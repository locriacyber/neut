module Entity.Comp.Reduce
  ( reduce,
    Context,
  )
where

import qualified Context.CompDefinition as CompDefinition
import qualified Context.Gensym as Gensym
import qualified Data.IntMap as IntMap
import qualified Entity.Comp as C
import Entity.Comp.Subst
import qualified Entity.EnumCase as EC
import Entity.Ident
import qualified Entity.Ident.Reify as Ident
import qualified Entity.Opacity as O

class (CompDefinition.Context m, Gensym.Context m) => Context m

reduce :: Context m => C.Comp -> m C.Comp
reduce term =
  case term of
    C.Primitive _ ->
      return term
    C.PiElimDownElim v ds -> do
      case v of
        C.VarGlobal x _ -> do
          mDefValue <- CompDefinition.lookup x
          case mDefValue of
            Just (O.Transparent, xs, body) -> do
              let sub = IntMap.fromList (zip (map Ident.toInt xs) ds)
              subst sub body >>= reduce
            _ ->
              return term
        _ ->
          return term
    C.SigmaElim shouldDeallocate xs v e ->
      if not shouldDeallocate
        then do
          e' <- reduce e
          return $ C.SigmaElim shouldDeallocate xs v e'
        else do
          case v of
            C.SigmaIntro ds
              | length ds == length xs -> do
                  let sub = IntMap.fromList (zip (map Ident.toInt xs) ds)
                  subst sub e >>= reduce
            _ -> do
              e' <- reduce e
              case e' of
                C.UpIntro (C.SigmaIntro ds)
                  | Just ys <- mapM extractIdent ds,
                    xs == ys ->
                      return $ C.UpIntro v -- eta-reduce
                C.Unreachable ->
                  return C.Unreachable
                _ ->
                  case xs of
                    [] ->
                      return e'
                    _ ->
                      return $ C.SigmaElim shouldDeallocate xs v e'
    C.UpIntro _ ->
      return term
    C.UpElim isReducible x e1 e2 -> do
      e1' <- reduce e1
      case e1' of
        C.UpIntro v
          | isReducible -> do
              let sub = IntMap.fromList [(Ident.toInt x, v)]
              subst sub e2 >>= reduce
        C.UpElim isReducible' y ey1 ey2 ->
          reduce $ C.UpElim isReducible' y ey1 $ C.UpElim isReducible x ey2 e2 -- commutative conversion
        C.SigmaElim b yts vy ey ->
          reduce $ C.SigmaElim b yts vy $ C.UpElim isReducible x ey e2 -- commutative conversion
        _ -> do
          e2' <- reduce e2
          case e2' of
            C.UpIntro (C.VarLocal y)
              | x == y,
                isReducible ->
                  return e1' -- eta-reduce
            C.Unreachable ->
              return C.Unreachable
            _ ->
              return $ C.UpElim isReducible x e1' e2'
    C.EnumElim v defaultBranch les -> do
      case v of
        C.Int _ l
          | Just body <- lookup (EC.Int (fromInteger l)) les ->
              reduce body
          | otherwise ->
              reduce defaultBranch
        _ -> do
          let (ls, es) = unzip les
          defaultBranch' <- reduce defaultBranch
          es' <- mapM reduce es
          return $ C.EnumElim v defaultBranch' (zip ls es')
    C.Unreachable ->
      return term

extractIdent :: C.Value -> Maybe Ident
extractIdent term =
  case term of
    C.VarLocal x ->
      Just x
    _ ->
      Nothing
