module Scene.Elaborate
  ( elaborate,
    Context (..),
  )
where

import qualified Context.Definition as Definition
import qualified Context.Env as Env
import qualified Context.Global as Global
import qualified Context.Implicit as Implicit
import qualified Context.Locator as Locator
import qualified Context.Log as Log
import qualified Context.Throw as Throw
import qualified Context.Type as Type
import Control.Comonad.Cofree
import Control.Monad
import qualified Data.IntMap as IntMap
import Data.List
import qualified Data.Text as T
import Entity.Binder
import qualified Entity.DefiniteDescription as DD
import Entity.EnumCase
import Entity.EnumInfo
import qualified Entity.EnumTypeName as ET
import qualified Entity.EnumValueName as EV
import qualified Entity.GlobalName as GN
import Entity.Hint
import qualified Entity.HoleSubst as HS
import qualified Entity.Ident.Reify as Ident
import Entity.LamKind
import Entity.Pattern
import qualified Entity.Prim as Prim
import Entity.PrimNum
import qualified Entity.Source as Source
import Entity.Stmt
import Entity.Term
import qualified Entity.Term.Reduce as Term
import qualified Entity.Term.Subst as Subst
import Entity.Term.Weaken
import Entity.WeakTerm
import qualified Entity.WeakTerm.Subst as WeakTerm
import Entity.WeakTerm.ToText
import qualified Scene.Elaborate.Infer as Infer
import qualified Scene.Elaborate.Unify as Unify

class
  ( Infer.Context m,
    Unify.Context m,
    Subst.Context m,
    Log.Context m,
    Locator.Context m,
    Global.Context m,
    Definition.Context m
  ) =>
  Context m
  where
  initialize :: m ()
  saveCache :: Program -> [EnumInfo] -> m ()

elaborate :: Context m => Source.Source -> Either [Stmt] ([WeakStmt], [EnumInfo]) -> m [Stmt]
elaborate source cacheOrStmt = do
  initialize
  case cacheOrStmt of
    Left cache -> do
      forM_ cache registerTopLevelDef
      return cache
    Right (defList, enumInfoList) -> do
      mMainDefiniteDescription <- Locator.getMainDefiniteDescription source
      -- infer
      defList' <- mapM setupDef defList
      defList'' <- mapM (inferStmt mMainDefiniteDescription) defList'
      constraintList <- Env.getConstraintEnv
      -- unify
      Unify.unify constraintList >>= Env.setHoleSubst
      -- elaborate
      defList''' <- elaborateStmtList defList''
      saveCache (source, defList''') enumInfoList
      return defList'''

registerTopLevelDef :: Context m => Stmt -> m ()
registerTopLevelDef stmt = do
  case stmt of
    StmtDefine opacity m x impArgNum xts codType e -> do
      Implicit.insert x impArgNum
      Type.insert x $ weaken $ m :< TermPi xts codType
      Definition.insert opacity m x (map weakenBinder xts) (weaken e)
    StmtDefineResource m name _ _ ->
      Type.insert name $ m :< WeakTermTau

setupDef :: Context m => WeakStmt -> m WeakStmt
setupDef def =
  case def of
    WeakStmtDefine opacity m f impArgNum xts codType e -> do
      Type.insert f $ m :< WeakTermPi xts codType
      Implicit.insert f impArgNum
      Definition.insert opacity m f xts e
      return $ WeakStmtDefine opacity m f impArgNum xts codType e
    WeakStmtDefineResource m name discarder copier -> do
      Type.insert name $ m :< WeakTermTau
      return $ WeakStmtDefineResource m name discarder copier

inferStmt :: Infer.Context m => Maybe DD.DefiniteDescription -> WeakStmt -> m WeakStmt
inferStmt mMainDD stmt = do
  case stmt of
    WeakStmtDefine isReducible m x impArgNum xts codType e -> do
      (xts', e', codType') <- inferStmtDefine xts e codType
      when (Just x == mMainDD) $
        Env.insConstraintEnv (m :< WeakTermPi [] (i64 m)) (m :< WeakTermPi xts codType)
      return $ WeakStmtDefine isReducible m x impArgNum xts' codType' e'
    WeakStmtDefineResource m name discarder copier ->
      Infer.inferDefineResource m name discarder copier

inferStmtDefine ::
  Infer.Context m =>
  [BinderF WeakTerm] ->
  WeakTerm ->
  WeakTerm ->
  m ([BinderF WeakTerm], WeakTerm, WeakTerm)
inferStmtDefine xts e codType = do
  (xts', (e', te)) <- Infer.inferBinder [] xts e
  codType' <- Infer.inferType codType
  Env.insConstraintEnv codType' te
  return (xts', e', codType')

elaborateStmtList :: Context m => [WeakStmt] -> m [Stmt]
elaborateStmtList stmtList = do
  case stmtList of
    [] ->
      return []
    WeakStmtDefine opacity m x impArgNum xts codType e : rest -> do
      e' <- elaborate' e
      xts' <- mapM elaborateWeakBinder xts
      codType' <- elaborate' codType >>= Term.reduce
      Type.insert x $ weaken $ m :< TermPi xts' codType'
      Definition.insert opacity m x (map weakenBinder xts') (weaken e')
      rest' <- elaborateStmtList rest
      return $ StmtDefine opacity m x impArgNum xts' codType' e' : rest'
    WeakStmtDefineResource m name discarder copier : rest -> do
      discarder' <- elaborate' discarder
      copier' <- elaborate' copier
      rest' <- elaborateStmtList rest
      return $ StmtDefineResource m name discarder' copier' : rest'

elaborate' :: Context m => WeakTerm -> m Term
elaborate' term =
  case term of
    m :< WeakTermTau ->
      return $ m :< TermTau
    m :< WeakTermVar x ->
      return $ m :< TermVar x
    m :< WeakTermVarGlobal name arity ->
      return $ m :< TermVarGlobal name arity
    m :< WeakTermPi xts t -> do
      xts' <- mapM elaborateWeakBinder xts
      t' <- elaborate' t
      return $ m :< TermPi xts' t'
    m :< WeakTermPiIntro kind xts e -> do
      kind' <- elaborateKind kind
      xts' <- mapM elaborateWeakBinder xts
      e' <- elaborate' e
      return $ m :< TermPiIntro kind' xts' e'
    m :< WeakTermPiElim e es -> do
      e' <- elaborate' e
      es' <- mapM elaborate' es
      return $ m :< TermPiElim e' es'
    m :< WeakTermSigma xts -> do
      xts' <- mapM elaborateWeakBinder xts
      return $ m :< TermSigma xts'
    m :< WeakTermSigmaIntro es -> do
      es' <- mapM elaborate' es
      return $ m :< TermSigmaIntro es'
    m :< WeakTermSigmaElim xts e1 e2 -> do
      e1' <- elaborate' e1
      xts' <- mapM elaborateWeakBinder xts
      e2' <- elaborate' e2
      return $ m :< TermSigmaElim xts' e1' e2'
    m :< WeakTermLet mxt e1 e2 -> do
      e1' <- elaborate' e1
      mxt' <- elaborateWeakBinder mxt
      e2' <- elaborate' e2
      return $ m :< TermLet mxt' e1' e2'
    m :< WeakTermAster h es -> do
      holeSubst <- Env.getHoleSubst
      case HS.lookup h holeSubst of
        Nothing ->
          Throw.raiseError m "couldn't instantiate the hole here"
        Just (xs, e)
          | length xs == length es -> do
            let s = IntMap.fromList $ zip (map Ident.toInt xs) es
            WeakTerm.subst s e >>= elaborate'
          | otherwise ->
            Throw.raiseError m "arity mismatch"
    m :< WeakTermPrim x ->
      return $ m :< TermPrim x
    m :< WeakTermInt t x -> do
      t' <- elaborate' t >>= Term.reduce
      case t' of
        _ :< TermPrim (Prim.Type (PrimNumInt size)) ->
          return $ m :< TermInt size x
        _ -> do
          Throw.raiseError m $
            "the term `"
              <> T.pack (show x)
              <> "` is an integer, but its type is: "
              <> toText (weaken t')
    m :< WeakTermFloat t x -> do
      t' <- elaborate' t >>= Term.reduce
      case t' of
        _ :< TermPrim (Prim.Type (PrimNumFloat size)) ->
          return $ m :< TermFloat size x
        _ ->
          Throw.raiseError m $
            "the term `"
              <> T.pack (show x)
              <> "` is a float, but its type is:\n"
              <> toText (weaken t')
    m :< WeakTermEnum k ->
      return $ m :< TermEnum k
    m :< WeakTermEnumIntro label ->
      return $ m :< TermEnumIntro label
    m :< WeakTermEnumElim (e, t) les -> do
      e' <- elaborate' e
      let (ls, es) = unzip les
      es' <- mapM elaborate' es
      t' <- elaborate' t >>= Term.reduce
      case t' of
        _ :< TermEnum x -> do
          checkSwitchExaustiveness m x ls
          return $ m :< TermEnumElim (e', t') (zip ls es')
        _ ->
          Throw.raiseError m $
            "the type of `"
              <> toText (weaken e')
              <> "` must be an enum type, but is:\n"
              <> toText (weaken t')
    m :< WeakTermQuestion e t -> do
      e' <- elaborate' e
      t' <- elaborate' t
      Log.printNote m $ toText (weaken t')
      return e'
    m :< WeakTermMagic der -> do
      der' <- mapM elaborate' der
      return $ m :< TermMagic der'
    m :< WeakTermMatch mSubject (e, t) patList -> do
      mSubject' <- mapM elaborate' mSubject
      e' <- elaborate' e
      t' <- elaborate' t >>= Term.reduce
      case t' of
        _ :< TermPiElim (_ :< TermVarGlobal name _) _ -> do
          mConsInfoList <- Global.lookup name
          case mConsInfoList of
            Just (GN.Data _ consInfoList) -> do
              patList' <- elaboratePatternList m consInfoList patList
              return $ m :< TermMatch mSubject' (e', t') patList'
            _ ->
              Throw.raiseError (metaOf t) $
                "the type of this term must be a data-type, but its type is:\n" <> toText (weaken t')
        _ -> do
          Throw.raiseError (metaOf t) $
            "the type of this term must be a data-type, but its type is:\n" <> toText (weaken t')
    m :< WeakTermNoema s e -> do
      s' <- elaborate' s
      e' <- elaborate' e
      return $ m :< TermNoema s' e'
    m :< WeakTermNoemaIntro s e -> do
      e' <- elaborate' e
      return $ m :< TermNoemaIntro s e'
    m :< WeakTermNoemaElim s e -> do
      e' <- elaborate' e
      return $ m :< TermNoemaElim s e'
    m :< WeakTermArray elemType -> do
      elemType' <- elaborate' elemType
      case elemType' of
        _ :< TermPrim (Prim.Type (PrimNumInt size)) ->
          return $ m :< TermArray (PrimNumInt size)
        _ :< TermPrim (Prim.Type (PrimNumFloat size)) ->
          return $ m :< TermArray (PrimNumFloat size)
        _ ->
          Throw.raiseError m $
            "invalid element type:\n" <> toText (weaken elemType')
    m :< WeakTermArrayIntro elemType elems -> do
      elemType' <- elaborate' elemType
      elems' <- mapM elaborate' elems
      case elemType' of
        _ :< TermPrim (Prim.Type (PrimNumInt size)) ->
          return $ m :< TermArrayIntro (PrimNumInt size) elems'
        _ :< TermPrim (Prim.Type (PrimNumFloat size)) ->
          return $ m :< TermArrayIntro (PrimNumFloat size) elems'
        _ ->
          Throw.raiseError m $ "invalid element type:\n" <> toText (weaken elemType')
    m :< WeakTermArrayAccess subject elemType array index -> do
      subject' <- elaborate' subject
      elemType' <- elaborate' elemType
      array' <- elaborate' array
      index' <- elaborate' index
      case elemType' of
        _ :< TermPrim (Prim.Type (PrimNumInt size)) ->
          return $ m :< TermArrayAccess subject' (PrimNumInt size) array' index'
        _ :< TermPrim (Prim.Type (PrimNumFloat size)) ->
          return $ m :< TermArrayAccess subject' (PrimNumFloat size) array' index'
        _ ->
          Throw.raiseError m $ "invalid element type:\n" <> toText (weaken elemType')
    m :< WeakTermText ->
      return $ m :< TermText
    m :< WeakTermTextIntro text ->
      return $ m :< TermTextIntro text
    m :< WeakTermCell contentType -> do
      contentType' <- elaborate' contentType
      return $ m :< TermCell contentType'
    m :< WeakTermCellIntro contentType content -> do
      contentType' <- elaborate' contentType
      content' <- elaborate' content
      return $ m :< TermCellIntro contentType' content'
    m :< WeakTermCellRead cell -> do
      cell' <- elaborate' cell
      return $ m :< TermCellRead cell'
    m :< WeakTermCellWrite cell newValue -> do
      cell' <- elaborate' cell
      newValue' <- elaborate' newValue
      return $ m :< TermCellWrite cell' newValue'
    m :< WeakTermResourceType name ->
      return $ m :< TermResourceType name

-- for now
elaboratePatternList ::
  Context m =>
  Hint ->
  [DD.DefiniteDescription] ->
  [(PatternF WeakTerm, WeakTerm)] ->
  m [(PatternF Term, Term)]
elaboratePatternList m bs patList = do
  patList' <- forM patList $ \((mPat, c, arity, xts), body) -> do
    xts' <- mapM elaborateWeakBinder xts
    body' <- elaborate' body
    return ((mPat, c, arity, xts'), body')
  checkCaseSanity m bs patList'
  return patList'

checkCaseSanity :: Context m => Hint -> [DD.DefiniteDescription] -> [(PatternF Term, Term)] -> m ()
checkCaseSanity m bs patList =
  case (bs, patList) of
    ([], []) ->
      return ()
    (b : bsRest, ((mPat, b', _, _), _) : patListRest) -> do
      if b /= b'
        then
          Throw.raiseError mPat $
            "the constructor here is supposed to be `" <> DD.reify b <> "`, but is: `" <> DD.reify b' <> "`"
        else checkCaseSanity m bsRest patListRest
    (b : _, []) ->
      Throw.raiseError m $
        "found a non-exhaustive pattern; the clause for `" <> DD.reify b <> "` is missing"
    ([], ((mPat, b, _, _), _) : _) ->
      Throw.raiseError mPat $
        "found a redundant pattern; this clause for `" <> DD.reify b <> "` is redundant"

elaborateWeakBinder :: Context m => BinderF WeakTerm -> m (BinderF Term)
elaborateWeakBinder (m, x, t) = do
  t' <- elaborate' t
  return (m, x, t')

elaborateKind :: Context m => LamKindF WeakTerm -> m (LamKindF Term)
elaborateKind kind =
  case kind of
    LamKindNormal ->
      return LamKindNormal
    LamKindCons dataName consName consNumber dataType -> do
      dataType' <- elaborate' dataType
      return $ LamKindCons dataName consName consNumber dataType'
    LamKindFix xt -> do
      xt' <- elaborateWeakBinder xt
      return $ LamKindFix xt'

checkSwitchExaustiveness :: Context m => Hint -> ET.EnumTypeName -> [EnumCase] -> m ()
checkSwitchExaustiveness m enumTypeName caseList = do
  let containsDefaultCase = doesContainDefaultCase caseList
  enumSet <- lookupEnumSet m enumTypeName
  let len = toInteger $ length (nub caseList)
  unless (toInteger (length enumSet) <= len || containsDefaultCase) $
    Throw.raiseError m "this switch is ill-constructed in that it is not exhaustive"

lookupEnumSet :: Context m => Hint -> ET.EnumTypeName -> m [EV.EnumValueName]
lookupEnumSet m enumTypeName = do
  let name = ET.reify enumTypeName
  mEnumItems <- Global.lookup name
  case mEnumItems of
    Just (GN.EnumType enumItems) ->
      return $ map fst enumItems
    _ ->
      Throw.raiseError m $ "no such enum defined: " <> DD.reify name

doesContainDefaultCase :: [EnumCase] -> Bool
doesContainDefaultCase enumCaseList =
  case enumCaseList of
    [] ->
      False
    (_ :< EnumCaseDefault) : _ ->
      True
    _ : rest ->
      doesContainDefaultCase rest

-- cs <- readIORef constraintEnv
-- p "==========================================================="
-- forM_ cs $ \(e1, e2) -> do
--   p $ T.unpack $ toText e1
--   p $ T.unpack $ toText e2
--   p "---------------------"
