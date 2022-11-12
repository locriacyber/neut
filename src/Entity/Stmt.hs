module Entity.Stmt where

import Control.Comonad.Cofree
import Data.Binary
import qualified Data.Set as S
import Entity.Binder
import qualified Entity.DefiniteDescription as DD
import Entity.EnumInfo
import Entity.Hint
import qualified Entity.ImpArgNum as I
import qualified Entity.Opacity as O
import qualified Entity.RawTerm as RT
import qualified Entity.Section as Section
import qualified Entity.Source as Source
import qualified Entity.Term as TM
import qualified Entity.WeakTerm as WT
import GHC.Generics
import Path

type PreProgram =
  (Path Abs File, [RawStmt])

data RawStmt
  = RawStmtDefine O.Opacity Hint DD.DefiniteDescription I.ImpArgNum [BinderF RT.RawTerm] RT.RawTerm RT.RawTerm
  | RawStmtSection Section.Section [RawStmt]

data WeakStmt
  = WeakStmtDefine O.Opacity Hint DD.DefiniteDescription I.ImpArgNum [BinderF WT.WeakTerm] WT.WeakTerm WT.WeakTerm

type Program =
  (Source.Source, [Stmt])

data Stmt
  = StmtDefine O.Opacity Hint DD.DefiniteDescription I.ImpArgNum [BinderF TM.Term] TM.Term TM.Term
  deriving (Generic)

instance Binary Stmt

type PathSet = S.Set (Path Abs File)

data Cache = Cache
  { cacheStmtList :: [Stmt],
    cacheEnumInfo :: [EnumInfo]
  }
  deriving (Generic)

instance Binary Cache

compress :: Stmt -> Stmt
compress stmt =
  case stmt of
    StmtDefine opacity m functionName impArgNum args codType _ ->
      case opacity of
        O.Opaque ->
          StmtDefine opacity m functionName impArgNum args codType (m :< TM.Tau)
        _ ->
          stmt
