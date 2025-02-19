module Entity.Hint where

import Data.Binary
import GHC.Generics

data Hint = Hint
  { metaFileName :: FilePath,
    metaLocation :: Loc
  }
  deriving (Generic)

type Line =
  Int

type Column =
  Int

type Loc =
  (Line, Column)

instance Binary Hint

instance Show Hint where
  show _ =
    "_"

instance Eq Hint where
  _ == _ = True

new :: Int -> Int -> FilePath -> Hint
new l c path =
  Hint
    { metaFileName = path,
      metaLocation = (l, c)
    }

internalHint :: Hint
internalHint =
  Hint
    { metaFileName = "<internal>",
      metaLocation = (0, 0)
    }
