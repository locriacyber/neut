module Context.LLVM
  ( Context (..),
  )
where

import qualified Data.ByteString.Lazy as L
import Entity.OutputKind
import Path

type OutputPath = Path Abs File

class Monad m => Context m where
  emit :: L.ByteString -> [(OutputKind, OutputPath)] -> m ()
  link :: [Path Abs File] -> OutputPath -> m ()
