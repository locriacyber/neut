module Context.Module where

import qualified Data.Text as T
import Entity.Hint
import Entity.Module
import Entity.ModuleID
import qualified Entity.StrictGlobalLocator as SGL
import Path

class Monad m => Context m where
  getModuleFilePath :: Maybe Hint -> ModuleID -> m (Path Abs File)
  getModule :: Hint -> ModuleID -> T.Text -> m Module
  getSourcePath :: SGL.StrictGlobalLocator -> m (Path Abs File)
