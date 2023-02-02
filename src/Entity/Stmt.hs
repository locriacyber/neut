module Entity.Stmt where

import Control.Comonad.Cofree
import Data.Binary
import qualified Data.Set as S
import qualified Data.Text as T
import Entity.Binder
import qualified Entity.DataInfo as DI
import qualified Entity.DefiniteDescription as DD
import qualified Entity.Discriminant as D
import Entity.Hint
import Entity.Ident
import qualified Entity.ImpArgNum as I
import qualified Entity.Opacity as O
import qualified Entity.RawTerm as RT
import qualified Entity.Section as Section
import qualified Entity.Source as Source
import qualified Entity.Term as TM
import qualified Entity.WeakTerm as WT
import qualified Entity.WeakTerm.ToText as WT
import GHC.Generics
import Path

type ConsInfo = (DD.DefiniteDescription, [BinderF TM.Term], D.Discriminant)

type PreProgram =
  (Path Abs File, [RawStmt])

data StmtKindF a
  = Normal O.Opacity
  | Data DD.DefiniteDescription [BinderF a] [(DD.DefiniteDescription, [BinderF a], D.Discriminant)]
  | DataIntro DD.DefiniteDescription [BinderF a] [BinderF a] D.Discriminant
  deriving (Generic)

-- opacity for elaboration
toOpacity :: StmtKindF a -> O.Opacity
toOpacity stmtKind =
  case stmtKind of
    Normal opacity ->
      opacity
    _ ->
      O.Transparent

-- opacity for clarification
toLowOpacity :: StmtKindF a -> O.Opacity
toLowOpacity stmtKind =
  case stmtKind of
    Normal opacity ->
      opacity
    Data {} ->
      O.Opaque -- so as not to reduce recursive terms
    _ ->
      O.Transparent

instance Binary a => Binary (StmtKindF a)

data RawStmt
  = RawStmtDefine
      (StmtKindF RT.RawTerm)
      Hint
      DD.DefiniteDescription
      I.ImpArgNum
      [BinderF RT.RawTerm]
      RT.RawTerm
      RT.RawTerm
  | RawStmtSection Section.Section [RawStmt]
  | RawStmtDefineResource Hint DD.DefiniteDescription RT.RawTerm RT.RawTerm

data WeakStmt
  = WeakStmtDefine
      (StmtKindF WT.WeakTerm)
      Hint
      DD.DefiniteDescription
      I.ImpArgNum
      [BinderF WT.WeakTerm]
      WT.WeakTerm
      WT.WeakTerm
  | WeakStmtDefineResource Hint DD.DefiniteDescription WT.WeakTerm WT.WeakTerm

type Program =
  (Source.Source, [Stmt])

data Stmt
  = StmtDefine
      (StmtKindF TM.Term)
      Hint
      DD.DefiniteDescription
      I.ImpArgNum
      [BinderF TM.Term]
      TM.Term
      TM.Term
  | StmtDefineResource Hint DD.DefiniteDescription TM.Term TM.Term
  deriving (Generic)

instance Binary Stmt

type PathSet = S.Set (Path Abs File)

newtype Cache = Cache
  { cacheStmtList :: [Stmt]
  }
  deriving (Generic)

instance Binary Cache

compress :: Stmt -> Stmt
compress stmt =
  case stmt of
    StmtDefine stmtKind m functionName impArgNum args codType _ ->
      case stmtKind of
        Normal O.Opaque ->
          StmtDefine stmtKind m functionName impArgNum args codType (m :< TM.Tau)
        _ ->
          stmt
    StmtDefineResource {} ->
      stmt

showStmt :: WeakStmt -> T.Text
showStmt stmt =
  case stmt of
    WeakStmtDefine _ m x _ xts codType e ->
      DD.reify x <> "\n" <> WT.toText (m :< WT.Pi xts codType) <> "\n" <> WT.toText (m :< WT.Pi xts e)
    _ ->
      "<define-resource>"

initialStmtList :: [Stmt]
initialStmtList = do
  flip concatMap enrichedEnumInfo $ \((dataName, dataArgs), introInfoList) -> do
    let formInfo' = defineEnum dataName dataArgs introInfoList
    let introInfoList' = map (defineEnumIntro dataName dataArgs) introInfoList
    formInfo' : introInfoList'

defineEnum :: DD.DefiniteDescription -> [BinderF TM.Term] -> [ConsInfo] -> Stmt
defineEnum dataName dataArgs consInfoList = do
  StmtDefine
    (Data dataName dataArgs consInfoList)
    internalHint
    dataName
    I.zero
    dataArgs
    (internalHint :< TM.Tau)
    (internalHint :< TM.Data dataName (map argToTerm dataArgs))

argToTerm :: BinderF TM.Term -> TM.Term
argToTerm (m, x, _) =
  m :< TM.Var x

defineEnumIntro ::
  DD.DefiniteDescription ->
  [BinderF TM.Term] ->
  ConsInfo ->
  Stmt
defineEnumIntro dataName dataArgs (consName, consArgs, discriminant) =
  StmtDefine
    (DataIntro dataName dataArgs consArgs discriminant)
    internalHint
    consName
    (I.fromInt $ length dataArgs)
    (dataArgs ++ consArgs)
    (internalHint :< TM.Data dataName (map argToTerm dataArgs))
    (internalHint :< TM.DataIntro dataName consName discriminant (map argToTerm dataArgs) (map argToTerm consArgs))

enrichedEnumInfo :: [((DD.DefiniteDescription, [BinderF TM.Term]), [ConsInfo])]
enrichedEnumInfo =
  addDiscriminants enumInfo

addDiscriminants :: [(a, [(b, c)])] -> [(a, [(b, c, D.Discriminant)])]
addDiscriminants info = do
  let (formInfo, introInfo) = unzip info
  zip formInfo $ map (addDiscriminants' D.zero) introInfo

addDiscriminants' :: D.Discriminant -> [(b, c)] -> [(b, c, D.Discriminant)]
addDiscriminants' d xs =
  case xs of
    [] ->
      []
    (x, y) : rest ->
      (x, y, d) : addDiscriminants' (D.increment d) rest

enumInfo :: [((DD.DefiniteDescription, [BinderF TM.Term]), [(DD.DefiniteDescription, [BinderF TM.Term])])]
enumInfo =
  [ ((DI.constBottom, []), []),
    ((DI.constTop, []), [(DI.constTopUnit, [])]),
    ((DI.constBool, []), [(DI.constBoolFalse, []), (DI.constBoolTrue, [])]),
    ( ( DI.constCoproduct,
        [ (internalHint, I ("a", 0), internalHint :< TM.Tau),
          (internalHint, I ("b", 1), internalHint :< TM.Tau)
        ]
      ),
      [ ( DI.constCoproductLeft,
          [(internalHint, I ("x", 2), internalHint :< TM.Var (I ("a", 0)))]
        ),
        ( DI.constCoproductRight,
          [(internalHint, I ("y", 3), internalHint :< TM.Var (I ("b", 1)))]
        )
      ]
    )
  ]
