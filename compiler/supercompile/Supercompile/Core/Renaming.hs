{-# LANGUAGE Rank2Types #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Supercompile.Core.Renaming (
    -- | Renamings
    Renaming, emptyRenaming,
    mkInScopeIdentityRenaming, mkIdentityRenaming, mkTyVarRenaming,
    invertRenaming,
    InScopeSet, emptyInScopeSet, mkInScopeSet,
    
    -- | Extending the renaming
    insertIdRenaming, insertIdRenamings,
    insertTypeSubst, insertTypeSubsts,
    insertCoercionSubst, insertCoercionSubsts,
    
    -- | Querying the renaming
    renameId, lookupTyVarSubst, lookupCoVarSubst,
    
    -- | Things with associated renamings
    In, Out,

    -- | Renaming variables occurrences and binding sites
    inFreeVars, renameFreeVars, renameIn,
    renameType, renameCoercion,
    renameBinders, renameNonRecBinder, renameNonRecBinders,
    renameBounds, renameNonRecBound,
    
    -- | Renaming actual bits of syntax
    renameAltCon,
    renameTerm,                renameAlts,                renameValue,                renameValue',
    renameFVedTerm,            renameFVedAlts,            renameFVedValue,            renameFVedValue',
    renameTaggedTerm,          renameTaggedAlts,          renameTaggedValue,          renameTaggedValue',
    renameTaggedSizedFVedTerm, renameTaggedSizedFVedAlts, renameTaggedSizedFVedValue, renameTaggedSizedFVedValue'
  ) where

import Supercompile.Core.FreeVars
import Supercompile.Core.Syntax

import Supercompile.Utilities

import CoreSubst
import OptCoercion (optCoercion)
import Coercion    (CvSubst(..), CvSubstEnv, isCoVar, mkCoVarCo, getCoVar_maybe)
import qualified CoreSyn as CoreSyn (CoreExpr, Expr(Var))
import Type        (mkTyVarTy, getTyVar_maybe)
import Id          (mkSysLocal)
import Var         (Id, TyVar, CoVar, isTyVar, mkTyVar, varType)
import OccName     (occNameFS)
import Name        (getOccName, mkSysTvName)
import FastString  (FastString)
import UniqFM      (ufmToList)
import VarEnv


-- We are going to use GHC's substitution type in a rather stylised way, and only
-- ever substitute variables for variables. The reasons for this are twofold:
--
--  1. Particularly since we are in ANF, doing any other sort of substitution is unnecessary
--
--  2. We have our own syntax data type, and we don't want to build a GHC syntax tree just
--     for insertion into the Subst if we can help it!
--
-- Unfortunately, in order to make this work with the coercionful operational semantics
-- we will sometimes need to substitute coerced variables for variables. An example would be
-- when reducing:
--
--  (\x. e) |> gam y
--
-- Where
--
--  gam = (F Int -> F Int ~ Bool -> Bool)
--
-- We need to reduce to something like:
--
--  e[(y |> sym (nth 1 gam))/x] |> (nth 2 gam)
--
-- We deal with this problem in the evaluator by introducing an intermediate let binding for
-- such redexes.

type Renaming = (IdSubstEnv, TvSubstEnv, CvSubstEnv)

joinSubst :: InScopeSet -> Renaming -> Subst
joinSubst iss (id_subst, tv_subst, co_subst) = mkSubst iss tv_subst co_subst id_subst

-- GHC's binder-renaming stuff does this awful thing where a var->var renaming
-- will always be added to the InScopeSet (which is really an InScopeMap) but
-- will only be added to the IdSubstEnv *if the unique changes*.
--
-- This is a problem for us because we only store the Renaming with each In thing,
-- not the full Subst. So we might lose some renamings recorded only in the InScopeSet.
--
-- The solution is either:
--  1) Rewrite the rest of the supercompiler so it stores a Subst with each binding.
--     Given the behaviour of GHCs binder-renamer, this is probably cleaner (and matches
--     what the GHC does), but I'm not really interested in doing that work right now.
--
--     It also means you have te be very careful to join together InScopeSets if you
--     pull one of those Subst-paired things down into a strictly deeper context. This
--     is easy to get wrong.
--
--  2) Ensure that we always extend the IdSubstEnv, regardless of whether the unique changed.
--     This is the solution I've adopted, and it is implemented here in splitSubst:
splitSubst :: Subst -> [(Var, Var)] -> (InScopeSet, Renaming)
splitSubst (Subst iss id_subst tv_subst co_subst) extend
  = (iss, foldVarlikes (\f -> foldr (\x_x' -> f (fst x_x') x_x')) extend
                       (\(x, x') -> first3  (\id_subst -> extendVarEnv id_subst x (varToCoreSyn x')))
                       (\(a, a') -> second3 (\tv_subst -> extendVarEnv tv_subst a (mkTyVarTy a')))
                       (\(q, q') -> third3  (\co_subst -> extendVarEnv co_subst q (mkCoVarCo q')))
                       (id_subst, tv_subst, co_subst))

-- NB: this used to return a triple of lists, but I introduced this version due to profiling
-- results that indicated a caller (renameFreeVars) was causing 2% of all allocations. It turns
-- out that I managed to achieve deforestation in all of the callers by rewriting them to use this
-- version instead.
{-# INLINE foldVarlikes #-}
foldVarlikes :: ((Var -> a -> b -> b) -> b -> f_a -> b)
             -> f_a
             -> (a -> b -> b) -- Id continuation
             -> (a -> b -> b) -- TyVar continuation
             -> (a -> b -> b) -- CoVar continuation
             -> b -> b
foldVarlikes fold as id tv co acc = fold go acc as
  where go x a res | isTyVar x = tv a res
                   | isCoVar x = co a res
                   | otherwise = id a res

emptyRenaming :: Renaming
emptyRenaming = (emptyVarEnv, emptyVarEnv, emptyVarEnv)

mkIdentityRenaming :: FreeVars -> Renaming
mkIdentityRenaming fvs = foldVarlikes (\f -> foldVarSet (\x -> f x x)) fvs
                                      (\x -> first3  (\id_subst -> extendVarEnv id_subst x (varToCoreSyn x)))
                                      (\a -> second3 (\tv_subst -> extendVarEnv tv_subst a (mkTyVarTy a)))
                                      (\q -> third3  (\co_subst -> extendVarEnv co_subst q (mkCoVarCo q)))
                                      (emptyVarEnv, emptyVarEnv, emptyVarEnv)

mkInScopeIdentityRenaming :: InScopeSet -> Renaming
mkInScopeIdentityRenaming = mkIdentityRenaming . getInScopeVars

mkTyVarRenaming :: [(TyVar, Type)] -> Renaming
mkTyVarRenaming aas = (emptyVarEnv, mkVarEnv aas, emptyVarEnv)

invertRenaming :: Renaming -> Maybe Renaming
invertRenaming (id_subst, tv_subst, co_subst)
  = liftM3 (,,) (traverse coreSynToVar_maybe id_subst >>= invertVarEnv (\fs uniq -> varToCoreSyn . mkSysLocal fs uniq))
                (traverse getTyVar_maybe     tv_subst >>= invertVarEnv (\fs uniq -> mkTyVarTy    . mkTyVar (mkSysTvName uniq fs)))
                (traverse getCoVar_maybe     co_subst >>= invertVarEnv (\fs uniq -> mkCoVarCo    . mkSysLocal fs uniq))
  where
    -- FIXME: this inversion relies on something of a hack because the domain of the mapping is not stored (only its Unique)
    invertVarEnv :: (FastString -> Unique -> Type -> a)
                 -> VarEnv Var -> Maybe (VarEnv a)
    invertVarEnv mk env
      | distinct (varEnvElts env) = Just (mkVarEnv [(x, mk (occNameFS (getOccName x)) u (varType x)) | (u, x) <- ufmToList env])
      | otherwise                 = Nothing

varToCoreSyn :: Var -> CoreSyn.CoreExpr
varToCoreSyn = CoreSyn.Var

coreSynToVar_maybe :: CoreSyn.CoreExpr -> Maybe Var
coreSynToVar_maybe (CoreSyn.Var x') = Just x'
coreSynToVar_maybe _                = Nothing

coreSynToVar :: CoreSyn.CoreExpr -> Var
coreSynToVar = fromMaybe (panic "renameId" empty) . coreSynToVar_maybe

insertIdRenaming :: Renaming -> Id -> Out Id -> Renaming
insertIdRenaming (id_subst, tv_subst, co_subst) x x'
  = (extendVarEnv id_subst x (varToCoreSyn x'), tv_subst, co_subst)

insertIdRenamings :: Renaming -> [(Id, Out Id)] -> Renaming
insertIdRenamings = foldr (\(x, x') rn -> insertIdRenaming rn x x')

insertTypeSubst :: Renaming -> TyVar -> Out Type -> Renaming
insertTypeSubst (id_subst, tv_subst, co_subst) x ty' = (id_subst, extendVarEnv tv_subst x ty', co_subst)

insertTypeSubsts :: Renaming -> [(TyVar, Out Type)] -> Renaming
insertTypeSubsts (id_subst, tv_subst, co_subst) xtys = (id_subst, extendVarEnvList tv_subst xtys, co_subst)

insertCoercionSubst :: Renaming -> CoVar -> Out Coercion -> Renaming
insertCoercionSubst (id_subst, tv_subst, co_subst) x co' = (id_subst, tv_subst, extendVarEnv co_subst x co')

insertCoercionSubsts :: Renaming -> [(CoVar, Out Coercion)] -> Renaming
insertCoercionSubsts (id_subst, tv_subst, co_subst) xcos = (id_subst, tv_subst, extendVarEnvList co_subst xcos)

-- NB: these three function can supply emptyInScopeSet because of what I do in splitSubst

renameId :: Renaming -> Id -> Out Id
renameId rn = coreSynToVar . lookupIdSubst (text "renameId") (joinSubst emptyInScopeSet rn)

lookupTyVarSubst :: Renaming -> TyVar -> Out Type
lookupTyVarSubst rn = lookupTvSubst (joinSubst emptyInScopeSet rn)

lookupCoVarSubst :: Renaming -> CoVar -> Out Coercion
lookupCoVarSubst rn = lookupCvSubst (joinSubst emptyInScopeSet rn)


type In a = (Renaming, a)
type Out a = a


inFreeVars :: (a -> FreeVars) -> In a -> FreeVars
inFreeVars thing_fvs (rn, thing) = renameFreeVars rn (thing_fvs thing)

renameFreeVars :: Renaming -> FreeVars -> FreeVars
renameFreeVars rn fvs = foldVarlikes (\f -> foldVarSet (\x -> f x x)) fvs
                                     (\x -> flip extendVarSet (renameId rn x))
                                     (\a -> unionVarSet (tyVarsOfType (lookupTyVarSubst rn a)))
                                     (\q -> unionVarSet (tyCoVarsOfCo (lookupCoVarSubst rn q)))
                                     emptyVarSet

renameType :: InScopeSet -> Renaming -> Type -> Type
renameType iss rn = substTy (joinSubst iss rn)

renameCoercion :: InScopeSet -> Renaming -> Coercion -> NormalCo
renameCoercion iss (_, tv_subst, co_subst) = optCoercion (CvSubst iss tv_subst co_subst)


renameIn :: (Renaming -> a -> a) -> In a -> a
renameIn f (rn, x) = f rn x


renameBinders :: InScopeSet -> Renaming -> [Var] -> (InScopeSet, Renaming, [Var])
renameBinders iss rn xs = (iss', rn', xs')
  where (subst', xs') = substRecBndrs (joinSubst iss rn) xs
        (iss', rn') = splitSubst subst' (xs `zip` xs')

renameNonRecBinder :: InScopeSet -> Renaming -> Var -> (InScopeSet, Renaming, Var)
renameNonRecBinder iss rn x = (iss', rn', x')
  where (subst', x') = substBndr (joinSubst iss rn) x
        (iss', rn') = splitSubst subst' [(x, x')]

renameNonRecBinders :: InScopeSet -> Renaming -> [Var] -> (InScopeSet, Renaming, [Var])
renameNonRecBinders iss rn xs = (iss', rn', xs')
  where (subst', xs') = substBndrs (joinSubst iss rn) xs
        (iss', rn') = splitSubst subst' (xs `zip` xs')


renameBounds :: InScopeSet -> Renaming -> [(Var, a)] -> (InScopeSet, Renaming, [(Var, In a)])
renameBounds iss rn xes = (iss', rn', xs' `zip` map ((,) rn') es)
  where (xs, es) = unzip xes
        (iss', rn', xs') = renameBinders iss rn xs

renameNonRecBound :: InScopeSet -> Renaming -> (Var, a) -> (InScopeSet, Renaming, (Var, In a))
renameNonRecBound iss rn (x, e) = (iss', rn', (x', (rn, e)))
  where (iss', rn', x') = renameNonRecBinder iss rn x


(renameTerm,                renameAlts,                renameValue,                renameValue')                = mkRename (\f rn (I e) -> I (f rn e))
(renameFVedTerm,            renameFVedAlts,            renameFVedValue,            renameFVedValue')            = mkRename (\f rn (FVed fvs e) -> FVed (renameFreeVars rn fvs) (f rn e))
(renameTaggedTerm,          renameTaggedAlts,          renameTaggedValue,          renameTaggedValue')          = mkRename (\f rn (Tagged tg e) -> Tagged tg (f rn e))
(renameTaggedSizedFVedTerm, renameTaggedSizedFVedAlts, renameTaggedSizedFVedValue, renameTaggedSizedFVedValue') = mkRename (\f rn (Comp (Tagged tg (Comp (Sized sz (FVed fvs e))))) -> Comp (Tagged tg (Comp (Sized sz (FVed (renameFreeVars rn fvs) (f rn e))))))

{-# INLINE mkRename #-}
mkRename :: (forall a. (Renaming -> a -> a) -> Renaming -> ann a -> ann a)
         -> (InScopeSet -> Renaming -> ann (TermF ann)  -> ann (TermF ann),
             InScopeSet -> Renaming -> [AltF ann]       -> [AltF ann],
             InScopeSet -> Renaming -> ann (ValueF ann) -> ann (ValueF ann),
             InScopeSet -> Renaming -> ValueF ann       -> ValueF ann)
mkRename rec = (term, alternatives, value, value')
  where
    term ids rn = rec (term' ids) rn
    term' ids rn e = case e of
      Var x -> Var (renameId rn x)
      Value v -> Value (value' ids rn v)
      TyApp e ty -> TyApp (term ids rn e) (renameType ids rn ty)
      CoApp e co -> CoApp (term ids rn e) (renameCoercion ids rn co)
      App e x -> App (term ids rn e) (renameId rn x)
      PrimOp pop tys es -> PrimOp pop (map (renameType ids rn) tys) (map (term ids rn) es)
      Case e x ty alts -> Case (term ids rn e) x' (renameType ids rn ty) (alternatives ids' rn' alts)
        where (ids', rn', x') = renameNonRecBinder ids rn x
      Let x e1 e2 -> Let x' (renameIn (term ids) in_e1) (term ids' rn' e2)
        where (ids', rn', (x', in_e1)) = renameNonRecBound ids rn (x, e1)
      LetRec xes e -> LetRec (map (second (renameIn (term ids'))) xes') (term ids' rn' e)
        where (ids', rn', xes') = renameBounds ids rn xes
      Cast e co -> Cast (term ids rn e) (renameCoercion ids rn co)
    
    value ids rn = rec (value' ids) rn
    value' ids rn v = case v of
      Indirect x -> Indirect (renameId rn x)
      TyLambda x e -> TyLambda x' (term ids' rn' e)
        where (ids', rn', x') = renameNonRecBinder ids rn x
      Lambda x e -> Lambda x' (term ids' rn' e)
        where (ids', rn', x') = renameNonRecBinder ids rn x
      Data dc tys cos xs -> Data dc (map (renameType ids rn) tys) (map (renameCoercion ids rn) cos) (map (renameId rn) xs)
      Literal l -> Literal l
      Coercion co -> Coercion (renameCoercion ids rn co)
    
    alternatives ids rn = map (alternative ids rn)
    
    alternative ids rn (alt_con, alt_e) = (alt_con', term ids' rn' alt_e)
        where (ids', rn', alt_con') = renameAltCon ids rn alt_con

renameAltCon :: InScopeSet -> Renaming -> AltCon -> (InScopeSet, Renaming, AltCon)
renameAltCon ids rn_alt alt_con = case alt_con of
    DataAlt alt_dc alt_as alt_qs alt_xs -> third3 (DataAlt alt_dc alt_as' alt_qs') $ renameNonRecBinders ids1 rn_alt1 alt_xs
      where (ids0, rn_alt0, alt_as') = renameNonRecBinders ids rn_alt alt_as
            (ids1, rn_alt1, alt_qs') = renameNonRecBinders ids0 rn_alt0 alt_qs
    LiteralAlt _                        -> (ids, rn_alt, alt_con)
    DefaultAlt                          -> (ids, rn_alt, alt_con)
