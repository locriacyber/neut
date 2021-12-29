module Reduce.LowComp
  ( reduceLowComp,
  )
where

import Data.Basic (asInt)
import Data.Global
  ( newIdentFromIdent,
    nopFreeSetRef,
    shouldCancelAllocRef,
  )
import Data.IORef (modifyIORef', readIORef)
import qualified Data.IntMap as IntMap
import Data.LowComp
  ( LowComp (..),
    LowOp (LowOpAlloc, LowOpBitcast, LowOpFree),
    LowValue (LowValueNull, LowValueVarLocal),
    SizeInfo,
    SubstLowComp,
    substLowOp,
    substLowValue,
  )
import Data.LowType
  ( LowType (LowTypeArray, LowTypePointer, LowTypeStruct),
  )
import qualified Data.Map as Map
import qualified Data.Set as S

type SizeMap =
  Map.Map SizeInfo [(Int, LowValue)]

reduceLowComp :: SubstLowComp -> SizeMap -> LowComp -> IO LowComp
reduceLowComp sub sizeMap llvm = do
  cancelAllocFlag <- readIORef shouldCancelAllocRef
  case llvm of
    LowCompReturn d ->
      return $ LowCompReturn $ substLowValue sub d
    LowCompLet x op cont ->
      case op of
        LowOpBitcast d from to
          | from == to -> do
            let sub' = IntMap.insert (asInt x) (substLowValue sub d) sub
            reduceLowComp sub' sizeMap cont
        LowOpAlloc _ (LowTypePointer (LowTypeArray 0 _)) -> do
          let sub' = IntMap.insert (asInt x) LowValueNull sub
          reduceLowComp sub' sizeMap cont
        LowOpAlloc _ (LowTypePointer (LowTypeStruct [])) -> do
          let sub' = IntMap.insert (asInt x) LowValueNull sub
          reduceLowComp sub' sizeMap cont
        LowOpAlloc _ size
          | cancelAllocFlag,
            Just ((j, d) : rest) <- Map.lookup size sizeMap -> do
            modifyIORef' nopFreeSetRef $ S.insert j
            let sizeMap' = Map.insert size rest sizeMap
            let sub' = IntMap.insert (asInt x) (substLowValue sub d) sub
            reduceLowComp sub' sizeMap' cont
        _ -> do
          x' <- newIdentFromIdent x
          let sub' = IntMap.insert (asInt x) (LowValueVarLocal x') sub
          cont' <- reduceLowComp sub' sizeMap cont
          return $ LowCompLet x' (substLowOp sub op) cont'
    LowCompCont op@(LowOpFree d size j) cont -> do
      let op' = substLowOp sub op
      let sizeMap' = Map.insertWith (++) size [(j, d)] sizeMap
      cont' <- reduceLowComp sub sizeMap' cont
      return $ LowCompCont op' cont'
    LowCompCont op cont -> do
      let op' = substLowOp sub op
      cont' <- reduceLowComp sub sizeMap cont
      return $ LowCompCont op' cont'
    LowCompSwitch (d, t) defaultBranch les -> do
      let d' = substLowValue sub d
      let (ls, es) = unzip les
      defaultBranch' <- reduceLowComp sub sizeMap defaultBranch
      es' <- mapM (reduceLowComp sub sizeMap) es
      return $ LowCompSwitch (d', t) defaultBranch' (zip ls es')
    LowCompCall d ds -> do
      let d' = substLowValue sub d
      let ds' = map (substLowValue sub) ds
      return $ LowCompCall d' ds'
    LowCompUnreachable ->
      return LowCompUnreachable
