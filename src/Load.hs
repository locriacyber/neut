module Load
  ( load
  ) where

import qualified Control.Monad.Except       as E
import           Control.Monad.Identity
import           Control.Monad.State        hiding (lift)
import           Control.Monad.Trans.Except

import           Control.Comonad.Cofree

import           Data.IORef

import           Asm
import           Data

import           Emit
import           Expand
import           Infer
import           Lift
import           Macro
import           Parse
import           Polarize
import           Read
import           Rename
import           Virtual

import qualified Text.Show.Pretty           as Pr

load :: String -> WithEnv ()
load s = do
  astList <- strToTree s
  load' astList

load' :: [Tree] -> WithEnv ()
load' [] = return ()
load' ((_ :< TreeNode [_ :< TreeAtom "notation", from, to]):as) = do
  modify (\e -> e {notationEnv = (from, to) : notationEnv e})
  load' as
load' ((_ :< TreeNode [_ :< TreeAtom "reserve", _ :< TreeAtom s]):as) = do
  modify (\e -> e {reservedEnv = s : reservedEnv e})
  load' as
load' ((_ :< TreeNode ((_ :< TreeAtom "index"):(_ :< TreeAtom name):ts)):as) = do
  indexList <- mapM parseAtom ts
  insIndexEnv name indexList
  load' as
load' (a:as) = do
  e <- macroExpand a >>= parse >>= rename
  liftIO $ putStrLn $ Pr.ppShow e
  check mainLabel e
  env <- get
  liftIO $ putStrLn $ Pr.ppShow (univConstraintEnv env)
  c' <- lift e >>= expand >>= polarize >>= toNeg >>= virtualNeg
  liftIO $ putStrLn $ Pr.ppShow c'
  insCodeEnv mainLabel [] c'
  asmCodeEnv
  emitGlobalLabel mainLabel
  emit
  -- env <- get
  -- liftIO $ putStrLn $ Pr.ppShow $ regEnv env
  load' as

mainLabel :: Identifier
mainLabel = "_main"
