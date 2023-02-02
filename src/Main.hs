module Main (main) where

import qualified Act.Build as Build
import qualified Act.Check as Check
import qualified Act.Clean as Clean
import qualified Act.Get as Get
import qualified Act.Init as Init
import qualified Act.Release as Release
import qualified Act.Run as Run
import qualified Act.Tidy as Tidy
import qualified Act.Version as Version
import qualified Case.Main as Main
import qualified Context.Log as Log
import qualified Data.Text as T
import Entity.ModuleURL
import qualified Entity.OutputKind as OK
import Entity.Target
import Options.Applicative

data Command
  = Build Build.Config
  | Run Run.Config
  | Check Check.Config
  | Clean Clean.Config
  | Release Release.Config
  | Get Get.Config
  | Tidy Tidy.Config
  | Init Init.Config
  | ShowVersion Version.Config

main :: IO ()
main = do
  c <- execParser (info (helper <*> parseOpt) fullDesc)
  case c of
    Build cfg -> do
      Main.build cfg
    Run cfg -> do
      Main.run cfg
    Check cfg -> do
      Main.check cfg
    Clean cfg ->
      Main.clean cfg
    Release cfg ->
      Main.release cfg
    Init cfg ->
      Main.initialize cfg
    Get cfg ->
      Main.get cfg
    Tidy cfg ->
      Main.tidy cfg
    ShowVersion cfg ->
      Main.version cfg

cmd :: String -> Parser a -> String -> Mod CommandFields a
cmd name parser desc =
  command name (info (helper <*> parser) (progDesc desc))

parseOpt :: Parser Command
parseOpt = do
  subparser $
    mconcat
      [ cmd "build" parseBuildOpt "build given target",
        cmd "run" parseRunOpt "build and run given target",
        cmd "clean" parseCleanOpt "remove the resulting files",
        cmd "check" parseCheckOpt "type-check specified file",
        cmd "release" parseReleaseOpt "create a release tar from a given path",
        cmd "init" parseInitOpt "create a new module",
        cmd "get" parseGetOpt "get a release tar",
        cmd "tidy" parseTidyOpt "tidy the module dependency",
        cmd "version" parseVersionOpt "show version info"
      ]

parseBuildOpt :: Parser Command
parseBuildOpt = do
  mTarget <- optional $ argument str $ mconcat [metavar "TARGET", help "The build target"]
  mClangOpt <- optional $ strOption $ mconcat [long "clang-option", metavar "OPT", help "Options for clang"]
  logCfg <- logConfigOpt
  shouldCancelAlloc <- cancelAllocOpt
  outputKindList <- outputKindListOpt
  shouldSkipLink <- shouldSkipLinkOpt
  pure $
    Build
      Build.Config
        { Build.mTarget = Target <$> mTarget,
          Build.mClangOptString = mClangOpt,
          Build.logCfg = logCfg,
          Build.shouldCancelAlloc = shouldCancelAlloc,
          Build.outputKindList = outputKindList,
          Build.shouldSkipLink = shouldSkipLink
        }

parseRunOpt :: Parser Command
parseRunOpt = do
  target <- argument str $ mconcat [metavar "TARGET", help "The build target"]
  mClangOpt <- optional $ strOption $ mconcat [long "clang-option", metavar "OPT", help "Options for clang"]
  logCfg <- logConfigOpt
  shouldCancelAlloc <- cancelAllocOpt
  pure $
    Run
      Run.Config
        { Run.target = Target target,
          Run.mClangOptString = mClangOpt,
          Run.logCfg = logCfg,
          Run.shouldCancelAlloc = shouldCancelAlloc
        }

parseCleanOpt :: Parser Command
parseCleanOpt = do
  logCfg <- logConfigOpt
  pure $
    Clean
      Clean.Config
        { Clean.logCfg = logCfg
        }

parseGetOpt :: Parser Command
parseGetOpt = do
  moduleAlias <- argument str (mconcat [metavar "ALIAS", help "The alias of the module"])
  moduleURL <- argument str (mconcat [metavar "URL", help "The URL of the archive"])
  logCfg <- logConfigOpt
  pure $
    Get
      Get.Config
        { Get.moduleAliasText = T.pack moduleAlias,
          Get.moduleURL = ModuleURL $ T.pack moduleURL,
          Get.logCfg = logCfg
        }

parseTidyOpt :: Parser Command
parseTidyOpt = do
  logCfg <- logConfigOpt
  pure $
    Tidy
      Tidy.Config
        { Tidy.logCfg = logCfg
        }

parseInitOpt :: Parser Command
parseInitOpt = do
  moduleName <- argument str (mconcat [metavar "MODULE", help "The name of the module"])
  logCfg <- logConfigOpt
  pure $
    Init
      Init.Config
        { Init.moduleName = T.pack moduleName,
          Init.logCfg = logCfg
        }

parseVersionOpt :: Parser Command
parseVersionOpt =
  pure $ ShowVersion Version.Config {}

parseCheckOpt :: Parser Command
parseCheckOpt = do
  inputFilePath <- optional $ argument str (mconcat [metavar "INPUT", help "The path of input file"])
  logCfg <- logConfigOpt
  pure $
    Check
      Check.Config
        { Check.mFilePathString = inputFilePath,
          Check.logCfg = logCfg
        }

logConfigOpt :: Parser Log.Config
logConfigOpt = do
  shouldColorize <- colorizeOpt
  eoe <- T.pack <$> endOfEntryOpt
  pure
    Log.Config
      { Log.shouldColorize = shouldColorize,
        Log.endOfEntry = eoe
      }

endOfEntryOpt :: Parser String
endOfEntryOpt =
  strOption (mconcat [long "end-of-entry", value "", help "String printed after each entry", metavar "STRING"])

colorizeOpt :: Parser Bool
colorizeOpt =
  flag
    True
    False
    ( mconcat
        [ long "no-color",
          help "Set this to disable colorization of the output"
        ]
    )

cancelAllocOpt :: Parser Bool
cancelAllocOpt =
  flag
    True
    False
    ( mconcat
        [ long "no-cancel-alloc",
          help "Set this to disable cancelling malloc/free"
        ]
    )

shouldSkipLinkOpt :: Parser Bool
shouldSkipLinkOpt =
  flag
    False
    True
    ( mconcat
        [ long "skip-link",
          help "Set this to skip linking"
        ]
    )

outputKindListOpt :: Parser [OK.OutputKind]
outputKindListOpt = do
  option outputKindListReader $ mconcat [long "emit", metavar "EMIT", help "llvm, asm, or object", value [OK.Object]]

outputKindListReader :: ReadM [OK.OutputKind]
outputKindListReader =
  eitherReader $ \input ->
    readOutputKinds $ T.splitOn "," $ T.pack input

readOutputKinds :: [T.Text] -> Either String [OK.OutputKind]
readOutputKinds kindStrList =
  case kindStrList of
    [] ->
      return []
    kindStr : rest -> do
      tmp <- readOutputKinds rest
      case kindStr of
        "llvm" ->
          return $ OK.LLVM : tmp
        "asm" ->
          return $ OK.Asm : tmp
        "object" ->
          return $ OK.Object : tmp
        _ ->
          Left $ T.unpack $ "no such output kind exists: " <> kindStr

parseReleaseOpt :: Parser Command
parseReleaseOpt = do
  releaseName <- argument str (mconcat [metavar "NAME", help "The name of the release"])
  logCfg <- logConfigOpt
  pure $
    Release
      Release.Config
        { Release.getReleaseName = releaseName,
          Release.logCfg = logCfg
        }
