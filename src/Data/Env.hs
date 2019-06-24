{-# LANGUAGE FlexibleInstances #-}

module Data.Env where

import           Control.Comonad.Cofree
import           Control.Monad.State
import           Control.Monad.Trans.Except
import           Data.List                  (elemIndex)

import           Data.Basic
import           Data.Constraint
import           Data.LLVM
import           Data.Polarized
import           Data.Term
import           Data.Tree
import           Data.WeakTerm

import qualified Data.Map.Strict            as Map

import qualified Data.PQueue.Min            as Q

data Env = Env
  { count             :: Int -- to generate fresh symbols
  , notationEnv       :: [(Tree, Tree)] -- macro transformers
  , reservedEnv       :: [Identifier] -- list of reserved keywords
  , constantEnv       :: [Identifier]
  -- , moduleEnv :: [(Identifier, (WeakSortal, [(WeakUpsilonPlus, WeakTerm)]))]
  , moduleEnv         :: [Identifier] -- "foo.bar" ~ ["foo", "bar"]
  , prefixEnv         :: [Identifier]
  , indexEnv          :: [(Identifier, [Identifier])]
  , nameEnv           :: [(Identifier, Identifier)] -- [("foo.bar.buz", "foo.bar.buz.13"), ...]
  , typeEnv           :: Map.Map Identifier WeakTerm
  , constraintEnv     :: [PreConstraint] -- for type inference
  , constraintQueue   :: Q.MinQueue EnrichedConstraint -- for (dependent) type inference
  , substitution      :: SubstWeakTerm -- for (dependent) type inference
  , univConstraintEnv :: [(UnivLevel, UnivLevel)]
  , currentDir        :: FilePath
  , termEnv           :: [(Identifier, ([Identifier], Term))] -- x == lam (x1, ..., xn). e
  , polEnv            :: [(Identifier, ([Identifier], Neg))] -- x == v || x == thunk (lam (x) e)
  , llvmEnv           :: [(Identifier, ([Identifier], LLVM))]
  }

initialEnv :: FilePath -> Env
initialEnv path =
  Env
    { count = 0
    , notationEnv = []
    , reservedEnv = []
    , constantEnv = []
    , moduleEnv = []
    , prefixEnv = []
    , indexEnv = []
    , nameEnv = []
    , typeEnv = Map.empty
    , termEnv = []
    , polEnv = []
    , llvmEnv = []
    , constraintEnv = []
    , constraintQueue = Q.empty
    , substitution = []
    , univConstraintEnv = []
    , currentDir = path
    }

type WithEnv a = StateT Env (ExceptT String IO) a

runWithEnv :: WithEnv a -> Env -> IO (Either String (a, Env))
runWithEnv c env = runExceptT (runStateT c env)

evalWithEnv :: (Show a) => WithEnv a -> Env -> IO (Either String a)
evalWithEnv c env = do
  resultOrErr <- runWithEnv c env
  case resultOrErr of
    Left err          -> return $ Left err
    Right (result, _) -> return $ Right result

newName :: WithEnv Identifier
newName = do
  env <- get
  let i = count env
  modify (\e -> e {count = i + 1})
  return $ "-" ++ show i

newNameWith :: Identifier -> WithEnv Identifier
newNameWith s = do
  i <- newName
  let s' = s ++ i
  modify (\e -> e {nameEnv = (s, s') : nameEnv e})
  return s'

newNameOfType :: WeakTerm -> WithEnv Identifier
newNameOfType t = do
  i <- newName
  insTypeEnv i t
  return i

newName1 :: Identifier -> WeakTerm -> WithEnv Identifier
newName1 baseName t = do
  i <- newNameWith baseName
  insTypeEnv i t
  return i

constNameWith :: Identifier -> WithEnv ()
constNameWith s = modify (\e -> e {nameEnv = (s, s) : nameEnv e})

lookupTypeEnv :: String -> WithEnv (Maybe WeakTerm)
lookupTypeEnv s = gets (Map.lookup s . typeEnv)

lookupTypeEnv' :: String -> WithEnv WeakTerm
lookupTypeEnv' s = do
  mt <- gets (Map.lookup s . typeEnv)
  case mt of
    Nothing -> lift $ throwE $ s ++ " is not found in the type environment."
    Just t  -> return t

lookupNameEnv :: String -> WithEnv String
lookupNameEnv s = do
  env <- get
  case lookup s (nameEnv env) of
    Just s' -> return s'
    Nothing -> lift $ throwE $ "undefined variable: " ++ show s

lookupNameEnv' :: String -> WithEnv String
lookupNameEnv' s = do
  env <- get
  case lookup s (nameEnv env) of
    Just s' -> return s'
    Nothing -> newNameWith s

lookupNameEnv'' :: String -> WithEnv (Maybe String)
lookupNameEnv'' s = do
  env <- get
  case lookup s (nameEnv env) of
    Just s' -> return $ Just s'
    Nothing -> return Nothing

lookupNameEnvByList :: [String] -> WithEnv (Maybe String)
lookupNameEnvByList [] = return Nothing
lookupNameEnvByList (x:xs) = do
  my <- lookupNameEnv'' x
  case my of
    Nothing -> lookupNameEnvByList xs
    Just y  -> return $ Just y

insTypeEnv :: Identifier -> WeakTerm -> WithEnv ()
insTypeEnv i t = modify (\e -> e {typeEnv = Map.insert i t (typeEnv e)})

insTypeEnv1 :: Identifier -> WeakTerm -> WithEnv ()
insTypeEnv1 i t = do
  tenv <- gets typeEnv
  let ts = Map.elems $ Map.filterWithKey (\j _ -> i == j) tenv
  forM_ ts $ \t' -> insConstraintEnv t t'
  modify (\e -> e {typeEnv = Map.insert i t (typeEnv e)})

insTermEnv :: Identifier -> [Identifier] -> Term -> WithEnv ()
insTermEnv name args e =
  modify (\env -> env {termEnv = (name, (args, e)) : termEnv env})

insPolEnv :: Identifier -> [Identifier] -> Neg -> WithEnv ()
insPolEnv name args e =
  modify (\env -> env {polEnv = (name, (args, e)) : polEnv env})

insLLVMEnv :: Identifier -> [Identifier] -> LLVM -> WithEnv ()
insLLVMEnv funName args e =
  modify (\env -> env {llvmEnv = (funName, (args, e)) : llvmEnv env})

insIndexEnv :: Identifier -> [Identifier] -> WithEnv ()
insIndexEnv name indexList =
  modify (\e -> e {indexEnv = (name, indexList) : indexEnv e})

lookupKind :: Literal -> WithEnv (Maybe Identifier)
lookupKind (LiteralInteger _) = return Nothing
lookupKind (LiteralFloat _) = return Nothing
lookupKind (LiteralLabel name) = do
  env <- get
  lookupKind' name $ indexEnv env

lookupKind' ::
     Identifier -> [(Identifier, [Identifier])] -> WithEnv (Maybe Identifier)
lookupKind' _ [] = return Nothing
lookupKind' i ((j, ls):xs) =
  if i `elem` ls
    then return $ Just j
    else lookupKind' i xs

lookupIndexSet :: Identifier -> WithEnv [Identifier]
lookupIndexSet name = do
  env <- get
  lookupIndexSet' name $ indexEnv env

lookupIndexSet' ::
     Identifier -> [(Identifier, [Identifier])] -> WithEnv [Identifier]
lookupIndexSet' name [] = lift $ throwE $ "no such index defined: " ++ show name
lookupIndexSet' name ((_, ls):xs) =
  if name `elem` ls
    then return ls
    else lookupIndexSet' name xs

getIndexNum :: Identifier -> WithEnv (Maybe Int)
getIndexNum label = do
  ienv <- gets indexEnv
  return $ getIndexNum' label $ map snd ienv

getIndexNum' :: Identifier -> [[Identifier]] -> Maybe Int
getIndexNum' _ [] = Nothing
getIndexNum' l (xs:xss) =
  case elemIndex l xs of
    Nothing -> getIndexNum' l xss
    Just i  -> Just i

isDefinedIndex :: Identifier -> WithEnv Bool
isDefinedIndex name = do
  env <- get
  let labelList = join $ map snd $ indexEnv env
  return $ name `elem` labelList

isDefinedIndexName :: Identifier -> WithEnv Bool
isDefinedIndexName name = do
  env <- get
  let indexNameList = map fst $ indexEnv env
  return $ name `elem` indexNameList

insConstraintEnv :: WeakTerm -> WeakTerm -> WithEnv ()
insConstraintEnv t1 t2 =
  modify (\e -> e {constraintEnv = (t1, t2) : constraintEnv e})

insUnivConstraintEnv :: UnivLevel -> UnivLevel -> WithEnv ()
insUnivConstraintEnv t1 t2 =
  modify (\e -> e {univConstraintEnv = (t1, t2) : univConstraintEnv e})

wrap :: f (Cofree f Identifier) -> WithEnv (Cofree f Identifier)
wrap a = do
  meta <- newNameWith "meta"
  return $ meta :< a

wrapType :: WeakTermF WeakTerm -> WithEnv WeakTerm
wrapType t = do
  meta <- newNameWith "meta"
  hole <- newName
  u <- wrap $ WeakTermUniv (UnivLevelHole hole)
  insTypeEnv meta u
  return $ meta :< t

wrapTypeWithUniv :: WeakTerm -> WeakTermF WeakTerm -> WithEnv WeakTerm
wrapTypeWithUniv univ t = do
  meta <- newNameWith "meta"
  insTypeEnv meta univ
  return $ meta :< t

insDef :: Identifier -> WeakTerm -> WithEnv (Maybe WeakTerm)
insDef x body = do
  sub <- gets substitution
  modify (\e -> e {substitution = (x, body) : substitution e})
  return $ lookup x sub

withEnvFoldL ::
     (Cofree f Identifier -> a -> f (Cofree f Identifier))
  -> Cofree f Identifier
  -> [a]
  -> WithEnv (Cofree f Identifier)
withEnvFoldL _ e [] = return e
withEnvFoldL f e (t:ts) = do
  i <- newName
  withEnvFoldL f (i :< f e t) ts

withEnvFoldR ::
     (a -> Cofree f Identifier -> f (Cofree f Identifier))
  -> Cofree f Identifier
  -> [a]
  -> WithEnv (Cofree f Identifier)
withEnvFoldR _ e [] = return e
withEnvFoldR f e (t:ts) = do
  tmp <- withEnvFoldR f e ts
  i <- newName
  return $ i :< f t tmp

newHole :: WithEnv WeakTerm
newHole = do
  h <- newNameWith "hole"
  m <- newNameWith "meta"
  return $ m :< WeakTermHole h
