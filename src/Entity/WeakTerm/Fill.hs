module Entity.WeakTerm.Fill
  ( fill,
  )
where

import Control.Comonad.Cofree
import Control.Monad
import qualified Data.IntMap as IntMap
import Data.Maybe
import Entity.Binder
import Entity.HoleSubst
import qualified Entity.Ident.Reify as Ident
import Entity.LamKind
import Entity.WeakTerm
import Entity.WeakTerm.Reduce
import Entity.WeakTerm.Subst
import Prelude hiding (lookup)

fill :: Context m => HoleSubst -> WeakTerm -> m WeakTerm
fill sub term =
  case term of
    _ :< WeakTermTau ->
      return term
    _ :< WeakTermVar {} ->
      return term
    _ :< WeakTermVarGlobal {} ->
      return term
    m :< WeakTermPi xts t -> do
      (xts', t') <- fill' sub xts t
      return $ m :< WeakTermPi xts' t'
    m :< WeakTermPiIntro kind xts e -> do
      case kind of
        LamKindFix xt -> do
          (xt', xts', e') <- fill'' sub xt xts e
          return $ m :< WeakTermPiIntro (LamKindFix xt') xts' e'
        _ -> do
          (xts', e') <- fill' sub xts e
          return $ m :< WeakTermPiIntro kind xts' e'
    m :< WeakTermPiElim e es -> do
      e' <- fill sub e
      es' <- mapM (fill sub) es
      return $ m :< WeakTermPiElim e' es'
    m :< WeakTermSigma xts -> do
      (xts', _) <- fill' sub xts (m :< WeakTermTau)
      return $ m :< WeakTermSigma xts'
    m :< WeakTermSigmaIntro es -> do
      es' <- mapM (fill sub) es
      return $ m :< WeakTermSigmaIntro es'
    m :< WeakTermSigmaElim xts e1 e2 -> do
      e1' <- fill sub e1
      (xts', e2') <- fill' sub xts e2
      return $ m :< WeakTermSigmaElim xts' e1' e2'
    m :< WeakTermLet mxt e1 e2 -> do
      e1' <- fill sub e1
      (mxt', _, e2') <- fill'' sub mxt [] e2
      -- ([mxt'], e2') <- fill' sub [mxt] e2
      return $ m :< WeakTermLet mxt' e1' e2'
    _ :< WeakTermPrim _ ->
      return term
    m :< WeakTermAster i es -> do
      es' <- mapM (fill sub) es
      case lookup i sub of
        Just (xs, body)
          | length xs == length es -> do
              let varList = map Ident.toInt xs
              subst (IntMap.fromList $ zip varList es') body >>= reduce
          | otherwise ->
              error "Entity.WeakTerm.Fill (assertion failure; arity mismatch)"
        Nothing ->
          return $ m :< WeakTermAster i es'
    m :< WeakTermInt t x -> do
      t' <- fill sub t
      return $ m :< WeakTermInt t' x
    m :< WeakTermFloat t x -> do
      t' <- fill sub t
      return $ m :< WeakTermFloat t' x
    _ :< WeakTermEnum {} ->
      return term
    _ :< WeakTermEnumIntro {} ->
      return term
    m :< WeakTermEnumElim (e, t) branchList -> do
      t' <- fill sub t
      e' <- fill sub e
      let (caseList, es) = unzip branchList
      es' <- mapM (fill sub) es
      return $ m :< WeakTermEnumElim (e', t') (zip caseList es')
    m :< WeakTermQuestion e t -> do
      e' <- fill sub e
      t' <- fill sub t
      return $ m :< WeakTermQuestion e' t'
    m :< WeakTermMagic der -> do
      der' <- mapM (fill sub) der
      return $ m :< WeakTermMagic der'
    m :< WeakTermMatch (e, t) clauseList -> do
      e' <- fill sub e
      t' <- fill sub t
      clauseList' <- forM clauseList $ \((mPat, name, arity, xts), body) -> do
        (xts', body') <- fill' sub xts body
        return ((mPat, name, arity, xts'), body')
      return $ m :< WeakTermMatch (e', t') clauseList'

fill' ::
  Context m =>
  HoleSubst ->
  [BinderF WeakTerm] ->
  WeakTerm ->
  m ([BinderF WeakTerm], WeakTerm)
fill' sub binder e =
  case binder of
    [] -> do
      e' <- fill sub e
      return ([], e')
    ((m, x, t) : xts) -> do
      (xts', e') <- fill' sub xts e
      t' <- fill sub t
      return ((m, x, t') : xts', e')

fill'' ::
  Context m =>
  HoleSubst ->
  BinderF WeakTerm ->
  [BinderF WeakTerm] ->
  WeakTerm ->
  m (BinderF WeakTerm, [BinderF WeakTerm], WeakTerm)
fill'' sub (m, x, t) binder e = do
  (xts', e') <- fill' sub binder e
  t' <- fill sub t
  return ((m, x, t'), xts', e')
