-- Used only by ToIface.hs-boot

module IfaceType( IfaceType, IfaceTyCon, IfaceForAllBndr
                , IfaceCoercion, IfaceTyLit, IfaceAppArgs ) where

import Var (TyVarBndr, ArgFlag)
import FastString (FastString)

data IfaceAppArgs
type IfLclName = FastString
type IfaceKind = IfaceType

data IfaceType
data IfaceTyCon
data IfaceTyLit
data IfaceCoercion
type IfaceTvBndr      = (IfLclName, IfaceKind)
type IfaceForAllBndr  = TyVarBndr IfaceTvBndr ArgFlag
