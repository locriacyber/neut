module Entity.Term.Reduce (reduce) where

import Control.Comonad.Cofree
import qualified Data.IntMap as IntMap
import qualified Entity.DecisionTree as DT
import qualified Entity.Ident.Reify as Ident
import qualified Entity.LamKind as LK
import qualified Entity.Opacity as O
import qualified Entity.Term as TM
import qualified Entity.Term.Subst as Subst

reduce :: Subst.Context m => TM.Term -> m TM.Term
reduce term =
  case term of
    (m :< TM.Pi xts cod) -> do
      let (ms, xs, ts) = unzip3 xts
      ts' <- mapM reduce ts
      cod' <- reduce cod
      return (m :< TM.Pi (zip3 ms xs ts') cod')
    (m :< TM.PiIntro kind xts e) -> do
      let (ms, xs, ts) = unzip3 xts
      ts' <- mapM reduce ts
      e' <- reduce e
      case kind of
        LK.Fix (mx, x, t) -> do
          t' <- reduce t
          return (m :< TM.PiIntro (LK.Fix (mx, x, t')) (zip3 ms xs ts') e')
        _ ->
          return (m :< TM.PiIntro kind (zip3 ms xs ts') e')
    (m :< TM.PiElim e es) -> do
      e' <- reduce e
      es' <- mapM reduce es
      case e' of
        (_ :< TM.PiIntro (LK.Normal O.Transparent) xts (_ :< body))
          | length xts == length es',
            all TM.isValue es -> do
              let xs = map (\(_, x, _) -> Ident.toInt x) xts
              let sub = IntMap.fromList $ zip xs es'
              Subst.subst sub (m :< body) >>= reduce
        _ ->
          return (m :< TM.PiElim e' es')
    m :< TM.Data name es -> do
      es' <- mapM reduce es
      return $ m :< TM.Data name es'
    m :< TM.DataIntro dataName consName disc dataArgs consArgs -> do
      dataArgs' <- mapM reduce dataArgs
      consArgs' <- mapM reduce consArgs
      return $ m :< TM.DataIntro dataName consName disc dataArgs' consArgs'
    m :< TM.DataElim isNoetic oets decisionTree -> do
      let (os, es, ts) = unzip3 oets
      es' <- mapM reduce es
      ts' <- mapM reduce ts
      decisionTree' <- reduceDecisionTree decisionTree
      return $ m :< TM.DataElim isNoetic (zip3 os es' ts') decisionTree'
    (m :< TM.Magic der) -> do
      der' <- traverse reduce der
      return (m :< TM.Magic der')
    _ ->
      return term

reduceDecisionTree ::
  Subst.Context m =>
  DT.DecisionTree TM.Term ->
  m (DT.DecisionTree TM.Term)
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
  DT.CaseList TM.Term ->
  m (DT.CaseList TM.Term)
reduceCaseList (fallbackTree, clauseList) = do
  fallbackTree' <- reduceDecisionTree fallbackTree
  clauseList' <- mapM reduceCase clauseList
  return (fallbackTree', clauseList')

reduceCase ::
  Subst.Context m =>
  DT.Case TM.Term ->
  m (DT.Case TM.Term)
reduceCase (DT.Cons dd disc dataArgs consArgs tree) = do
  let (dataTerms, dataTypes) = unzip dataArgs
  dataTerms' <- mapM reduce dataTerms
  dataTypes' <- mapM reduce dataTypes
  let (ms, xs, ts) = unzip3 consArgs
  ts' <- mapM reduce ts
  tree' <- reduceDecisionTree tree
  return $ DT.Cons dd disc (zip dataTerms' dataTypes') (zip3 ms xs ts') tree'
