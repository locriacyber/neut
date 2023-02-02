module Context.Env where

import qualified Data.HashMap.Strict as Map
import qualified Data.Set as S
import qualified Data.Text as T
import Entity.AliasInfo
import qualified Entity.DefiniteDescription as DD
import qualified Entity.GlobalLocatorAlias as GLA
import qualified Entity.GlobalName as GN
import qualified Entity.HoleID as HID
import qualified Entity.HoleSubst as HS
import Entity.Ident
import Entity.Module
import Entity.ModuleAlias
import Entity.ModuleChecksum
import qualified Entity.Section as Section
import qualified Entity.Source as Source
import Entity.Stmt
import qualified Entity.StrictGlobalLocator as SGL
import Entity.TargetPlatform
import Entity.VisitInfo
import Entity.WeakTerm
import Path

class MonadFail m => Context m where
  setMainModule :: Module -> m ()
  getMainModule :: m Module
  setCurrentSource :: Source.Source -> m ()
  getCurrentSource :: m Source.Source
  setCurrentSectionStack :: [Section.Section] -> m ()
  getCurrentSectionStack :: m [Section.Section]
  setShouldCancelAlloc :: Bool -> m ()
  getShouldCancelAlloc :: m Bool
  setShouldColorize :: Bool -> m ()
  getShouldColorize :: m Bool
  setEndOfEntry :: T.Text -> m ()
  getEndOfEntry :: m T.Text
  setClangOptString :: String -> m ()
  getClangOptString :: m String
  getModuleCacheMap :: m (Map.HashMap (Path Abs File) Module)
  insertToModuleCacheMap :: Path Abs File -> Module -> m ()
  insertToLocatorAliasMap :: GLA.GlobalLocatorAlias -> SGL.StrictGlobalLocator -> m ()
  getLocatorAliasMap :: m (Map.HashMap GLA.GlobalLocatorAlias SGL.StrictGlobalLocator)
  setModuleAliasMap :: Map.HashMap ModuleAlias ModuleChecksum -> m ()
  insertToModuleAliasMap :: ModuleAlias -> ModuleChecksum -> m ()
  getModuleAliasMap :: m (Map.HashMap ModuleAlias ModuleChecksum)
  setNameMap :: Map.HashMap DD.DefiniteDescription GN.GlobalName -> m ()
  insertToNameMap :: DD.DefiniteDescription -> GN.GlobalName -> m ()
  getNameMap :: m (Map.HashMap DD.DefiniteDescription GN.GlobalName)
  setNopFreeSet :: S.Set Int -> m ()
  getNopFreeSet :: m (S.Set Int)
  insertToNopFreeSet :: Int -> m ()
  getSourceAliasMap :: m SourceAliasMap
  insertToSourceAliasMap :: Path Abs File -> [AliasInfo] -> m ()
  setConstraintEnv :: [(WeakTerm, WeakTerm)] -> m ()
  insConstraintEnv :: WeakTerm -> WeakTerm -> m ()
  getConstraintEnv :: m [(WeakTerm, WeakTerm)]
  setHoleSubst :: HS.HoleSubst -> m ()
  insertSubst :: HID.HoleID -> [Ident] -> WeakTerm -> m ()
  getHoleSubst :: m HS.HoleSubst
  setTargetPlatform :: m ()
  getTargetPlatform :: m TargetPlatform
  insertToSourceChildrenMap :: Path Abs File -> [Source.Source] -> m ()
  getSourceChildrenMap :: m (Map.HashMap (Path Abs File) [Source.Source])
  setTraceSourceList :: [Source.Source] -> m ()
  pushToTraceSourceList :: Source.Source -> m ()
  popFromTraceSourceList :: m ()
  getTraceSourceList :: m [Source.Source]
  getHasObjectSet :: m PathSet
  getHasLLVMSet :: m PathSet
  insertToHasObjectSet :: Path Abs File -> m ()
  insertToHasCacheSet :: Path Abs File -> m ()
  insertToHasLLVMSet :: Path Abs File -> m ()
  getHasCacheSet :: m PathSet
  insertToVisitEnv :: Path Abs File -> VisitInfo -> m ()
  getVisitEnv :: m (Map.HashMap (Path Abs File) VisitInfo)
