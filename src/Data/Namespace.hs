module Data.Namespace where

import Control.Comonad.Cofree (Cofree (..))
import Data.Basic (EnumCase, EnumCaseF (EnumCaseLabel), Hint, Ident)
import Data.Global (currentGlobalLocatorRef, definiteSep, globalLocatorListRef, localLocatorListRef, locatorAliasMapRef, moduleAliasMapRef, nsSep)
import qualified Data.HashMap.Lazy as Map
import Data.IORef (modifyIORef', readIORef, writeIORef)
import Data.Log (raiseError)
import Data.LowType
  ( LowType (LowTypeFloat, LowTypeInt),
    asLowTypeMaybe,
    asPrimOp,
  )
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Internal as Text
import Data.Text.Internal.Search (indices)
import Data.WeakTerm
  ( WeakTerm,
    WeakTermF
      ( WeakTermConst,
        WeakTermEnum,
        WeakTermEnumIntro,
        WeakTermVar,
        WeakTermVarGlobal
      ),
  )

data Section
  = Section T.Text [T.Text]

{-# INLINE nsUnsafe #-}
nsUnsafe :: T.Text
nsUnsafe =
  "unsafe" <> nsSep

{-# INLINE nsOS #-}
nsOS :: T.Text
nsOS =
  "os" <> nsSep

attachSectionPrefix :: T.Text -> IO T.Text
attachSectionPrefix x = do
  currentGlobalLocator <- readIORef currentGlobalLocatorRef
  return $ currentGlobalLocator <> definiteSep <> x

activateGlobalLocator :: T.Text -> IO ()
activateGlobalLocator s =
  modifyIORef' globalLocatorListRef $ (:) s

activateLocalLocator :: T.Text -> IO ()
activateLocalLocator s =
  modifyIORef' localLocatorListRef $ (:) s

handleDefinePrefix :: Hint -> T.Text -> T.Text -> IO ()
handleDefinePrefix m from to = do
  aliasEnv <- readIORef locatorAliasMapRef
  if Map.member from aliasEnv
    then raiseError m $ "the prefix `" <> from <> "` is already registered"
    else writeIORef locatorAliasMapRef $ Map.insert from to aliasEnv

{-# INLINE resolveSymbol #-}
resolveSymbol :: Hint -> (T.Text -> Maybe b) -> T.Text -> [T.Text] -> IO (Maybe b)
resolveSymbol m predicate name candList = do
  case takeAll predicate candList [] of
    [] ->
      return Nothing
    [prefixedName] ->
      return $ predicate prefixedName
    candList' -> do
      let candInfo = T.concat $ map ("\n- " <>) candList'
      raiseError m $ "this `" <> name <> "` is ambiguous since it could refer to:" <> candInfo

constructCandList :: T.Text -> Bool -> IO [T.Text]
constructCandList name isDefinite = do
  prefixedNameList <- getPrefixedNameList name isDefinite
  print prefixedNameList
  moduleAliasMap <- readIORef moduleAliasMapRef
  locatorAliasMap <- readIORef locatorAliasMapRef
  return $ map (resolveName moduleAliasMap locatorAliasMap) prefixedNameList

getPrefixedNameList :: T.Text -> Bool -> IO [T.Text]
getPrefixedNameList name isDefinite = do
  if isDefinite
    then return [name]
    else do
      localLocatorList <- readIORef localLocatorListRef
      globalLocatorList <- readIORef globalLocatorListRef
      let localNameList = mapPrefix nsSep localLocatorList name
      let globalNameList = mapPrefix definiteSep globalLocatorList name
      return $ globalNameList ++ localNameList

mapPrefix :: T.Text -> [T.Text] -> T.Text -> [T.Text]
mapPrefix sep prefixList basename =
  map (<> sep <> basename) prefixList

breakOn :: T.Text -> T.Text -> Maybe (T.Text, T.Text)
breakOn pat src@(Text.Text arr off len)
  | T.null pat =
    Nothing
  | otherwise = case indices pat src of
    [] ->
      Nothing
    (x : _) ->
      Just (Text.text arr off x, Text.text arr (off + x) (len - x))

resolveName :: Map.HashMap T.Text T.Text -> Map.HashMap T.Text T.Text -> T.Text -> T.Text
resolveName moduleAliasMap locatorAliasMap name =
  resolveAlias nsSep moduleAliasMap $ resolveAlias definiteSep locatorAliasMap name

resolveAlias :: T.Text -> Map.HashMap T.Text T.Text -> T.Text -> T.Text
resolveAlias sep aliasMap currentName = do
  case breakOn sep currentName of
    Just (currentPrefix, currentSuffix)
      | Just newPrefix <- Map.lookup currentPrefix aliasMap ->
        newPrefix <> currentSuffix
    _ ->
      currentName

takeAll :: (T.Text -> Maybe b) -> [T.Text] -> [T.Text] -> [T.Text]
takeAll predicate candidateList acc =
  case candidateList of
    [] ->
      acc
    x : xs -> do
      case predicate x of
        Just _ ->
          takeAll predicate xs (x : acc)
        Nothing ->
          takeAll predicate xs acc

{-# INLINE asVar #-}
asVar :: Hint -> Map.HashMap T.Text t -> T.Text -> (t -> f (Cofree f Hint)) -> Maybe (Cofree f Hint)
asVar m nenv name f =
  Map.lookup name nenv >>= \x -> return (m :< f x)

{-# INLINE asWeakVar #-}
asWeakVar :: Hint -> Map.HashMap T.Text Ident -> T.Text -> Maybe WeakTerm
asWeakVar m nenv var =
  asVar m nenv var WeakTermVar

{-# INLINE asGlobalVar #-}
asGlobalVar :: Hint -> S.Set T.Text -> T.Text -> Maybe WeakTerm
asGlobalVar m nenv name =
  if S.member name nenv
    then Just (m :< WeakTermVarGlobal name)
    else Nothing

{-# INLINE asConstructor #-}
asConstructor :: Hint -> S.Set T.Text -> T.Text -> Maybe (Hint, T.Text)
asConstructor m nenv name =
  if S.member name nenv
    then Just (m, name)
    else Nothing

{-# INLINE findThenModify #-}
findThenModify :: Map.HashMap T.Text t -> (T.Text -> a) -> T.Text -> Maybe a
findThenModify env f name = do
  if name `Map.member` env
    then Just $ f name
    else Nothing

{-# INLINE asEnumLabel #-}
asEnumLabel :: Hint -> Map.HashMap T.Text (T.Text, Int) -> T.Text -> Maybe EnumCase
asEnumLabel m env name = do
  case Map.lookup name env of
    Just _ ->
      Just $ m :< EnumCaseLabel name
    _ ->
      Nothing

{-# INLINE asEnumIntro #-}
asEnumIntro :: Hint -> Map.HashMap T.Text (T.Text, Int) -> T.Text -> Maybe WeakTerm
asEnumIntro m env name = do
  case Map.lookup name env of
    Just (_, _) ->
      Just (m :< WeakTermEnumIntro name)
    _ ->
      Nothing

{-# INLINE asEnum #-}
asEnum :: Hint -> Map.HashMap T.Text a -> T.Text -> Maybe WeakTerm
asEnum m env name = do
  case Map.lookup name env of
    Just _ ->
      Just (m :< WeakTermEnum name)
    _ ->
      Nothing

{-# INLINE asWeakConstant #-}
asWeakConstant :: Hint -> T.Text -> Maybe WeakTerm
asWeakConstant m name
  | Just (LowTypeInt _) <- asLowTypeMaybe name =
    Just (m :< WeakTermConst name)
  | Just (LowTypeFloat _) <- asLowTypeMaybe name =
    Just (m :< WeakTermConst name)
  | Just _ <- asPrimOp name =
    Just (m :< WeakTermConst name)
  | otherwise = do
    Nothing

tryCand :: (Monad m) => m (Maybe a) -> m a -> m a
tryCand comp cont = do
  mx <- comp
  maybe cont return mx
