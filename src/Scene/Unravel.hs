module Scene.Unravel
  ( unravel,
    Context,
  )
where

import qualified Context.Env as Env
import qualified Context.Module as Module
import qualified Context.Path as Path
import qualified Context.Throw as Throw
import Control.Monad
import Data.Foldable
import qualified Data.HashMap.Strict as Map
import Data.List (unzip4)
import Data.Sequence as Seq
  ( Seq,
    empty,
    (><),
    (|>),
  )
import qualified Data.Set as S
import qualified Data.Text as T
import Entity.Hint
import qualified Entity.OutputKind as OK
import qualified Entity.Source as Source
import qualified Entity.VisitInfo as VI
import Path
import qualified Scene.Parse.Core as ParseCore
import qualified Scene.Parse.Import as Parse

type IsCacheAvailable =
  Bool

type IsObjectAvailable =
  Bool

type IsLLVMAvailable =
  Bool

class
  ( Throw.Context m,
    Path.Context m,
    Module.Context m,
    Env.Context m,
    Source.Context m,
    Parse.Context m
  ) =>
  Context m

unravel ::
  Context m =>
  Source.Source ->
  m (IsCacheAvailable, IsLLVMAvailable, IsObjectAvailable, Seq Source.Source)
unravel source = do
  unravel' source

unravel' :: Context m => Source.Source -> m (IsCacheAvailable, IsLLVMAvailable, IsObjectAvailable, Seq Source.Source)
unravel' source = do
  visitEnv <- Env.getVisitEnv
  let path = Source.sourceFilePath source
  case Map.lookup path visitEnv of
    Just VI.Active ->
      raiseCyclicPath source
    Just VI.Finish -> do
      hasCacheSet <- Env.getHasCacheSet
      hasLLVMSet <- Env.getHasObjectSet
      hasObjectSet <- Env.getHasObjectSet
      return (path `S.member` hasCacheSet, path `S.member` hasLLVMSet, path `S.member` hasObjectSet, Seq.empty)
    Nothing -> do
      Env.insertToVisitEnv path VI.Active
      Env.pushToTraceSourceList source
      children <- getChildren source
      (isCacheAvailableList, isLLVMAvailableList, isObjectAvailableList, seqList) <- unzip4 <$> mapM unravel' children
      _ <- Env.popFromTraceSourceList
      Env.insertToVisitEnv path VI.Finish
      isCacheAvailable <- checkIfCacheIsAvailable isCacheAvailableList source
      isLLVMAvailable <- checkIfLLVMIsAvailable isLLVMAvailableList source
      isObjectAvailable <- checkIfObjectIsAvailable isObjectAvailableList source
      return (isCacheAvailable, isLLVMAvailable, isObjectAvailable, foldl' (><) Seq.empty seqList |> source)

checkIfCacheIsAvailable :: Context m => [IsCacheAvailable] -> Source.Source -> m IsCacheAvailable
checkIfCacheIsAvailable = do
  checkIfItemIsAvailable isFreshCacheAvailable Env.insertToHasCacheSet

checkIfLLVMIsAvailable :: Context m => [IsLLVMAvailable] -> Source.Source -> m IsLLVMAvailable
checkIfLLVMIsAvailable = do
  checkIfItemIsAvailable isFreshLLVMAvailable Env.insertToHasLLVMSet

checkIfObjectIsAvailable :: Context m => [IsObjectAvailable] -> Source.Source -> m IsObjectAvailable
checkIfObjectIsAvailable = do
  checkIfItemIsAvailable isFreshObjectAvailable Env.insertToHasObjectSet

checkIfItemIsAvailable ::
  Context m =>
  (Source.Source -> m Bool) ->
  (Path Abs File -> m ()) ->
  [IsObjectAvailable] ->
  Source.Source ->
  m IsObjectAvailable
checkIfItemIsAvailable isFreshItemAvailable inserter isObjectAvailableList source = do
  b <- isFreshItemAvailable source
  let isObjectAvailable = and $ b : isObjectAvailableList
  when isObjectAvailable $ inserter $ Source.sourceFilePath source
  return isObjectAvailable

isFreshCacheAvailable :: Context m => Source.Source -> m Bool
isFreshCacheAvailable source = do
  cachePath <- Source.getSourceCachePath source
  isItemAvailable source cachePath

isFreshLLVMAvailable :: Context m => Source.Source -> m Bool
isFreshLLVMAvailable source = do
  llvmPath <- Source.sourceToOutputPath OK.LLVM source
  isItemAvailable source llvmPath

isFreshObjectAvailable :: Context m => Source.Source -> m Bool
isFreshObjectAvailable source = do
  objectPath <- Source.sourceToOutputPath OK.Object source
  isItemAvailable source objectPath

isItemAvailable :: Context m => Source.Source -> Path Abs File -> m Bool
isItemAvailable source itemPath = do
  existsItem <- Path.doesFileExist itemPath
  if not existsItem
    then return False
    else do
      srcModTime <- Path.getModificationTime $ Source.sourceFilePath source
      itemModTime <- Path.getModificationTime itemPath
      return $ itemModTime > srcModTime

raiseCyclicPath :: Context m => Source.Source -> m a
raiseCyclicPath source = do
  traceSourceList <- Env.getTraceSourceList
  let m = Entity.Hint.new 1 1 $ toFilePath $ Source.sourceFilePath source
  let cyclicPathList = map Source.sourceFilePath $ reverse $ source : traceSourceList
  Throw.raiseError m $ "found a cyclic inclusion:\n" <> showCyclicPath cyclicPathList

showCyclicPath :: [Path Abs File] -> T.Text
showCyclicPath pathList =
  case pathList of
    [] ->
      ""
    [path] ->
      T.pack (toFilePath path)
    path : ps ->
      "     " <> T.pack (toFilePath path) <> showCyclicPath' ps

showCyclicPath' :: [Path Abs File] -> T.Text
showCyclicPath' pathList =
  case pathList of
    [] ->
      ""
    [path] ->
      "\n  ~> " <> T.pack (toFilePath path)
    path : ps ->
      "\n  ~> " <> T.pack (toFilePath path) <> showCyclicPath' ps

getChildren :: Context m => Source.Source -> m [Source.Source]
getChildren currentSource = do
  sourceChildrenMap <- Env.getSourceChildrenMap
  let currentSourceFilePath = Source.sourceFilePath currentSource
  case Map.lookup currentSourceFilePath sourceChildrenMap of
    Just sourceList ->
      return sourceList
    Nothing -> do
      let path = Source.sourceFilePath currentSource
      (sourceList, aliasInfoList) <- ParseCore.run Parse.parseImportSequence path
      Env.insertToSourceChildrenMap currentSourceFilePath sourceList
      Env.insertToSourceAliasMap currentSourceFilePath aliasInfoList
      return sourceList
