module Context.Log
  ( Context (..),
    Config (..),
    printNote,
    printNote',
    printWarning,
    printWarning',
    printError,
    printError',
    printCritical,
    printCritical',
    printPass,
    printPass',
    printFail,
    printFail',
  )
where

import qualified Context.Env as Env
import qualified Data.Text as T
import qualified Entity.FilePos as FilePos
import Entity.Hint
import qualified Entity.Log as L

data Config = Config
  { shouldColorize :: Bool,
    endOfEntry :: T.Text
  }

class Env.Context m => Context m where
  printLog :: L.Log -> m ()

printNote :: Context m => Hint -> T.Text -> m ()
printNote =
  printLogWithFilePos L.Note

printNote' :: Context m => T.Text -> m ()
printNote' =
  printLogWithoutFilePos L.Note

printWarning :: Context m => Hint -> T.Text -> m ()
printWarning =
  printLogWithFilePos L.Warning

printWarning' :: Context m => T.Text -> m ()
printWarning' =
  printLogWithoutFilePos L.Warning

printError :: Context m => Hint -> T.Text -> m ()
printError =
  printLogWithFilePos L.Error

printError' :: Context m => T.Text -> m ()
printError' =
  printLogWithoutFilePos L.Error

printCritical :: Context m => Hint -> T.Text -> m ()
printCritical =
  printLogWithFilePos L.Critical

printCritical' :: Context m => T.Text -> m ()
printCritical' =
  printLogWithoutFilePos L.Critical

printPass :: Context m => Hint -> T.Text -> m ()
printPass =
  printLogWithFilePos L.Pass

printPass' :: Context m => T.Text -> m ()
printPass' =
  printLogWithoutFilePos L.Pass

printFail :: Context m => Hint -> T.Text -> m ()
printFail =
  printLogWithFilePos L.Fail

printFail' :: Context m => T.Text -> m ()
printFail' =
  printLogWithoutFilePos L.Fail

printLogWithFilePos :: Context m => L.LogLevel -> Hint -> T.Text -> m ()
printLogWithFilePos level m txt = do
  printLog (Just (FilePos.fromHint m), level, txt)

printLogWithoutFilePos :: Context m => L.LogLevel -> T.Text -> m ()
printLogWithoutFilePos level txt =
  printLog (Nothing, level, txt)
