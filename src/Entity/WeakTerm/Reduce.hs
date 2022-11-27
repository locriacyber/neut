module Entity.WeakTerm.Reduce (reduce) where

import Control.Comonad.Cofree
import qualified Data.IntMap as IntMap
import qualified Entity.DecisionTree as DT
import qualified Entity.EnumCase as EC
import qualified Entity.Ident.Reify as Ident
import qualified Entity.LamKind as LK
import qualified Entity.WeakTerm as WT
import Entity.WeakTerm.FreeVars
import qualified Entity.WeakTerm.Subst as Subst

reduce :: Subst.Context m => WT.WeakTerm -> m WT.WeakTerm
reduce term =
  case term of
    m :< WT.Pi xts cod -> do
      let (ms, xs, ts) = unzip3 xts
      ts' <- mapM reduce ts
      cod' <- reduce cod
      return $ m :< WT.Pi (zip3 ms xs ts') cod'
    m :< WT.PiIntro kind xts e
      | LK.Fix (_, x, _) <- kind,
        x `notElem` freeVars e ->
          reduce $ m :< WT.PiIntro LK.Normal xts e
      | otherwise -> do
          let (ms, xs, ts) = unzip3 xts
          ts' <- mapM reduce ts
          e' <- reduce e
          case kind of
            LK.Fix (mx, x, t) -> do
              t' <- reduce t
              return (m :< WT.PiIntro (LK.Fix (mx, x, t')) (zip3 ms xs ts') e')
            _ ->
              return (m :< WT.PiIntro kind (zip3 ms xs ts') e')
    m :< WT.PiElim e es -> do
      e' <- reduce e
      es' <- mapM reduce es
      case e' of
        (_ :< WT.PiIntro LK.Normal xts body)
          | length xts == length es' -> do
              let xs = map (\(_, x, _) -> Ident.toInt x) xts
              let sub = IntMap.fromList $ zip xs es'
              Subst.subst sub body >>= reduce
        _ ->
          return $ m :< WT.PiElim e' es'
    m :< WT.Data name es -> do
      es' <- mapM reduce es
      return $ m :< WT.Data name es'
    m :< WT.DataIntro dataName consName disc dataArgs consArgs -> do
      dataArgs' <- mapM reduce dataArgs
      consArgs' <- mapM reduce consArgs
      return $ m :< WT.DataIntro dataName consName disc dataArgs' consArgs'
    m :< WT.DataElim oets decisionTree -> do
      let (os, es, ts) = unzip3 oets
      es' <- mapM reduce es
      ts' <- mapM reduce ts
      decisionTree' <- reduceDecisionTree decisionTree
      return $ m :< WT.DataElim (zip3 os es' ts') decisionTree'
    m :< WT.Sigma xts -> do
      let (ms, xs, ts) = unzip3 xts
      ts' <- mapM reduce ts
      return $ m :< WT.Sigma (zip3 ms xs ts')
    m :< WT.SigmaIntro es -> do
      es' <- mapM reduce es
      return $ m :< WT.SigmaIntro es'
    m :< WT.SigmaElim xts e1 e2 -> do
      e1' <- reduce e1
      case e1' of
        _ :< WT.SigmaIntro es
          | length xts == length es -> do
              let xs = map (\(_, x, _) -> Ident.toInt x) xts
              let sub = IntMap.fromList $ zip xs es
              Subst.subst sub e2 >>= reduce
        _ -> do
          e2' <- reduce e2
          return $ m :< WT.SigmaElim xts e1' e2'
    _ :< WT.Let (_, x, _) e1 e2 -> do
      e1' <- reduce e1
      let sub = IntMap.fromList [(Ident.toInt x, e1')]
      Subst.subst sub e2
    m :< WT.EnumElim (e, t) les -> do
      e' <- reduce e
      let (ls, es) = unzip les
      es' <- mapM reduce es
      let les' = zip ls es'
      let les'' = zip (map unwrap ls) es'
      t' <- reduce t
      case e' of
        (_ :< WT.EnumIntro label) ->
          case lookup (EC.Label label) les'' of
            Just body ->
              reduce body
            Nothing ->
              error "enum-elim (Entity.WeakTerm.Reduce)"
        -- case lookup EC.Default les'' of
        --   Just body ->
        --     reduce body
        --   Nothing ->
        --     return $ m :< WT.EnumElim (e', t') les'
        _ ->
          return $ m :< WT.EnumElim (e', t') les'
    _ :< WT.Question e _ ->
      reduce e
    m :< WT.Magic der -> do
      der' <- mapM reduce der
      return $ m :< WT.Magic der'
    _ ->
      return term

reduceDecisionTree ::
  Subst.Context m =>
  DT.DecisionTree WT.WeakTerm ->
  m (DT.DecisionTree WT.WeakTerm)
reduceDecisionTree tree =
  case tree of
    DT.Leaf xs e -> do
      e' <- reduce e
      return $ DT.Leaf xs e'
    DT.Unreachable ->
      return DT.Unreachable
    DT.Switch (cursorVar, cursor) clauseList -> do
      cursor' <- reduce cursor
      clauseList' <- reduceCaseList clauseList
      return $ DT.Switch (cursorVar, cursor') clauseList'

reduceCaseList ::
  Subst.Context m =>
  DT.CaseList WT.WeakTerm ->
  m (DT.CaseList WT.WeakTerm)
reduceCaseList (fallbackTree, clauseList) = do
  fallbackTree' <- reduceDecisionTree fallbackTree
  clauseList' <- mapM reduceCase clauseList
  return (fallbackTree', clauseList')

reduceCase ::
  Subst.Context m =>
  DT.Case WT.WeakTerm ->
  m (DT.Case WT.WeakTerm)
reduceCase (DT.Cons dd disc dataArgs consArgs tree) = do
  let (ms1, xs1, ts1) = unzip3 dataArgs
  let (ms2, xs2, ts2) = unzip3 consArgs
  ts1' <- mapM reduce ts1
  ts2' <- mapM reduce ts2
  tree' <- reduceDecisionTree tree
  return $ DT.Cons dd disc (zip3 ms1 xs1 ts1') (zip3 ms2 xs2 ts2') tree'
