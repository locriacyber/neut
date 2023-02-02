module Entity.Section where

import Data.Binary
import Data.Hashable
import qualified Entity.BaseName as BN
import GHC.Generics

type SectionStack = [Section]

newtype Section = Section {reify :: BN.BaseName}
  deriving (Generic, Show, Eq)

instance Binary Section

instance Hashable Section

dummySectionStack :: SectionStack
dummySectionStack =
  [Section BN.internalBaseName]
