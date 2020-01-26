{-# LANGUAGE OverloadedStrings #-}

module Elaborate.Synthesize
  ( synthesize
  ) where

import Control.Monad.Except
import Control.Monad.State
import Data.List (sortBy)
import Path
import System.Console.ANSI

import qualified Data.HashMap.Strict as Map
import qualified Data.PQueue.Min as Q
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Text.Show.Pretty as Pr

import Data.Basic
import Data.Constraint
import Data.Env
import Data.WeakTerm
import Elaborate.Analyze
import Parse.Rename
import Reduce.WeakTerm

-- Given a queue of constraints (easier ones comes earlier), try to synthesize
-- all of them using heuristics.
-- {} synthesize {}
synthesize :: WithEnv ()
synthesize = do
  q <- gets constraintQueue
  sub <- gets substEnv
  case Q.getMin q of
    Nothing -> return ()
    Just (Enriched (e1, e2) ms _)
      | Just (m, e) <- lookupAny ms sub -> do resolveStuck e1 e2 m e
    Just (Enriched _ _ (ConstraintDelta iter mess1 mess2)) -> do
      resolveDelta iter mess1 mess2
    Just (Enriched _ _ (ConstraintQuasiPattern m ess e)) -> do
      resolvePiElim m ess e
    Just (Enriched _ _ (ConstraintFlexRigid m ess e)) -> do
      resolvePiElim m ess e
    Just (Enriched _ _ _) -> do
      showErrorThenQuit q
      -- p $ "rest: " ++ show (Q.size q)
      -- throwError' $ "cannot simplify:\n" <> T.pack (Pr.ppShow (e1, e2))

-- e1だけがstuckしているとき、e2だけがstuckしているとき、両方がstuckしているときをそれぞれ
-- 独立したケースとして扱えるようにしたほうがよい（そうすればsubstを減らせる）
-- つまり、e1とe2のstuck reasonをそれぞれ別々に保持したほうがよい。
-- synthのときにlookupAnyできるかでseparateするとか？
resolveStuck ::
     WeakTermPlus -> WeakTermPlus -> Hole -> WeakTermPlus -> WithEnv ()
resolveStuck e1 e2 h e = do
  let e1' = substWeakTermPlus [(h, e)] e1
  let e2' = substWeakTermPlus [(h, e)] e2
  deleteMin
  simp [(e1', e2')]
  synthesize

resolveDelta ::
     IterInfo
  -> [(Meta, [WeakTermPlus])]
  -> [(Meta, [WeakTermPlus])]
  -> WithEnv ()
resolveDelta iter mess1 mess2 = do
  let planA = do
        let ess1 = map snd mess1
        let ess2 = map snd mess2
        simp $ zip (concat ess1) (concat ess2)
        synthesize
  let planB = do
        let e1 = toPiElim (unfoldIter iter) mess1
        let e2 = toPiElim (unfoldIter iter) mess2
        simp $ [(e1, e2)]
        synthesize
  deleteMin
  chain [planA, planB]

-- synthesize `hole @ arg-1 @ ... @ arg-n = e`, where arg-i is a variable.
-- Suppose that we received a quasi-pattern ?M @ x @ x @ y @ z == e.
-- What this function do is to try two alternatives in this case:
--   (1) ?M == lam x. lam _. lam y. lam z. e
--   (2) ?M == lam _. lam x. lam y. lam z. e
-- where `_` are new variables. In other words, this function tries
-- all the alternatives that are obtained by choosing one `x` from the
-- list [x, x, y, z], replacing all the other occurrences of `x` with new variables.
-- If the given pattern is a flex-rigid pattern like ?M @ x @ x @ e1 @ y == e,
-- this function replaces all the arguments that are not variable by
-- fresh variables, and try to resolve the new quasi-pattern ?M @ x @ x @ z @ y == e.
-- {} resolvePiElim {}
resolvePiElim :: Hole -> [[WeakTermPlus]] -> WeakTermPlus -> WithEnv ()
resolvePiElim m ess e = do
  let lengthInfo = map length ess
  let es = concat ess
  xss <- toVarList es >>= toAltList
  let xsss = map (takeByCount lengthInfo) xss
  let lamList = map (bindFormalArgs e) xsss
  deleteMin
  chain $ map (resolveHole m) lamList

-- {} resolveHole {}
resolveHole :: Hole -> WeakTermPlus -> WithEnv ()
resolveHole m e = do
  modify (\env -> env {substEnv = Map.insert m e (substEnv env)})
  q <- gets constraintQueue
  let (q1, q2) = Q.partition (\(Enriched _ ms _) -> m `elem` ms) q
  let q1' = Q.mapU asAnalyzable q1
  modify (\env -> env {constraintQueue = q1' `Q.union` q2})
  synthesize

-- {} asAnalyzable {}
asAnalyzable :: EnrichedConstraint -> EnrichedConstraint
asAnalyzable (Enriched cs ms _) = Enriched cs ms ConstraintAnalyzable

-- Try the list of alternatives.
chain :: [WithEnv a] -> WithEnv a
chain [] = throwError' $ "cannot synthesize(chain)."
chain [e] = e
chain (e:es) = catchError e $ (const $ do chain es)

deleteMin :: WithEnv ()
deleteMin = do
  modify (\env -> env {constraintQueue = Q.deleteMin (constraintQueue env)})

-- [x, x, y, z, z] ~>
--   [ [x, p, y, z, q]
--   , [x, p, y, q, z]
--   , [p, x, y, z, q]
--   , [p, x, y, q, z]
--   ]
-- (p, q : fresh variables)
-- {} toAltList {それぞれのlistはlinear list}
toAltList :: [IdentifierPlus] -> WithEnv [[IdentifierPlus]]
toAltList xts = do
  result <-
    mapM (discardInactive xts) $ chooseActive $ toIndexInfo (map fst xts)
  -- forM_ (map (map fst) result) $ \xs -> do
  --   let info = toInfo "toAltList: linearity is not satisfied:" xs
  --   assertUP info $ linearCheck xs
  return result

-- [x, x, y, z, z] ~> [(x, [0, 1]), (y, [2]), (z, [3, 4])]
toIndexInfo :: Eq a => [a] -> [(a, [Int])]
toIndexInfo xs = toIndexInfo' $ zip xs [0 ..]

toIndexInfo' :: Eq a => [(a, Int)] -> [(a, [Int])]
toIndexInfo' [] = []
toIndexInfo' ((x, i):xs) = do
  let (is, xs') = toIndexInfo'' x xs
  let xs'' = toIndexInfo' xs'
  (x, i : is) : xs''

toIndexInfo'' :: Eq a => a -> [(a, Int)] -> ([Int], [(a, Int)])
toIndexInfo'' _ [] = ([], [])
toIndexInfo'' x ((y, i):ys) = do
  let (is, ys') = toIndexInfo'' x ys
  if x == y
    then (i : is, ys') -- remove x from the list
    else (is, (y, i) : ys')

chooseActive :: [(Identifier, [Int])] -> [[(Identifier, Int)]]
chooseActive xs = do
  let xs' = map (\(x, is) -> zip (repeat x) is) xs
  pickup xs'

pickup :: Eq a => [[a]] -> [[a]]
pickup [] = [[]]
pickup (xs:xss) = do
  let yss = pickup xss
  x <- xs
  map (\ys -> x : ys) yss

discardInactive ::
     [IdentifierPlus] -> [(Identifier, Int)] -> WithEnv [IdentifierPlus]
discardInactive xs indexList =
  forM (zip xs [0 ..]) $ \((x, t), i) ->
    case lookup x indexList of
      Just j
        | i == j -> return (x, t)
      _ -> do
        y <- newNameWith "hole"
        return (y, t)

-- takeByCount [1, 3, 2] [a, b, c, d, e, f, g, h] ~> [[a], [b, c, d], [e, f]]
takeByCount :: [Int] -> [a] -> [[a]]
takeByCount [] _ = []
takeByCount (i:is) xs = do
  let ys = take i xs
  let yss = takeByCount is (drop i xs)
  ys : yss

showErrorThenQuit :: ConstraintQueue -> WithEnv ()
showErrorThenQuit q = do
  let pcs = sortBy (\x y -> fst x `compare` fst y) $ setupPosInfo $ Q.toList q
  prepareInvRename
  showErrors [] pcs >>= throwError

type PosInfo = (Path Abs File, Maybe Loc)

isFollowedBy :: PosInfo -> PosInfo -> Bool
isFollowedBy (_, loc1) (_, loc2) = loc1 < loc2

setupPosInfo :: [EnrichedConstraint] -> [(PosInfo, PreConstraint)]
setupPosInfo [] = []
setupPosInfo ((Enriched c@(e1, e2) _ _):cs) = do
  case (getLocInfo e1, getLocInfo e2) of
    (Just pos1, Just pos2) -> do
      if pos1 `isFollowedBy` pos2
        then (pos2, c) : setupPosInfo cs
        else (pos1, c) : setupPosInfo cs
    (Just pos1, Nothing) -> (pos1, c) : setupPosInfo cs
    (Nothing, Just pos2) -> (pos2, c) : setupPosInfo cs
    _ -> setupPosInfo cs -- fixme (loc info not available)

showErrors :: [PosInfo] -> [(PosInfo, PreConstraint)] -> WithEnv [IO ()]
showErrors _ [] = return []
showErrors ps ((pos, (e1, e2)):pcs) = do
  e1' <- invRename e1
  e2' <- invRename e2
  showErrors' pos ps e1' e2' pcs

showErrors' ::
     PosInfo
  -> [PosInfo]
  -> WeakTermPlus
  -> WeakTermPlus
  -> [(PosInfo, PreConstraint)]
  -> WithEnv [IO ()]
showErrors' pos ps e1 e2 pcs
  | pos `notElem` ps = do
    b <- gets shouldColorize
    let a = showErrorHeader b pos >> showError' b e1 e2
    as <- showErrors (pos : ps) pcs
    return $ a : as
  | otherwise = showErrors ps pcs

showErrorHeader :: Bool -> PosInfo -> IO ()
showErrorHeader b (path, loc) = do
  setSGR' b [SetConsoleIntensity BoldIntensity]
  TIO.putStr $ T.pack (showPosInfo path $ maximum loc)
  TIO.putStrLn ":"
  setSGR' b [Reset]

showError' :: Bool -> WeakTermPlus -> WeakTermPlus -> IO ()
showError' b e1 e2 = do
  setSGR' b [SetConsoleIntensity BoldIntensity, SetColor Foreground Vivid Red]
  TIO.putStr "error: "
  setSGR' b [Reset]
  TIO.putStrLn
    "couldn't verify the definitional equality of the following two terms:"
  TIO.putStrLn $ "- " <> toText e1
  TIO.putStrLn $ "- " <> toText e2

setSGR' :: Bool -> [SGR] -> IO ()
setSGR' False _ = return ()
setSGR' True arg = setSGR arg

getLocInfo :: WeakTermPlus -> Maybe PosInfo
getLocInfo (m, _) =
  case (metaFileName m, metaConstraintLocation m) of
    (_, Nothing) -> Nothing
    (Just path, l) -> return (path, l)
    _ -> Nothing
