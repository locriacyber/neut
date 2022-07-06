module Act.Build
  ( build,
    check,
    BuildConfig (..),
    CheckConfig (..),
  )
where

import qualified Context.Alias as Alias
import qualified Context.App as App
import qualified Context.Gensym as Gensym
import qualified Context.Global as Global
import qualified Context.LLVM as LLVM
import qualified Context.Locator as Locator
import qualified Context.Log as Log
import qualified Context.Mode as Mode
import qualified Context.Throw as Throw
import Control.Monad
import qualified Data.ByteString.Lazy as L
import Data.Foldable
import qualified Data.HashMap.Lazy as Map
import qualified Data.Set as S
import qualified Data.Text as T
import Entity.AliasInfo
import Entity.Global
import Entity.Module
import qualified Entity.Module.Reflect as Module
import Entity.OutputKind
import Entity.Source
import Entity.Stmt
import qualified Entity.Target as Target
import Path
import Path.IO
import Scene.Clarify
import Scene.Elaborate
import Scene.Emit
import Scene.Lower
import Scene.Parse
import Scene.Unravel
import System.Exit
import qualified System.Info as System
import Prelude hiding (log)

data BuildConfig = BuildConfig
  { mTarget :: Maybe TargetString,
    mClangOptString :: Maybe String,
    buildLogCfg :: Log.Config,
    buildThrowCfg :: Throw.Config,
    shouldCancelAlloc :: Bool
  }

build :: Mode.Mode -> BuildConfig -> IO ()
build mode cfg = do
  throwCtx <- Mode.throwCtx mode $ buildThrowCfg cfg
  logCtx <- Mode.logCtx mode $ buildLogCfg cfg
  Throw.run throwCtx (Log.printLog logCtx) $ do
    ensureNotInLibDir throwCtx "build"
    mainModule <- Module.fromCurrentPath throwCtx
    case mTarget cfg of
      Just target ->
        build' mode throwCtx logCtx (shouldCancelAlloc cfg) target mainModule
      Nothing -> do
        forM_ (Map.keys $ moduleTarget mainModule) $ \target ->
          build' mode throwCtx logCtx (shouldCancelAlloc cfg) (T.unpack target) mainModule

build' ::
  Mode.Mode ->
  Throw.Context ->
  Log.Context ->
  Bool ->
  TargetString ->
  Module ->
  IO ()
build' mode throwCtx logCtx cancelAllocFlag target mainModule = do
  mainFilePath <- resolveTarget throwCtx mainModule target
  mainSource <- getMainSource mainModule mainFilePath
  (_, isObjectAvailable, hasCacheSet, hasObjectSet, sourceAliasMap, dependenceSeq) <- unravel throwCtx mainSource
  gensymCtx <- Mode.gensymCtx mode $ Gensym.Config {}
  globalCtx <-
    Mode.globalCtx mode $
      Global.Config
        { Global.throwCtx = throwCtx
        }
  let ctxCfg =
        CC
          { ccMode = mode,
            ccThrowCtx = throwCtx,
            ccLogCtx = logCtx,
            ccGlobalCtx = globalCtx,
            ccGensymCtx = gensymCtx,
            ccCancelAllocFlag = cancelAllocFlag,
            ccMainModule = mainModule,
            ccInitialSource = mainSource,
            ccSourceAliasMap = sourceAliasMap,
            ccHasCacheSet = hasCacheSet
          }
  mapM_ (compile ctxCfg hasObjectSet) dependenceSeq
  llvmCtx <- Mode.llvmCtx mode $ LLVM.Config {LLVM.throwCtx = throwCtx, LLVM.clangOptString = ""} -- fixme
  unless isObjectAvailable $ link llvmCtx target mainModule $ toList dependenceSeq

data ContextConfig = CC
  { ccMode :: Mode.Mode,
    ccThrowCtx :: Throw.Context,
    ccLogCtx :: Log.Context,
    ccGlobalCtx :: Global.Context,
    ccGensymCtx :: Gensym.Context,
    ccCancelAllocFlag :: Bool,
    ccMainModule :: Module,
    ccInitialSource :: Source,
    ccSourceAliasMap :: SourceAliasMap,
    ccHasCacheSet :: PathSet
  }

newCtx :: ContextConfig -> Source -> IO App.Context
newCtx cfg source = do
  llvmCtx <-
    Mode.llvmCtx (ccMode cfg) $
      LLVM.Config
        { LLVM.throwCtx = ccThrowCtx cfg,
          LLVM.clangOptString = "" -- fixme
        }
  locatorCtx <-
    Mode.locatorCtx (ccMode cfg) $
      Locator.Config
        { Locator.currentSource = source,
          Locator.mainModule = ccMainModule cfg,
          Locator.throwCtx = ccThrowCtx cfg
        }
  aliasCtx <-
    Mode.aliasCtx (ccMode cfg) $
      Alias.Config
        { Alias.currentModule = sourceModule source,
          Alias.mainModule = ccMainModule cfg,
          Alias.throwCtx = ccThrowCtx cfg,
          Alias.locatorCtx = locatorCtx
        }
  return $
    App.Context
      { App.log = ccLogCtx cfg,
        App.throw = ccThrowCtx cfg,
        App.gensym = ccGensymCtx cfg,
        App.llvm = llvmCtx,
        App.global = ccGlobalCtx cfg,
        App.locator = locatorCtx,
        App.alias = aliasCtx,
        App.shouldCancelAlloc = ccCancelAllocFlag cfg,
        App.initialSource = ccInitialSource cfg,
        App.target =
          Target.Target
            { Target.os = System.os,
              Target.arch = System.arch
            },
        App.sourceAliasMap = ccSourceAliasMap cfg,
        App.hasCacheSet = ccHasCacheSet cfg
      }

data CheckConfig = CheckConfig
  { mFilePathString :: Maybe FilePath,
    checkLogCfg :: Log.Config,
    checkThrowCfg :: Throw.Config
  }

check :: Mode.Mode -> CheckConfig -> IO ()
check mode cfg = do
  throwCtx <- Mode.throwCtx mode $ checkThrowCfg cfg
  logCtx <- Mode.logCtx mode $ checkLogCfg cfg
  Throw.run throwCtx (Log.printLog logCtx) $ do
    ensureNotInLibDir throwCtx "check"
    mainModule <- Module.fromCurrentPath throwCtx
    case mFilePathString cfg of
      Just filePathStr -> do
        filePath <- resolveFile' filePathStr
        check' mode throwCtx logCtx filePath mainModule
      Nothing -> do
        forM_ (Map.elems $ moduleTarget mainModule) $ \relPath ->
          check' mode throwCtx logCtx (getSourceDir mainModule </> relPath) mainModule

check' :: Mode.Mode -> Throw.Context -> Log.Context -> Path Abs File -> Module -> IO ()
check' mode throwCtx logCtx filePath mainModule = do
  ensureFileModuleSanity throwCtx filePath mainModule
  let source = Source {sourceModule = mainModule, sourceFilePath = filePath}
  (_, _, hasCacheSet, _, sourceAliasMap, dependenceSeq) <- unravel throwCtx source
  globalCtx <- Mode.globalCtx mode $ Global.Config {Global.throwCtx = throwCtx}
  gensymCtx <- Mode.gensymCtx mode $ Gensym.Config {}
  let ctxCfg =
        CC
          { ccMode = mode,
            ccThrowCtx = throwCtx,
            ccLogCtx = logCtx,
            ccGlobalCtx = globalCtx,
            ccGensymCtx = gensymCtx,
            ccCancelAllocFlag = False,
            ccMainModule = mainModule,
            ccInitialSource = source,
            ccSourceAliasMap = sourceAliasMap,
            ccHasCacheSet = hasCacheSet
          }
  mapM_ (check'' ctxCfg) dependenceSeq

ensureFileModuleSanity :: Throw.Context -> Path Abs File -> Module -> IO ()
ensureFileModuleSanity ctx filePath mainModule = do
  unless (isProperPrefixOf (getSourceDir mainModule) filePath) $ do
    Throw.raiseError' ctx "the specified file is not in the current module"

ensureNotInLibDir :: Throw.Context -> T.Text -> IO ()
ensureNotInLibDir ctx commandName = do
  currentDir <- getCurrentDir
  libDir <- getLibraryDirPath
  when (isProperPrefixOf libDir currentDir) $
    Throw.raiseError' ctx $
      "the subcommand `" <> commandName <> "` cannot be run under the library directory"

check'' :: ContextConfig -> Source -> IO ()
check'' ctxCfg source = do
  ctx <- newCtx ctxCfg source
  mMainFunctionName <- getMainFunctionName ctx source
  case mMainFunctionName of
    Just mainName ->
      void $ parseMain ctx mainName source >>= elaborateMain ctx mainName source
    Nothing ->
      void $ parseOther ctx source >>= elaborateOther ctx source

compile ::
  ContextConfig ->
  S.Set (Path Abs File) ->
  Source ->
  IO ()
compile ctxCfg hasObjectSet source = do
  ctx <- newCtx ctxCfg source
  if S.member (sourceFilePath source) hasObjectSet
    then loadTopLevelDefinitions ctx source
    else compile' ctx source

loadTopLevelDefinitions :: App.Context -> Source -> IO ()
loadTopLevelDefinitions ctx source = do
  mMainFunctionName <- getMainFunctionNameIfEntryPoint ctx source
  case mMainFunctionName of
    Just mainName ->
      void $ parseMain ctx mainName source >>= elaborateMain ctx mainName source >>= clarifyMain ctx mainName
    Nothing ->
      void $ parseOther ctx source >>= elaborateOther ctx source >>= clarifyOther ctx

compile' :: App.Context -> Source -> IO ()
compile' ctx source = do
  llvmCode <- compileToLLVM ctx source
  outputPath <- sourceToOutputPath OutputKindObject source
  ensureDir $ parent outputPath
  llvmOutputPath <- sourceToOutputPath OutputKindLLVM source
  L.writeFile (toFilePath llvmOutputPath) llvmCode
  LLVM.emit (App.llvm ctx) OutputKindObject llvmCode outputPath

compileToLLVM :: App.Context -> Source -> IO L.ByteString
compileToLLVM ctx source = do
  mMainFunctionName <- getMainFunctionNameIfEntryPoint ctx source
  case mMainFunctionName of
    Just mainName -> do
      parseMain ctx mainName source
        >>= elaborateMain ctx mainName source
        >>= clarifyMain ctx mainName
        >>= lowerMain ctx
        >>= emitMain ctx
    Nothing -> do
      parseOther ctx source
        >>= elaborateOther ctx source
        >>= clarifyOther ctx
        >>= lowerOther ctx
        >> emitOther ctx

link :: LLVM.Context -> TargetString -> Module -> [Source] -> IO ()
link ctx target mainModule sourceList = do
  outputPath <- getExecutableOutputPath target mainModule
  objectPathList <- mapM (sourceToOutputPath OutputKindObject) sourceList
  LLVM.link ctx objectPathList outputPath

getExecutableOutputPath :: TargetString -> Module -> IO (Path Abs File)
getExecutableOutputPath target mainModule =
  resolveFile (getExecutableDir mainModule) target

getMainSource :: Module -> Path Abs File -> IO Source
getMainSource mainModule mainSourceFilePath = do
  return $
    Source
      { sourceModule = mainModule,
        sourceFilePath = mainSourceFilePath
      }

getMainFunctionName :: App.Context -> Source -> IO (Maybe T.Text)
getMainFunctionName ctx source = do
  b <- isMainFile source
  if b
    then return <$> getMainFunctionName' ctx
    else return Nothing

getMainFunctionNameIfEntryPoint :: App.Context -> Source -> IO (Maybe T.Text)
getMainFunctionNameIfEntryPoint ctx source = do
  if sourceFilePath source == sourceFilePath (App.initialSource ctx)
    then return <$> getMainFunctionName' ctx
    else return Nothing

getMainFunctionName' :: App.Context -> IO T.Text
getMainFunctionName' ctx = do
  Locator.attachCurrentLocator (App.locator ctx) "main"

type TargetString =
  String

resolveTarget :: Throw.Context -> Module -> TargetString -> IO (Path Abs File)
resolveTarget ctx mainModule target = do
  case getTargetFilePath mainModule (T.pack target) of
    Just path ->
      return path
    Nothing -> do
      _ <- Throw.raiseError' ctx $ "no such target is defined: `" <> T.pack target <> "`"
      exitWith (ExitFailure 1)
