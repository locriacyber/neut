module Scene.Clarify.Linearize
  ( linearize,
  )
where

import Context.Gensym
import Control.Monad
import qualified Entity.Comp as C
import Entity.Ident
import Entity.Magic
import Scene.Clarify.Utility

data Occurrence
  = OccurrenceNormal Ident
  | OccurrenceIdeal Ident
  deriving (Show)

linearize ::
  Context m =>
  [(Ident, C.Comp)] -> -- [(x1, t1), ..., (xn, tn)]  (closed chain)
  C.Comp -> -- a term that can contain non-linear occurrences of xi
  m C.Comp -- a term in which all the variables in the closed chain occur linearly
linearize binder e =
  case binder of
    [] ->
      return e
    (x, t) : xts -> do
      e' <- linearize xts e
      (newNameList, e'') <- distinguishComp x e'
      case newNameList of
        [] -> do
          hole <- newIdentFromText "unit"
          discardUnusedVar <- toAffineApp x t
          return $ C.UpElim hole discardUnusedVar e''
        z : zs ->
          insertHeader x z zs t e''

insertFooter :: Context m => Ident -> C.Comp -> C.Comp -> m C.Comp
insertFooter x t e = do
  ans <- newIdentFromText "answer"
  hole <- newIdentFromText "unit"
  discardUnusedVar <- toAffineApp x t
  return $
    C.UpElim ans e $
      C.UpElim hole discardUnusedVar $
        C.UpIntro (C.VarLocal ans)

insertHeader ::
  Context m =>
  Ident ->
  Occurrence ->
  [Occurrence] ->
  C.Comp ->
  C.Comp ->
  m C.Comp
insertHeader x occurrence zs t e = do
  case zs of
    [] ->
      case occurrence of
        OccurrenceNormal z1 ->
          return $ C.UpElim z1 (C.UpIntro (C.VarLocal x)) e
        OccurrenceIdeal z1 -> do
          e' <- insertFooter z1 t e
          return $ C.UpElim z1 (C.UpIntro (C.VarLocal x)) e'
    z2 : rest -> do
      case occurrence of
        OccurrenceNormal z1 -> do
          e' <- insertHeader x z2 rest t e
          copyRelevantVar <- toRelevantApp x t
          return $ C.UpElim z1 copyRelevantVar e'
        OccurrenceIdeal z1 -> do
          e' <- insertHeader x z2 rest t e
          return $ C.UpElim z1 (C.UpIntro (C.VarLocal x)) e'

distinguishValue :: Context m => Ident -> C.Value -> m ([Occurrence], C.Value)
distinguishValue z term =
  case term of
    C.VarLocal x ->
      if x /= z
        then return ([], term)
        else do
          x' <- newIdentFromIdent x
          return ([OccurrenceNormal x'], C.VarLocal x')
    C.VarLocalIdeal x ->
      if x /= z
        then return ([], term)
        else do
          x' <- newIdentFromIdent x
          return ([OccurrenceIdeal x'], C.VarLocal x')
    C.SigmaIntro ds -> do
      (vss, ds') <- mapAndUnzipM (distinguishValue z) ds
      return (concat vss, C.SigmaIntro ds')
    _ ->
      return ([], term)

distinguishComp :: Context m => Ident -> C.Comp -> m ([Occurrence], C.Comp)
distinguishComp z term =
  case term of
    C.Primitive theta -> do
      (vs, theta') <- distinguishPrimitive z theta
      return (vs, C.Primitive theta')
    C.PiElimDownElim d ds -> do
      (vs, d') <- distinguishValue z d
      (vss, ds') <- mapAndUnzipM (distinguishValue z) ds
      return (concat $ vs : vss, C.PiElimDownElim d' ds')
    C.SigmaElim shouldDeallocate xs d e -> do
      (vs1, d') <- distinguishValue z d
      (vs2, e') <- distinguishComp z e
      return (vs1 ++ vs2, C.SigmaElim shouldDeallocate xs d' e')
    C.UpIntro d -> do
      (vs, d') <- distinguishValue z d
      return (vs, C.UpIntro d')
    C.UpElim x e1 e2 -> do
      (vs1, e1') <- distinguishComp z e1
      (vs2, e2') <- distinguishComp z e2
      return (vs1 ++ vs2, C.UpElim x e1' e2')
    C.ArrayAccess elemType array index -> do
      (vs1, array') <- distinguishValue z array
      (vs2, index') <- distinguishValue z index
      return (vs1 ++ vs2, C.ArrayAccess elemType array' index')
    C.EnumElim d branchList -> do
      (vs, d') <- distinguishValue z d
      case branchList of
        [] ->
          return (vs, C.EnumElim d' [])
        _ -> do
          let (cs, es) = unzip branchList
          -- countBefore <- readmRef countRef
          countBefore <- readCount
          (vss, es') <- fmap unzip $
            forM es $ \e -> do
              writeCount countBefore
              -- writemRef countRef countBefore
              distinguishComp z e
          return (vs ++ head vss, C.EnumElim d' (zip cs es'))

distinguishPrimitive :: Context m => Ident -> C.Primitive -> m ([Occurrence], C.Primitive)
distinguishPrimitive z term =
  case term of
    C.PrimOp op ds -> do
      (vss, ds') <- mapAndUnzipM (distinguishValue z) ds
      return (concat vss, C.PrimOp op ds')
    C.Magic der -> do
      case der of
        MagicCast from to value -> do
          (vs1, from') <- distinguishValue z from
          (vs2, to') <- distinguishValue z to
          (vs3, value') <- distinguishValue z value
          return (vs1 <> vs2 <> vs3, C.Magic (MagicCast from' to' value'))
        MagicStore lt pointer value -> do
          (vs1, pointer') <- distinguishValue z pointer
          (vs2, value') <- distinguishValue z value
          return (vs1 <> vs2, C.Magic (MagicStore lt pointer' value'))
        MagicLoad lt pointer -> do
          (vs, pointer') <- distinguishValue z pointer
          return (vs, C.Magic (MagicLoad lt pointer'))
        MagicSyscall syscallNum args -> do
          (vss, args') <- mapAndUnzipM (distinguishValue z) args
          return (concat vss, C.Magic (MagicSyscall syscallNum args'))
        MagicExternal extFunName args -> do
          (vss, args') <- mapAndUnzipM (distinguishValue z) args
          return (concat vss, C.Magic (MagicExternal extFunName args'))
