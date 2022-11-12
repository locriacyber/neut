module Scene.Parse
  ( parse,
    Context (..),
  )
where

import qualified Context.Alias as Alias
import qualified Context.Env as Env
import qualified Context.Gensym as Gensym
import qualified Context.Global as Global
import qualified Context.Locator as Locator
import qualified Context.Throw as Throw
import Control.Comonad.Cofree hiding (section)
import Control.Monad
import Control.Monad.Trans
import qualified Data.HashMap.Strict as Map
import qualified Data.Text as T
import Entity.AliasInfo
import qualified Entity.Arity as A
import qualified Entity.BaseName as BN
import Entity.Binder
import Entity.Const
import qualified Entity.DefiniteDescription as DD
import qualified Entity.DefiniteLocator as DL
import qualified Entity.Discriminant as D
import Entity.EnumInfo
import qualified Entity.GlobalLocator as GL
import qualified Entity.GlobalName as GN
import Entity.Hint
import qualified Entity.Ident.Reflect as Ident
import qualified Entity.Ident.Reify as Ident
import qualified Entity.ImpArgNum as I
import qualified Entity.LamKind as LK
import qualified Entity.LocalLocator as LL
import qualified Entity.Opacity as O
import qualified Entity.RawTerm as RT
import qualified Entity.Section as Section
import qualified Entity.Source as Source
import Entity.Stmt
import qualified Entity.StrictGlobalLocator as SGL
import Path
import qualified Scene.Parse.Core as P
import qualified Scene.Parse.Discern as Discern
import qualified Scene.Parse.Enum as Enum
import qualified Scene.Parse.Import as Parse
import Scene.Parse.RawTerm
import Text.Megaparsec hiding (parse)

class
  ( Alias.Context m,
    Gensym.Context m,
    Global.Context m,
    Locator.Context m,
    Throw.Context m,
    Env.Context m,
    Enum.Context m,
    Discern.Context m,
    Parse.Context m,
    P.Context m
  ) =>
  Context m
  where
  loadCache :: Source.Source -> PathSet -> m (Maybe Cache)

--
-- core functions
--

parse :: Context m => Source.Source -> m (Either [Stmt] ([WeakStmt], [EnumInfo]))
parse source = do
  result <- parseSource source
  mMainDD <- Locator.getMainDefiniteDescription source
  case mMainDD of
    Just mainDD -> do
      let m = Entity.Hint.new 1 1 $ toFilePath $ Source.sourceFilePath source
      ensureMain m mainDD
      return result
    Nothing ->
      return result

parseSource :: Context m => Source.Source -> m (Either [Stmt] ([WeakStmt], [EnumInfo]))
parseSource source = do
  hasCacheSet <- Env.getHasCacheSet
  mCache <- loadCache source hasCacheSet
  case mCache of
    Just cache -> do
      let hint = Entity.Hint.new 1 1 $ toFilePath $ Source.sourceFilePath source
      forM_ (cacheEnumInfo cache) $ \enumInfo ->
        uncurry (Global.registerEnum hint) (fromEnumInfo enumInfo)
      let stmtList = cacheStmtList cache
      forM_ stmtList $ \stmt -> do
        case stmt of
          StmtDefine _ _ name _ args _ _ ->
            Global.registerTopLevelFunc hint name $ A.fromInt (length args)
      return $ Left stmtList
    Nothing -> do
      sourceAliasMap <- Env.getSourceAliasMap
      case Map.lookup (Source.sourceFilePath source) sourceAliasMap of
        Nothing ->
          Throw.raiseCritical' "[activateAliasInfoOfCurrentFile] (compiler bug)"
        Just aliasInfoList ->
          activateAliasInfo aliasInfoList
      (defList, enumInfoList) <- P.run program $ Source.sourceFilePath source
      return $ Right (defList, enumInfoList)

ensureMain :: Context m => Hint -> DD.DefiniteDescription -> m ()
ensureMain m mainFunctionName = do
  mMain <- Global.lookup mainFunctionName
  case mMain of
    Just (GN.TopLevelFunc _) ->
      return ()
    _ ->
      Throw.raiseError m "`main` is missing"

program :: Context m => P.Parser m ([WeakStmt], [EnumInfo])
program = do
  Parse.skipImportSequence
  program' <* eof

program' :: Context m => P.Parser m ([WeakStmt], [EnumInfo])
program' =
  choice
    [ do
        enumInfo <- Enum.parseDefineEnum
        (defList, enumInfoList) <- program'
        return (defList, enumInfo : enumInfoList),
      do
        parseStmtUse
        program',
      do
        stmtList <- many parseStmt >>= lift . Discern.discernStmtList . concat
        return (stmtList, [])
    ]

parseStmtUse :: Context m => P.Parser m ()
parseStmtUse = do
  try $ P.keyword "use"
  loc <- parseLocator
  case loc of
    Left partialLocator ->
      lift $ Locator.activateDefiniteLocator partialLocator
    Right globalLocator ->
      lift $ Locator.activateGlobalLocator globalLocator

parseLocator :: Context m => P.Parser m (Either DL.DefiniteLocator SGL.StrictGlobalLocator)
parseLocator = do
  choice
    [ Left <$> try parseDefiniteLocator,
      Right <$> parseGlobalLocator
    ]

parseStmt :: Context m => P.Parser m [RawStmt]
parseStmt = do
  choice
    [ parseDefineData,
      parseDefineCodata,
      return <$> parseDefine O.Transparent,
      return <$> parseDefine O.Opaque,
      return <$> parseSection
    ]

parseDefiniteLocator :: Context m => P.Parser m DL.DefiniteLocator
parseDefiniteLocator = do
  m <- P.getCurrentHint
  globalLocator <- P.symbol >>= lift . (GL.reflect m >=> Alias.resolveAlias m)
  P.delimiter definiteSep
  localLocator <- P.symbol
  baseNameList <- lift $ BN.bySplit m localLocator
  return $ DL.new globalLocator $ map Section.Section baseNameList

parseGlobalLocator :: Context m => P.Parser m SGL.StrictGlobalLocator
parseGlobalLocator = do
  m <- P.getCurrentHint
  gl <- P.symbol >>= lift . GL.reflect m
  lift $ Alias.resolveAlias m gl

--
-- parser for statements
--

parseSection :: Context m => P.Parser m RawStmt
parseSection = do
  try $ P.keyword "section"
  section <- Section.Section <$> P.baseName
  Locator.withLiftedSection section $ do
    stmtList <- concat <$> many parseStmt
    P.keyword "end"
    return $ RawStmtSection section stmtList

-- define name (x1 : A1) ... (xn : An) : A = e
parseDefine :: Context m => O.Opacity -> P.Parser m RawStmt
parseDefine opacity = do
  try $
    case opacity of
      O.Opaque ->
        P.keyword "define"
      O.Transparent ->
        P.keyword "define-inline"
  m <- P.getCurrentHint
  ((_, name), impArgs, expArgs, codType, e) <- parseTopDefInfo
  name' <- lift $ Locator.attachCurrentLocator name
  lift $ defineFunction opacity m name' (I.fromInt $ length impArgs) (impArgs ++ expArgs) codType e

defineFunction ::
  Context m =>
  O.Opacity ->
  Hint ->
  DD.DefiniteDescription ->
  I.ImpArgNum ->
  [BinderF RT.RawTerm] ->
  RT.RawTerm ->
  RT.RawTerm ->
  m RawStmt
defineFunction opacity m name impArgNum binder codType e = do
  Global.registerTopLevelFunc m name (A.fromInt (length binder))
  return $ RawStmtDefine opacity m name impArgNum binder codType e

parseDefineData :: Context m => P.Parser m [RawStmt]
parseDefineData = do
  m <- P.getCurrentHint
  try $ P.keyword "define-data"
  a <- P.baseName >>= lift . Locator.attachCurrentLocator
  dataArgs <- P.argList preAscription
  consInfoList <- P.asBlock $ P.manyList parseDefineDataClause
  lift $ defineData m a dataArgs consInfoList

defineData ::
  Context m =>
  Hint ->
  DD.DefiniteDescription ->
  [BinderF RT.RawTerm] ->
  [(Hint, T.Text, [BinderF RT.RawTerm])] ->
  m [RawStmt]
defineData m dataName dataArgs consInfoList = do
  consInfoList' <- mapM (modifyConstructorName m dataName) consInfoList
  setAsData m dataName (A.fromInt (length dataArgs)) consInfoList'
  let consType = m :< RT.Pi [] (m :< RT.Tau)
  let formRule = RawStmtDefine O.Opaque m dataName (I.fromInt 0) dataArgs (m :< RT.Tau) consType
  introRuleList <- parseDefineDataConstructor dataName dataArgs consInfoList' D.zero
  return $ formRule : introRuleList

modifyConstructorName ::
  Throw.Context m =>
  Hint ->
  DD.DefiniteDescription ->
  (Hint, T.Text, [BinderF RT.RawTerm]) ->
  m (Hint, DD.DefiniteDescription, [BinderF RT.RawTerm])
modifyConstructorName m dataDD (mb, consName, yts) = do
  consName' <- DD.extend m dataDD consName
  return (mb, consName', yts)

parseDefineDataConstructor ::
  Context m =>
  DD.DefiniteDescription ->
  [BinderF RT.RawTerm] ->
  [(Hint, DD.DefiniteDescription, [BinderF RT.RawTerm])] ->
  D.Discriminant ->
  m [RawStmt]
parseDefineDataConstructor dataName dataArgs consInfoList discriminant = do
  case consInfoList of
    [] ->
      return []
    (m, consName, consArgs) : rest -> do
      let consArgs' = map identPlusToVar consArgs
      let dataType = constructDataType m dataName dataArgs
      introRule <-
        defineFunction
          O.Transparent
          m
          consName
          (I.fromInt $ length dataArgs)
          (dataArgs ++ consArgs)
          dataType
          $ m
            :< RT.PiIntro
              (LK.Cons dataName consName discriminant dataType)
              [ (m, Ident.fromText (DD.reify consName), m :< RT.Pi consArgs (m :< RT.Tau))
              ]
              (m :< RT.PiElim (preVar m (DD.reify consName)) consArgs')
      introRuleList <- parseDefineDataConstructor dataName dataArgs rest (D.increment discriminant)
      return $ introRule : introRuleList

constructDataType :: Hint -> DD.DefiniteDescription -> [BinderF RT.RawTerm] -> RT.RawTerm
constructDataType m dataName dataArgs =
  m :< RT.PiElim (m :< RT.VarGlobalStrict dataName) (map identPlusToVar dataArgs)

parseDefineDataClause :: Context m => P.Parser m (Hint, T.Text, [BinderF RT.RawTerm])
parseDefineDataClause = do
  m <- P.getCurrentHint
  b <- P.symbol
  yts <- P.argList parseDefineDataClauseArg
  return (m, b, yts)

parseDefineDataClauseArg :: Context m => P.Parser m (BinderF RT.RawTerm)
parseDefineDataClauseArg = do
  m <- P.getCurrentHint
  choice
    [ try preAscription,
      weakTermToWeakIdent m rawTerm
    ]

parseDefineCodata :: Context m => P.Parser m [RawStmt]
parseDefineCodata = do
  m <- P.getCurrentHint
  try $ P.keyword "define-codata"
  dataName <- P.baseName >>= lift . Locator.attachCurrentLocator
  dataArgs <- P.argList preAscription
  elemInfoList <- P.asBlock $ P.manyList preAscription
  formRule <- lift $ defineData m dataName dataArgs [(m, "new", elemInfoList)]
  elimRuleList <- mapM (lift . parseDefineCodataElim dataName dataArgs elemInfoList) elemInfoList
  return $ formRule ++ elimRuleList

parseDefineCodataElim ::
  Context m =>
  DD.DefiniteDescription ->
  [BinderF RT.RawTerm] ->
  [BinderF RT.RawTerm] ->
  BinderF RT.RawTerm ->
  m RawStmt
parseDefineCodataElim dataName dataArgs elemInfoList (m, elemName, elemType) = do
  let codataType = constructDataType m dataName dataArgs
  recordVarText <- Gensym.newText
  let projArgs = dataArgs ++ [(m, Ident.fromText recordVarText, codataType)]
  projectionName <- DD.extend m dataName $ Ident.toText elemName
  let newDD = DD.extendLL dataName $ LL.new [] BN.new
  defineFunction
    O.Opaque
    m
    projectionName -- e.g. some-lib.foo::my-record.element-x
    (I.fromInt $ length dataArgs)
    projArgs
    elemType
    $ m
      :< RT.Match
        (preVar m recordVarText, codataType)
        [((m, Right newDD, elemInfoList), preVar m (Ident.toText elemName))]

setAsData ::
  Global.Context m =>
  Hint ->
  DD.DefiniteDescription ->
  A.Arity ->
  [(Hint, DD.DefiniteDescription, [BinderF RT.RawTerm])] ->
  m ()
setAsData m dataName arity consInfoList = do
  let consNameList = map (\(_, consName, _) -> consName) consInfoList
  Global.registerData m dataName arity consNameList

identPlusToVar :: BinderF RT.RawTerm -> RT.RawTerm
identPlusToVar (m, x, _) =
  m :< RT.Var x

weakTermToWeakIdent :: Context m => Hint -> P.Parser m RT.RawTerm -> P.Parser m (BinderF RT.RawTerm)
weakTermToWeakIdent m f = do
  a <- f
  h <- lift $ Gensym.newTextualIdentFromText "_"
  return (m, h, a)
