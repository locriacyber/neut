module Entity.WeakTerm where

import Control.Comonad.Cofree
import qualified Data.IntMap as IntMap
import Entity.Arity
import Entity.Binder
import qualified Entity.DecisionTree as DT
import qualified Entity.DefiniteDescription as DD
import qualified Entity.Discriminant as D
import Entity.Hint
import Entity.HoleID
import Entity.Ident
import Entity.LamKind
import Entity.Magic
import qualified Entity.Noema as N
import qualified Entity.Opacity as O
import Entity.PrimNumSize
import qualified Entity.PrimType as PT
import qualified Entity.WeakPrim as WP

type WeakTerm = Cofree WeakTermF Hint

data WeakTermF a
  = Tau
  | Var Ident
  | VarGlobal DD.DefiniteDescription Arity
  | Pi [BinderF a] a
  | PiIntro (LamKindF a) [BinderF a] a
  | PiElim a [a]
  | Data DD.DefiniteDescription [a]
  | DataIntro DD.DefiniteDescription DD.DefiniteDescription D.Discriminant [a] [a]
  | DataElim N.IsNoetic [(Ident, a, a)] (DT.DecisionTree a)
  | Noema a
  | Let LetOpacity (BinderF a) a a
  | Prim (WP.WeakPrim a)
  | ResourceType DD.DefiniteDescription
  | Magic (Magic a) -- (magic kind arg-1 ... arg-n)
  | Hole HoleID [WeakTerm] -- ?M @ (e1, ..., en)

type SubstWeakTerm =
  IntMap.IntMap WeakTerm

data LetOpacity
  = Opaque
  | Transparent
  | Noetic
  deriving (Show, Eq)

reifyOpacity :: LetOpacity -> O.Opacity
reifyOpacity letOpacity =
  case letOpacity of
    Opaque ->
      O.Opaque
    Transparent ->
      O.Transparent
    Noetic ->
      O.Transparent

toVar :: Hint -> Ident -> WeakTerm
toVar m x =
  m :< Var x

i8 :: Hint -> WeakTerm
i8 m =
  m :< Prim (WP.Type $ PT.Int $ IntSize 8)

i64 :: Hint -> WeakTerm
i64 m =
  m :< Prim (WP.Type $ PT.Int $ IntSize 64)

metaOf :: WeakTerm -> Hint
metaOf (m :< _) =
  m

asVar :: WeakTerm -> Maybe Ident
asVar term =
  case term of
    (_ :< Var x) ->
      Just x
    _ ->
      Nothing
