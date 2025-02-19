module Main (main) where

import Context.Log
import Context.Log.IO
import Control.Exception.Safe (catch)
import Control.Monad (filterM, forM_)
import Data.List (intercalate, sort)
import qualified Data.Text as T
import Path
  ( Abs,
    Dir,
    File,
    Path,
    PathException,
    addExtension,
    parseRelDir,
    splitExtension,
    stripProperPrefix,
    toFilePath,
    (</>),
  )
import Path.IO (getCurrentDir, listDirRecur, removeFile)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.Process (readProcess, readProcessWithExitCode)

main :: IO ()
main = do
  args <- getArgs
  relDirPathList <- mapM parseRelDir args
  currentDir <- getCurrentDir
  let testDirPathList = map (currentDir </>) relDirPathList
  forM_ testDirPathList $ \testDirPath -> do
    (_, contents) <- listDirRecur testDirPath
    progList <- filterM isSourceFile contents
    result <- test testDirPath $ sort progList
    if result
      then return ()
      else exitWith (ExitFailure 1)

test :: Path Abs Dir -> [Path Abs File] -> IO Bool
test _ [] = return True
test testDirPath [srcPath] = test' testDirPath srcPath
test testDirPath (srcPath : rest) = do
  b1 <- test' testDirPath srcPath
  putStr "\n"
  b2 <- test testDirPath rest
  return $ b1 && b2

test' :: Path Abs Dir -> Path Abs File -> IO Bool
test' testDirPath srcPath = do
  (binaryPath, _) <- splitExtension srcPath
  (code, out, _) <-
    readProcessWithExitCode
      "neut"
      [ "build",
        toFilePath srcPath,
        "-o",
        toFilePath binaryPath,
        "--no-color",
        "--no-log-location",
        "--no-log-level",
        "--clang-option",
        "-fsanitize=address,undefined -g"
      ]
      []
  result <-
    case code of
      ExitSuccess -> do
        result <- readProcess (toFilePath binaryPath) [] []
        removeFile binaryPath
        return $ out <> result
      ExitFailure _ ->
        return out
  answerPath <- addExtension ".answer" binaryPath
  expectedResult <- readFile $ toFilePath answerPath
  relSrcPath <- stripProperPrefix testDirPath srcPath
  (testName, _) <- splitExtension relSrcPath
  if result == expectedResult
    then do
      printPass' testLogContext $ T.pack $ toFilePath testName
      return True
    else do
      printFail' testLogContext $ T.pack $ toFilePath testName
      putStrLn $ prefixExpected <> stylize expectedResult
      putStrLn $ prefixFound <> stylize result
      return False

testLogContext :: LogContext IO
testLogContext =
  logContextIO

prefixExpected :: String
prefixExpected =
  "  expected: "

prefixFound :: String
prefixFound =
  "     found: "

pad :: String
pad =
  "            "

stylize :: String -> String
stylize str =
  case str of
    "" ->
      ""
    _ ->
      stylize' str

stylize' :: String -> String
stylize' str = do
  let ls = lines str
  intercalate "\n" $ head ls : map (pad ++) (tail ls)

isSourceFile :: Path Abs File -> IO Bool
isSourceFile path =
  isSourceFile' path `catch` returnFalse

returnFalse :: PathException -> IO Bool
returnFalse _ =
  return False

isSourceFile' :: Path Abs File -> IO Bool
isSourceFile' path = do
  (_, ext) <- splitExtension path
  case ext of
    ".neut" ->
      return True
    _ ->
      return False
