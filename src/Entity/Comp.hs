module Entity.Comp where

import qualified Data.IntMap as IntMap
import Entity.Arity
import qualified Entity.DefiniteDescription as DD
import Entity.EnumCase
import Entity.Ident
import Entity.Magic
import Entity.Opacity
import Entity.PrimNum
import Entity.PrimNumSize
import Entity.PrimOp

data Value
  = VarLocal Ident
  | VarLocalIdeal Ident
  | VarGlobal DD.DefiniteDescription Arity
  | SigmaIntro [Value]
  | ArrayIntro PrimNum [Value]
  | Int IntSize Integer
  | Float FloatSize Double
  | EnumIntro EnumLabel
  deriving (Show)

data Comp
  = PiElimDownElim Value [Value] -- ((force v) v1 ... vn)
  | SigmaElim ShouldDeallocate [Ident] Value Comp
  | UpIntro Value
  | UpElim Ident Comp Comp
  | EnumElim Value [(CompEnumCase, Comp)]
  | ArrayAccess PrimNum Value Value
  | Primitive Primitive
  deriving (Show)

type ShouldDeallocate = Bool

data Primitive
  = PrimOp PrimOp [Value]
  | Magic (Magic Value)
  deriving (Show)

type SubstValue =
  IntMap.IntMap Value

type CompDef =
  (DD.DefiniteDescription, (Opacity, [Ident], Comp))
