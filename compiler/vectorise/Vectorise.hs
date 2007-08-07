module Vectorise( vectorise )
where

#include "HsVersions.h"

import VectMonad
import VectUtils
import VectType
import VectCore

import DynFlags
import HscTypes

import CoreLint             ( showPass, endPass )
import CoreSyn
import CoreUtils
import CoreFVs
import SimplMonad           ( SimplCount, zeroSimplCount )
import Rules                ( RuleBase )
import DataCon
import TyCon
import Type
import FamInstEnv           ( extendFamInstEnvList )
import InstEnv              ( extendInstEnvList )
import Var
import VarEnv
import VarSet
import Name                 ( Name, mkSysTvName, getName )
import NameEnv
import Id
import MkId                 ( unwrapFamInstScrut )
import OccName
import RdrName              ( RdrName, mkRdrQual )
import Module               ( mkModuleNameFS )

import DsMonad hiding (mapAndUnzipM)
import DsUtils              ( mkCoreTup, mkCoreTupTy )

import Literal              ( Literal )
import PrelNames
import TysWiredIn
import TysPrim              ( intPrimTy )
import BasicTypes           ( Boxity(..) )

import Outputable
import FastString
import Control.Monad        ( liftM, liftM2, zipWithM, mapAndUnzipM )

mkNDPVar :: FastString -> RdrName
mkNDPVar fs = mkRdrQual nDP_BUILTIN (mkVarOccFS fs)

builtin_PAs :: [(Name, RdrName)]
builtin_PAs = [(intTyConName, mkNDPVar FSLIT("dPA_Int"))]

vectorise :: HscEnv -> UniqSupply -> RuleBase -> ModGuts
          -> IO (SimplCount, ModGuts)
vectorise hsc_env _ _ guts
  = do
      showPass dflags "Vectorisation"
      eps <- hscEPS hsc_env
      let info = hptVectInfo hsc_env `plusVectInfo` eps_vect_info eps
      Just (info', guts') <- initV hsc_env guts info (vectModule guts)
      endPass dflags "Vectorisation" Opt_D_dump_vect (mg_binds guts')
      return (zeroSimplCount dflags, guts' { mg_vect_info = info' })
  where
    dflags = hsc_dflags hsc_env

vectModule :: ModGuts -> VM ModGuts
vectModule guts
  = do
      defTyConRdrPAs builtin_PAs
      (types', fam_insts) <- vectTypeEnv (mg_types guts)
      
      let fam_inst_env' = extendFamInstEnvList (mg_fam_inst_env guts) fam_insts
      updGEnv (setFamInstEnv fam_inst_env')
     
      -- dicts   <- mapM buildPADict pa_insts
      -- workers <- mapM vectDataConWorkers pa_insts
      binds'  <- mapM vectTopBind (mg_binds guts)
      return $ guts { mg_types        = types'
                    , mg_binds        = -- Rec (concat workers ++ concat dicts) :
                                        binds'
                    , mg_fam_inst_env = fam_inst_env'
                    , mg_fam_insts    = mg_fam_insts guts ++ fam_insts
                    }

vectTopBind :: CoreBind -> VM CoreBind
vectTopBind b@(NonRec var expr)
  = do
      var'  <- vectTopBinder var
      expr' <- vectTopRhs var expr
      hs    <- takeHoisted
      return . Rec $ (var, expr) : (var', expr') : hs
  `orElseV`
    return b

vectTopBind b@(Rec bs)
  = do
      vars'  <- mapM vectTopBinder vars
      exprs' <- zipWithM vectTopRhs vars exprs
      hs     <- takeHoisted
      return . Rec $ bs ++ zip vars' exprs' ++ hs
  `orElseV`
    return b
  where
    (vars, exprs) = unzip bs

vectTopBinder :: Var -> VM Var
vectTopBinder var
  = do
      vty  <- vectType (idType var)
      var' <- cloneId mkVectOcc var vty
      defGlobalVar var var'
      return var'
    
vectTopRhs :: Var -> CoreExpr -> VM CoreExpr
vectTopRhs var expr
  = do
      closedV . liftM vectorised
              . inBind var
              $ vectPolyExpr (freeVars expr)

-- ----------------------------------------------------------------------------
-- Bindings

vectBndr :: Var -> VM VVar
vectBndr v
  = do
      vty <- vectType (idType v)
      lty <- mkPArrayType vty
      let vv = v `Id.setIdType` vty
          lv = v `Id.setIdType` lty
      updLEnv (mapTo vv lv)
      return (vv, lv)
  where
    mapTo vv lv env = env { local_vars = extendVarEnv (local_vars env) v (vv, lv) }

vectBndrIn :: Var -> VM a -> VM (VVar, a)
vectBndrIn v p
  = localV
  $ do
      vv <- vectBndr v
      x <- p
      return (vv, x)

vectBndrsIn :: [Var] -> VM a -> VM ([VVar], a)
vectBndrsIn vs p
  = localV
  $ do
      vvs <- mapM vectBndr vs
      x <- p
      return (vvs, x)

-- ----------------------------------------------------------------------------
-- Expressions

vectVar :: Var -> VM VExpr
vectVar v
  = do
      r <- lookupVar v
      case r of
        Local (vv,lv) -> return (Var vv, Var lv)
        Global vv     -> do
                           let vexpr = Var vv
                           lexpr <- liftPA vexpr
                           return (vexpr, lexpr)

vectPolyVar :: Var -> [Type] -> VM VExpr
vectPolyVar v tys
  = do
      vtys <- mapM vectType tys
      r <- lookupVar v
      case r of
        Local (vv, lv) -> liftM2 (,) (polyApply (Var vv) vtys)
                                     (polyApply (Var lv) vtys)
        Global poly    -> do
                            vexpr <- polyApply (Var poly) vtys
                            lexpr <- liftPA vexpr
                            return (vexpr, lexpr)

vectLiteral :: Literal -> VM VExpr
vectLiteral lit
  = do
      lexpr <- liftPA (Lit lit)
      return (Lit lit, lexpr)

vectPolyExpr :: CoreExprWithFVs -> VM VExpr
vectPolyExpr expr
  = polyAbstract tvs $ \abstract ->
    do
      mono' <- vectExpr mono
      return $ mapVect abstract mono'
  where
    (tvs, mono) = collectAnnTypeBinders expr  
                
vectExpr :: CoreExprWithFVs -> VM VExpr
vectExpr (_, AnnType ty)
  = liftM vType (vectType ty)

vectExpr (_, AnnVar v) = vectVar v

vectExpr (_, AnnLit lit) = vectLiteral lit

vectExpr (_, AnnNote note expr)
  = liftM (vNote note) (vectExpr expr)

vectExpr e@(_, AnnApp _ arg)
  | isAnnTypeArg arg
  = vectTyAppExpr fn tys
  where
    (fn, tys) = collectAnnTypeArgs e

vectExpr (_, AnnApp fn arg)
  = do
      fn'  <- vectExpr fn
      arg' <- vectExpr arg
      mkClosureApp fn' arg'

vectExpr (_, AnnCase expr bndr ty alts)
  = panic "vectExpr: case"

vectExpr (_, AnnLet (AnnNonRec bndr rhs) body)
  = do
      vrhs <- localV . inBind bndr $ vectPolyExpr rhs
      (vbndr, vbody) <- vectBndrIn bndr (vectExpr body)
      return $ vLet (vNonRec vbndr vrhs) vbody

vectExpr (_, AnnLet (AnnRec bs) body)
  = do
      (vbndrs, (vrhss, vbody)) <- vectBndrsIn bndrs
                                $ liftM2 (,)
                                  (zipWithM vect_rhs bndrs rhss)
                                  (vectPolyExpr body)
      return $ vLet (vRec vbndrs vrhss) vbody
  where
    (bndrs, rhss) = unzip bs

    vect_rhs bndr rhs = localV
                      . inBind bndr
                      $ vectExpr rhs

vectExpr e@(fvs, AnnLam bndr _)
  | not (isId bndr) = pprPanic "vectExpr" (ppr $ deAnnotate e)
  | otherwise = vectLam fvs bs body
  where
    (bs,body) = collectAnnValBinders e

vectLam :: VarSet -> [Var] -> CoreExprWithFVs -> VM VExpr
vectLam fvs bs body
  = do
      tyvars <- localTyVars
      (vs, vvs) <- readLEnv $ \env ->
                   unzip [(var, vv) | var <- varSetElems fvs
                                    , Just vv <- [lookupVarEnv (local_vars env) var]]

      arg_tys <- mapM (vectType . idType) bs
      res_ty  <- vectType (exprType $ deAnnotate body)

      buildClosures tyvars vvs arg_tys res_ty
        . hoistPolyVExpr tyvars
        $ do
            lc <- builtin liftingContext
            (vbndrs, vbody) <- vectBndrsIn (vs ++ bs)
                                           (vectExpr body)
            return $ vLams lc vbndrs vbody
  
vectTyAppExpr :: CoreExprWithFVs -> [Type] -> VM VExpr
vectTyAppExpr (_, AnnVar v) tys = vectPolyVar v tys
vectTyAppExpr e tys = pprPanic "vectTyAppExpr" (ppr $ deAnnotate e)

