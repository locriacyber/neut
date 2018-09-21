module Virtual
  ( virtualPos
  , virtualNeg
  ) where

import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Identity
import           Control.Monad.State
import           Control.Monad.Trans.Except

import           Data

import           Control.Comonad.Cofree

import qualified Text.Show.Pretty           as Pr

import           Debug.Trace

virtualPos :: Pos -> WithEnv Data
virtualPos (PosVar x) = return (DataLocal x)
virtualPos (PosPi _ _) = virtualPos PosTopIntro
virtualPos (PosSigma _ _) = virtualPos PosTopIntro
virtualPos (PosSigmaIntro xs) = return $ DataStruct xs
virtualPos PosTop = virtualPos PosTopIntro
virtualPos PosTopIntro = return $ DataInt32 0
virtualPos (PosIndex _) = return $ DataInt32 0
virtualPos (PosIndexIntro x) = do
  i <- indexToInt x
  return $ DataInt32 i
virtualPos (PosUp _) = virtualPos PosTopIntro
virtualPos (PosDown _) = virtualPos PosTopIntro
virtualPos (PosDownIntroPiIntro name args body) = do
  bodyCode <- virtualNeg body
  insCodeEnv name args bodyCode
  return $ DataLabel name
virtualPos PosUniv = virtualPos PosTopIntro

virtualNeg :: Neg -> WithEnv Code
virtualNeg (NegPiElimDownElim funName args) = do
  s <- newNameWith "tmp"
  return $ CodeCall s funName args (CodeReturn (DataLocal s))
virtualNeg (NegSigmaElim z (x, y) e) = do
  e' <- virtualNeg e
  return $ CodeExtractValue x z 0 (CodeExtractValue y z 1 e')
virtualNeg (NegIndexElim x branchList) = do
  let (labelList, es) = unzip branchList
  es' <- mapM virtualNeg es
  return $ CodeSwitch x $ zip labelList es'
virtualNeg (NegUpIntro v) = do
  d <- virtualPos v
  return $ CodeReturn d
virtualNeg (NegUpElim x e1 e2) = do
  e1' <- virtualNeg e1
  e2' <- virtualNeg e2
  traceLet x e1' e2'

traceLet :: String -> Code -> Code -> WithEnv Code
traceLet s (CodeReturn ans) cont = return $ CodeLet s ans cont
traceLet s (CodeLet k o1 o2) cont = do
  c <- traceLet s o2 cont
  return $ CodeLet k o1 c
traceLet s (CodeCall reg name xds cont1) cont2 = do
  tmp <- traceLet s cont1 cont2
  return $ CodeCall reg name xds tmp
traceLet x (CodeSwitch y branchList) cont = do
  let (labelList, es) = unzip branchList
  es' <- mapM (\e -> traceLet x e cont) es
  return $ CodeSwitch y $ zip labelList es'
traceLet s (CodeExtractValue x d i cont1) cont2 = do
  tmp <- traceLet s cont1 cont2
  return $ CodeExtractValue x d i tmp
