module Scene.Emit
  ( emitMain,
    emitOther,
  )
where

import Context.App
import qualified Context.Gensym as Gensym
import qualified Context.Throw as Throw
import Control.Monad
import Data.ByteString.Builder
import qualified Data.ByteString.Builder as L
import qualified Data.ByteString.Lazy as L
import Data.Function
import qualified Data.HashMap.Lazy as HashMap
import Data.IORef
import qualified Data.IntMap as IntMap
import qualified Data.Map as Map
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Entity.Global
import Entity.Ident
import Entity.LowComp
import Entity.LowComp.Reduce
import Entity.LowType
import Entity.PrimNum
import Entity.PrimNumSize
import Entity.PrimNumSize.ToInt
import Entity.PrimOp
import Entity.PrimOp.OpSet
import Numeric.Half
import qualified System.Info as System

emitMain :: Axis -> LowComp -> IO L.ByteString
emitMain axis mainTerm = do
  mainTerm' <- reduceLowComp (axis & gensym) IntMap.empty Map.empty mainTerm
  mainBuilder <- emitDefinition axis "i64" "main" [] mainTerm'
  emit' axis mainBuilder

emitOther :: Axis -> IO L.ByteString
emitOther axis =
  emit' axis []

emit' :: Axis -> [Builder] -> IO L.ByteString
emit' axis aux = do
  g <- emitDeclarations
  lowDefEnv <- readIORef lowDefEnvRef
  xs <-
    forM (HashMap.toList lowDefEnv) $ \(name, (args, body)) -> do
      let args' = map (showLowValue . LowValueVarLocal) args
      body' <- reduceLowComp (axis & gensym) IntMap.empty Map.empty body
      emitDefinition axis "i8*" (TE.encodeUtf8Builder name) args' body'
  return $ L.toLazyByteString $ unlinesL $ g : aux <> concat xs

emitDeclarations :: IO Builder
emitDeclarations = do
  lowDeclEnv <- HashMap.toList <$> readIORef lowDeclEnvRef
  return $ unlinesL $ map declToBuilder lowDeclEnv

declToBuilder :: (T.Text, ([LowType], LowType)) -> Builder
declToBuilder (name, (dom, cod)) = do
  let name' = TE.encodeUtf8Builder name
  "declare fastcc "
    <> showLowType cod
    <> " @"
    <> name'
    <> "("
    <> showItems showLowType dom
    <> ")"

emitDefinition :: Axis -> Builder -> Builder -> [Builder] -> LowComp -> IO [Builder]
emitDefinition axis retType name args asm = do
  let header = sig retType name args <> " {"
  content <- emitLowComp axis retType asm
  let footer = "}"
  return $ [header] <> content <> [footer]

sig :: Builder -> Builder -> [Builder] -> Builder
sig retType name args =
  "define fastcc " <> retType <> " @" <> name <> showLocals args

emitBlock :: Axis -> Builder -> Ident -> LowComp -> IO [Builder]
emitBlock axis funName (I (_, i)) asm = do
  a <- emitLowComp axis funName asm
  return $ emitLabel ("_" <> intDec i) : a

emitLowComp :: Axis -> Builder -> LowComp -> IO [Builder]
emitLowComp axis retType lowComp =
  case lowComp of
    LowCompReturn d ->
      emitRet retType d
    LowCompCall f args -> do
      tmp <- Gensym.newIdentFromText (axis & gensym) "tmp"
      op <-
        emitOp $
          unwordsL
            [ showLowValue (LowValueVarLocal tmp),
              "=",
              "tail call fastcc i8*",
              showLowValue f <> showArgs args
            ]
      a <- emitRet retType (LowValueVarLocal tmp)
      return $ op <> a
    LowCompSwitch (d, lowType) defaultBranch branchList -> do
      defaultLabel <- Gensym.newIdentFromText (axis & gensym) "default"
      labelList <- constructLabelList (axis & gensym) branchList
      op <-
        emitOp $
          unwordsL
            [ "switch",
              showLowType lowType,
              showLowValue d <> ",",
              "label",
              showLowValue (LowValueVarLocal defaultLabel),
              showBranchList lowType $ zip (map fst branchList) labelList
            ]
      let asmList = map snd branchList
      xs <-
        forM (zip labelList asmList <> [(defaultLabel, defaultBranch)]) $
          uncurry (emitBlock axis retType)
      return $ op <> concat xs
    LowCompCont op cont -> do
      s <- emitLowOp axis op
      str <- emitOp s
      a <- emitLowComp axis retType cont
      return $ str <> a
    LowCompLet x op cont -> do
      s <- emitLowOp axis op
      str <- emitOp $ showLowValue (LowValueVarLocal x) <> " = " <> s
      a <- emitLowComp axis retType cont
      return $ str <> a
    LowCompUnreachable ->
      emitOp $ unwordsL ["unreachable"]

emitLowOp :: Axis -> LowOp -> IO Builder
emitLowOp axis lowOp =
  case lowOp of
    LowOpCall d ds ->
      return $ unwordsL ["call fastcc i8*", showLowValue d <> showArgs ds]
    LowOpGetElementPtr (base, n) is ->
      return $
        unwordsL
          [ "getelementptr",
            showLowTypeAsIfNonPtr n <> ",",
            showLowType n,
            showLowValue base <> ",",
            showIndex is
          ]
    LowOpBitcast d fromType toType ->
      emitConvOp "bitcast" d fromType toType
    LowOpIntToPointer d fromType toType ->
      emitConvOp "inttoptr" d fromType toType
    LowOpPointerToInt d fromType toType ->
      emitConvOp "ptrtoint" d fromType toType
    LowOpLoad d lowType ->
      return $
        unwordsL
          [ "load",
            showLowType lowType <> ",",
            showLowTypeAsIfPtr lowType,
            showLowValue d
          ]
    LowOpStore t d1 d2 ->
      return $
        unwordsL
          [ "store",
            showLowType t,
            showLowValue d1 <> ",",
            showLowTypeAsIfPtr t,
            showLowValue d2
          ]
    LowOpAlloc d _ ->
      return $ unwordsL ["call fastcc", "i8*", "@malloc(i8* " <> showLowValue d <> ")"]
    LowOpFree d _ j -> do
      nopFreeSet <- readIORef nopFreeSetRef
      if S.member j nopFreeSet
        then return "bitcast i8* null to i8*" -- nop
        else return $ unwordsL ["call fastcc", "i8*", "@free(i8* " <> showLowValue d <> ")"]
    LowOpSyscall num ds ->
      emitSyscallOp axis num ds
    LowOpPrimOp (PrimOp op domList cod) args -> do
      let op' = TE.encodeUtf8Builder op
      case (S.member op unaryOpSet, S.member op convOpSet, S.member op binaryOpSet, S.member op cmpOpSet) of
        (True, _, _, _) ->
          emitUnaryOp (head domList) op' (head args)
        (_, True, _, _) ->
          emitConvOp op' (head args) (LowTypePrimNum $ head domList) (LowTypePrimNum cod)
        (_, _, True, _) ->
          emitBinaryOp (head domList) op' (head args) (args !! 1)
        (_, _, _, True) ->
          emitBinaryOp (head domList) op' (head args) (args !! 1)
        _ ->
          axis & throw & Throw.raiseCritical' $ "unknown primitive: " <> op

emitUnaryOp :: PrimNum -> Builder -> LowValue -> IO Builder
emitUnaryOp t inst d =
  return $ unwordsL [inst, showPrimNumForEmit t, showLowValue d]

emitBinaryOp :: PrimNum -> Builder -> LowValue -> LowValue -> IO Builder
emitBinaryOp t inst d1 d2 =
  return $
    unwordsL [inst, showPrimNumForEmit t, showLowValue d1 <> ",", showLowValue d2]

emitConvOp :: Builder -> LowValue -> LowType -> LowType -> IO Builder
emitConvOp cast d dom cod =
  return $
    unwordsL [cast, showLowType dom, showLowValue d, "to", showLowType cod]

emitSyscallOp :: Axis -> Integer -> [LowValue] -> IO Builder
emitSyscallOp axis num ds = do
  regList <- getRegList axis
  case System.arch of
    "x86_64" -> do
      let args = (LowValueInt num, LowTypePrimNum $ PrimNumInt (IntSize 64)) : zip ds (repeat voidPtr)
      let argStr = "(" <> showIndex args <> ")"
      let regStr = "\"=r" <> showRegList (take (length args) regList) <> "\""
      return $
        unwordsL ["call fastcc i8* asm sideeffect \"syscall\",", regStr, argStr]
    "aarch64" -> do
      let args = (LowValueInt num, LowTypePrimNum $ PrimNumInt (IntSize 64)) : zip ds (repeat voidPtr)
      let argStr = "(" <> showIndex args <> ")"
      let regStr = "\"=r" <> showRegList (take (length args) regList) <> "\""
      return $
        unwordsL ["call fastcc i8* asm sideeffect \"svc 0\",", regStr, argStr]
    targetArch ->
      axis & throw & Throw.raiseCritical' $ "unsupported target arch: " <> T.pack (show targetArch)

emitOp :: Builder -> IO [Builder]
emitOp s =
  return ["  " <> s]

emitRet :: Builder -> LowValue -> IO [Builder]
emitRet retType d =
  emitOp $ unwordsL ["ret", retType, showLowValue d]

emitLabel :: Builder -> Builder
emitLabel s =
  s <> ":"

constructLabelList :: Gensym.Axis -> [a] -> IO [Ident]
constructLabelList axis input =
  case input of
    [] ->
      return []
    (_ : rest) -> do
      label <- Gensym.newIdentFromText axis "case"
      labelList <- constructLabelList axis rest
      return $ label : labelList

showRegList :: [Builder] -> Builder
showRegList regList =
  case regList of
    [] ->
      ""
    (s : ss) ->
      ",{" <> s <> "}" <> showRegList ss

showBranchList :: LowType -> [(Int, Ident)] -> Builder
showBranchList lowType xs =
  "[" <> unwordsL (map (uncurry (showBranch lowType)) xs) <> "]"

showIndex :: [(LowValue, LowType)] -> Builder
showIndex idxList =
  case idxList of
    [] ->
      ""
    [(d, t)] ->
      showLowType t <> " " <> showLowValue d
    ((d, t) : dts) ->
      showIndex [(d, t)] <> ", " <> showIndex dts

showBranch :: LowType -> Int -> Ident -> Builder
showBranch lowType i label =
  showLowType lowType
    <> " "
    <> intDec i
    <> ", label "
    <> showLowValue (LowValueVarLocal label)

showArg :: LowValue -> Builder
showArg d =
  "i8* " <> showLowValue d

showLocal :: Builder -> Builder
showLocal x =
  "i8* " <> x

showArgs :: [LowValue] -> Builder
showArgs ds =
  "(" <> showItems showArg ds <> ")"

showLocals :: [Builder] -> Builder
showLocals ds =
  "(" <> showItems showLocal ds <> ")"

showLowTypeAsIfPtr :: LowType -> Builder
showLowTypeAsIfPtr t =
  showLowType t <> "*"

showLowTypeAsIfNonPtr :: LowType -> Builder
showLowTypeAsIfNonPtr lowType =
  case lowType of
    LowTypePrimNum primNum ->
      showPrimNumForEmit primNum
    LowTypeStruct ts ->
      "{" <> showItems showLowType ts <> "}"
    LowTypeFunction ts t ->
      showLowType t <> " (" <> showItems showLowType ts <> ")"
    LowTypeArray i t -> do
      let s = showLowType t
      "[" <> intDec i <> " x " <> s <> "]"
    LowTypePointer t ->
      showLowType t

getRegList :: Axis -> IO [Builder]
getRegList axis = do
  targetPlatform <- readIORef targetPlatformRef
  case targetPlatform of
    "x86_64-linux" ->
      return ["rax", "rdi", "rsi", "rdx", "rcx", "r8", "r9"]
    "arm64-linux" ->
      return ["x8", "x0", "x1", "x2", "x3", "x4", "x5"]
    "x86_64-darwin" ->
      return ["rax", "rdi", "rsi", "rdx", "r10", "r8", "r9"]
    _ ->
      axis & throw & Throw.raiseError' $ "unsupported target: " <> T.pack targetPlatform

showLowType :: LowType -> Builder
showLowType lowType =
  case lowType of
    LowTypePrimNum primNum ->
      showPrimNumForEmit primNum
    LowTypeStruct ts ->
      "{" <> showItems showLowType ts <> "}"
    LowTypeFunction ts t ->
      showLowType t <> " (" <> showItems showLowType ts <> ")"
    LowTypeArray i t -> do
      let s = showLowType t
      "[" <> intDec i <> " x " <> s <> "]"
    LowTypePointer t ->
      showLowType t <> "*"

showPrimNumForEmit :: PrimNum -> Builder
showPrimNumForEmit lowType =
  case lowType of
    PrimNumInt i ->
      "i" <> intDec (intSizeToInt i)
    PrimNumFloat FloatSize16 ->
      "half"
    PrimNumFloat FloatSize32 ->
      "float"
    PrimNumFloat FloatSize64 ->
      "double"

showLowValue :: LowValue -> Builder
showLowValue lowValue =
  case lowValue of
    LowValueVarLocal (I (_, i)) ->
      "%_" <> intDec i
    LowValueVarGlobal x ->
      "@" <> TE.encodeUtf8Builder x
    LowValueInt i ->
      integerDec i
    LowValueFloat FloatSize16 x -> do
      let x' = realToFrac x :: Half
      "0x" <> doubleHexFixed (realToFrac x')
    LowValueFloat FloatSize32 x -> do
      let x' = realToFrac x :: Float
      "0x" <> doubleHexFixed (realToFrac x')
    LowValueFloat FloatSize64 x -> do
      let x' = realToFrac x :: Double
      "0x" <> doubleHexFixed (realToFrac x')
    LowValueNull ->
      "null"

showItems :: (a -> Builder) -> [a] -> Builder
showItems f itemList =
  case itemList of
    [] ->
      ""
    [a] ->
      f a
    a : as ->
      f a <> ", " <> showItems f as

{-# INLINE unwordsL #-}
unwordsL :: [Builder] -> Builder
unwordsL strList =
  case strList of
    [] ->
      ""
    [b] ->
      b
    b : bs ->
      b <> " " <> unwordsL bs

{-# INLINE unlinesL #-}
unlinesL :: [Builder] -> Builder
unlinesL strList =
  case strList of
    [] ->
      ""
    [b] ->
      b
    b : bs ->
      b <> "\n" <> unlinesL bs
