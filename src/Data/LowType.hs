{-# LANGUAGE DeriveGeneric #-}

module Data.LowType where

import Data.Binary (Binary)
import qualified Data.Set as S
import qualified Data.Text as T
import GHC.Generics (Generic)
import Text.Read (readMaybe)

data LowType
  = LowTypeInt IntSize
  | LowTypeFloat FloatSize
  | LowTypePointer LowType
  | LowTypeArray Int LowType -- [n x LOWTYPE]
  | LowTypeStruct [LowType]
  | LowTypeFunction [LowType] LowType
  deriving (Eq, Ord, Show, Generic)

instance Binary LowType

type IntSize =
  Int

data FloatSize
  = FloatSize16
  | FloatSize32
  | FloatSize64
  deriving (Eq, Ord, Show, Generic)

instance Binary FloatSize

data PrimOp
  = PrimOp T.Text [LowType] LowType
  deriving (Show, Eq)

-- a `derangement` handles an extra-linguistic feature
data Derangement a
  = DerangementCast a a a
  | DerangementStore LowType a a
  | DerangementLoad LowType a
  | DerangementSyscall Integer [a]
  | DerangementExternal T.Text [a]
  | DerangementCreateArray LowType [a]
  deriving (Show, Eq, Generic)

instance (Binary a) => Binary (Derangement a)

instance Functor Derangement where
  fmap f der =
    case der of
      DerangementCast from to value ->
        DerangementCast (f from) (f to) (f value)
      DerangementStore lt pointer value ->
        DerangementStore lt (f pointer) (f value)
      DerangementLoad lt pointer ->
        DerangementLoad lt (f pointer)
      DerangementSyscall syscallNum args ->
        DerangementSyscall syscallNum $ fmap f args
      DerangementExternal extFunName args ->
        DerangementExternal extFunName $ fmap f args
      DerangementCreateArray lt args ->
        DerangementCreateArray lt $ fmap f args

instance Foldable Derangement where
  foldMap f der =
    case der of
      DerangementCast from to value ->
        f from <> f to <> f value
      DerangementStore _ pointer value ->
        f pointer <> f value
      DerangementLoad _ pointer ->
        f pointer
      DerangementSyscall _ args ->
        foldMap f args
      DerangementExternal _ args ->
        foldMap f args
      DerangementCreateArray _ args ->
        foldMap f args

instance Traversable Derangement where
  traverse f der =
    case der of
      DerangementCast from to value ->
        DerangementCast <$> f from <*> f to <*> f value
      DerangementStore lt pointer value ->
        DerangementStore lt <$> f pointer <*> f value
      DerangementLoad lt pointer ->
        DerangementLoad lt <$> f pointer
      DerangementSyscall syscallNum args ->
        DerangementSyscall syscallNum <$> traverse f args
      DerangementExternal extFunName args ->
        DerangementExternal extFunName <$> traverse f args
      DerangementCreateArray lt args ->
        DerangementCreateArray lt <$> traverse f args

getDerangementName :: Derangement a -> T.Text
getDerangementName d =
  case d of
    DerangementSyscall {} ->
      "syscall"
    DerangementExternal {} ->
      "external"
    DerangementLoad {} ->
      "load"
    DerangementStore {} ->
      "store"
    DerangementCast {} ->
      "nop"
    DerangementCreateArray {} ->
      "create-array"

asLowTypeMaybe :: T.Text -> Maybe LowType
asLowTypeMaybe name
  | Just intSize <- asLowInt name =
    Just $ LowTypeInt intSize
  | Just floatSize <- asLowFloat name =
    Just $ LowTypeFloat floatSize
  | otherwise =
    Nothing

voidPtr :: LowType
voidPtr =
  LowTypePointer (LowTypeInt 8)

asLowInt :: T.Text -> Maybe IntSize
asLowInt s =
  case T.uncons s of
    Nothing ->
      Nothing
    Just (c, rest) ->
      case c of
        'i'
          | Just n <- readMaybe $ T.unpack rest,
            1 <= n,
            n <= 64 ->
            Just n
        _ ->
          Nothing

asLowFloat :: T.Text -> Maybe FloatSize
asLowFloat s =
  case T.uncons s of
    Nothing ->
      Nothing
    Just (c, rest) ->
      case c of
        'f'
          | Just n <- readMaybe $ T.unpack rest,
            Just size <- asFloatSize n ->
            Just size
        _ ->
          Nothing

asPrimOp :: T.Text -> Maybe PrimOp
asPrimOp name
  | Just ("fneg", typeStr) <- breakOnMaybe "-" name,
    Just lowType@(LowTypeFloat _) <- asLowTypeMaybe typeStr =
    Just $ PrimOp "fneg" [lowType] lowType
  | Just (convOpStr, rest) <- breakOnMaybe "-" name,
    Just (domTypeStr, codTypeStr) <- breakOnMaybe "-" rest,
    Just domType <- asLowTypeMaybe domTypeStr,
    Just codType <- asLowTypeMaybe codTypeStr,
    isValidConvOp convOpStr domType codType =
    Just $ PrimOp convOpStr [domType] codType
  | Just (opStr, typeStr) <- breakOnMaybe "-" name =
    case asLowTypeMaybe typeStr of
      Just lowType@(LowTypeInt _)
        | asLowICmpMaybe opStr ->
          Just $ PrimOp ("icmp " <> opStr) [lowType, lowType] (LowTypeInt 1)
      Just lowType@(LowTypeFloat _)
        | asLowFCmpMaybe opStr ->
          Just $ PrimOp ("fcmp " <> opStr) [lowType, lowType] (LowTypeInt 1)
      Just lowType
        | asLowBinaryOpMaybe' opStr lowType ->
          Just $ PrimOp opStr [lowType, lowType] lowType
      _ ->
        Nothing
  | otherwise =
    Nothing

unaryOpSet :: S.Set T.Text
unaryOpSet =
  S.fromList ["fneg"]

convOpSet :: S.Set T.Text
convOpSet =
  S.fromList ["trunc", "zext", "sext", "fptrunc", "fpext", "fptoui", "fptosi", "uitofp", "sitofp"]

cmpOpSet :: S.Set T.Text
cmpOpSet = do
  let s1 = S.map ("icmp " <>) intCmpOpSet
  let s2 = S.map ("fcmp " <>) floatCmpOpSet
  S.union s1 s2

binaryOpSet :: S.Set T.Text
binaryOpSet =
  S.union intBinaryOpSet floatBinaryOpSet

intCmpOpSet :: S.Set T.Text
intCmpOpSet =
  S.fromList ["eq", "ne", "ugt", "uge", "ult", "ule", "sgt", "sge", "slt", "sle"]

floatCmpOpSet :: S.Set T.Text
floatCmpOpSet =
  S.fromList ["false", "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "ueq", "ugt", "uge", "ult", "ule", "une", "uno", "true"]

intBinaryOpSet :: S.Set T.Text
intBinaryOpSet =
  S.fromList ["add", "sub", "mul", "udiv", "sdiv", "urem", "srem", "shl", "lshr", "ashr", "and", "or", "xor"]

floatBinaryOpSet :: S.Set T.Text
floatBinaryOpSet =
  S.fromList ["fadd", "fsub", "fmul", "fdiv", "frem"]

isValidConvOp :: T.Text -> LowType -> LowType -> Bool
isValidConvOp name domType codType =
  case name of
    "trunc"
      | LowTypeInt i1 <- domType,
        LowTypeInt i2 <- codType ->
        i1 > i2
    "zext"
      | LowTypeInt i1 <- domType,
        LowTypeInt i2 <- codType ->
        i1 < i2
    "sext"
      | LowTypeInt i1 <- domType,
        LowTypeInt i2 <- codType ->
        i1 < i2
    "fptrunc"
      | LowTypeFloat size1 <- domType,
        LowTypeFloat size2 <- codType ->
        sizeAsInt size1 > sizeAsInt size2
    "fpext"
      | LowTypeFloat size1 <- domType,
        LowTypeFloat size2 <- codType ->
        sizeAsInt size1 < sizeAsInt size2
    "fptoui"
      | LowTypeFloat _ <- domType,
        LowTypeInt _ <- codType ->
        True
    "fptosi"
      | LowTypeFloat _ <- domType,
        LowTypeInt _ <- codType ->
        True
    "uitofp"
      | LowTypeInt _ <- domType,
        LowTypeFloat _ <- codType ->
        True
    "sitofp"
      | LowTypeInt _ <- domType,
        LowTypeFloat _ <- codType ->
        True
    _ ->
      False

asLowBinaryOpMaybe' :: T.Text -> LowType -> Bool
asLowBinaryOpMaybe' name lowType =
  case lowType of
    LowTypeInt _ ->
      S.member name intBinaryOpSet
    LowTypeFloat _ ->
      S.member name floatBinaryOpSet
    _ ->
      False

asLowICmpMaybe :: T.Text -> Bool
asLowICmpMaybe name =
  S.member name intCmpOpSet

asLowFCmpMaybe :: T.Text -> Bool
asLowFCmpMaybe name =
  S.member name floatCmpOpSet

{-# INLINE breakOnMaybe #-}
breakOnMaybe :: T.Text -> T.Text -> Maybe (T.Text, T.Text)
breakOnMaybe needle text =
  if T.null text
    then Nothing
    else do
      let (h, t) = T.breakOn needle text
      if T.null t
        then Nothing
        else return (h, T.tail t)

asFloatSize :: Int -> Maybe FloatSize
asFloatSize size =
  case size of
    16 ->
      Just FloatSize16
    32 ->
      Just FloatSize32
    64 ->
      Just FloatSize64
    _ ->
      Nothing

showIntSize :: IntSize -> T.Text
showIntSize size =
  "i" <> T.pack (show size)

showFloatSize :: FloatSize -> T.Text
showFloatSize size =
  "f" <> T.pack (show $ sizeAsInt size)

sizeAsInt :: FloatSize -> Int
sizeAsInt size =
  case size of
    FloatSize16 ->
      16
    FloatSize32 ->
      32
    FloatSize64 ->
      64
