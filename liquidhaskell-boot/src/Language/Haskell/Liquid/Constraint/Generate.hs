{-# LANGUAGE DeriveTraversable         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE PatternGuards             #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ImplicitParams            #-}

{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

-- | This module defines the representation of Subtyping and WF Constraints,
--   and the code for syntax-directed constraint generation.

module Language.Haskell.Liquid.Constraint.Generate ( generateConstraints, generateConstraintsWithEnv, caseEnv, consE ) where

import           Prelude                                       hiding ()
import           GHC.Stack
import           Liquid.GHC.API                   as Ghc hiding ( panic
                                                                                 , checkErr
                                                                                 , (<+>)
                                                                                 , text
                                                                                 , vcat
                                                                                 )
import           Liquid.GHC.TypeRep           ()
import           Text.PrettyPrint.HughesPJ hiding ((<>))
import           Control.Monad.State
import qualified Control.Monad.State.Strict                    as ST
import           Data.Functor ((<&>))
import           Data.Maybe                                    (fromMaybe, catMaybes, isJust, mapMaybe, isNothing)
import qualified Data.HashMap.Strict                           as M
import qualified Data.HashSet                                  as S
import qualified Data.List                                     as L
import qualified Data.Foldable                                 as F
import           Data.Hashable                                 (Hashable, hashWithSalt)
import qualified Data.Traversable                              as T
import qualified Data.Text                                     as Text
import qualified Data.Text.Encoding                            as Text
import qualified Data.Functor.Identity

import           Language.Haskell.Liquid.Constraint.ToFixpoint (makeSimplify)
import           Language.Fixpoint.Misc
import           Language.Fixpoint.Types.Sorts                 (charSort, isChar, isString, strSort)
import           Language.Fixpoint.SortCheck                   (toExpr)
import           Language.Fixpoint.Solver.Simplify             as F
import           Language.Fixpoint.Solver.Rewrite              as F
import           Language.Fixpoint.Types.Visitor
import qualified Language.Fixpoint.Types                       as F
import qualified Language.Fixpoint.Types.Visitor               as F
import           Language.Haskell.Liquid.Constraint.Fresh
import           Language.Haskell.Liquid.Constraint.Init
import           Language.Haskell.Liquid.Constraint.Env
import           Language.Haskell.Liquid.Constraint.Monad
import           Language.Haskell.Liquid.Constraint.Split
import           Language.Haskell.Liquid.Constraint.Relational (consAssmRel, consRelTop)
import           Language.Haskell.Liquid.Types.Dictionaries
import qualified Liquid.GHC.Resugar           as Rs
import qualified Liquid.GHC.SpanStack         as Sp
import qualified Liquid.GHC.Misc         as GM -- ( isInternal, collectArguments, tickSrcSpan, showPpr )
import           Language.Haskell.Liquid.Misc
import           Language.Haskell.Liquid.Constraint.Types
import           Language.Haskell.Liquid.Constraint.Constraint
import           Language.Haskell.Liquid.Transforms.Rec
import           Language.Haskell.Liquid.Transforms.CoreToLogic (weakenResult, runToLogic, coreToLogic)
import           Language.Haskell.Liquid.Bare.DataType (dataConMap, makeDataConChecker)

import           Language.Haskell.Liquid.Types hiding (binds, Loc, loc, Def)
--import Debug.Trace (trace)

--------------------------------------------------------------------------------
-- | Constraint Generation: Toplevel -------------------------------------------
--------------------------------------------------------------------------------
generateConstraints      :: TargetInfo -> CGInfo
--------------------------------------------------------------------------------
generateConstraints info = {-# SCC "ConsGen" #-} execState act $ initCGI cfg info
  where
    act                  = do { γ <- initEnv info; consAct γ cfg info }
    cfg                  = getConfig   info

generateConstraintsWithEnv :: TargetInfo -> CGInfo -> CGEnv -> CGInfo
--------------------------------------------------------------------------------
generateConstraintsWithEnv info cgi γ = {-# SCC "ConsGenEnv" #-} execState act cgi
  where
    act                  = consAct γ cfg info
    cfg                  = getConfig   info

consAct :: CGEnv -> Config -> TargetInfo -> CG ()
consAct γ cfg info = do
  let sSpc = gsSig . giSpec $ info
  let gSrc = giSrc info
  when (gradual cfg) (mapM_ (addW . WfC γ . val . snd) (gsTySigs sSpc ++ gsAsmSigs sSpc))
  γ' <- foldM (consCBTop cfg info) γ (giCbs gSrc)
  -- Relational Checking: the following only runs when the list of relational specs is not empty
  (ψ, γ'') <- foldM (consAssmRel cfg info) ([], γ') (gsAsmRel sSpc ++ gsRelation sSpc)
  mapM_ (consRelTop cfg info γ'' ψ) (gsRelation sSpc)
  -- End: Relational Checking
  mapM_ (consClass γ) (gsMethods $ gsSig $ giSpec info)
  hcs <- gets hsCs
  hws <- gets hsWfs
  fcs <- concat <$> mapM (splitC (typeclass (getConfig info))) hcs
  fws <- concat <$> mapM splitW hws
  modify $ \st -> st { fEnv     = fEnv    st `mappend` feEnv (fenv γ)
                     , cgLits   = litEnv   γ
                     , cgConsts = cgConsts st `mappend` constEnv γ
                     , fixCs    = fcs
                     , fixWfs   = fws }



--------------------------------------------------------------------------------
-- | Ensure that the instance type is a subtype of the class type --------------
--------------------------------------------------------------------------------

consClass :: CGEnv -> (Var, MethodType LocSpecType) -> CG ()
consClass γ (x,mt)
  | Just ti <- tyInstance mt
  , Just tc <- tyClass    mt
  = addC (SubC (γ `setLocation` Sp.Span (GM.fSrcSpan (F.loc ti))) (val ti) (val tc)) ("cconsClass for " ++ GM.showPpr x)
consClass _ _
  = return ()

--------------------------------------------------------------------------------
-- | Quotient aliasing/erasure                                    --------------
--------------------------------------------------------------------------------
{-aliasQuotients :: CGInfo -> CGInfo
aliasQuotients = x
  where
    aliasInFixSubC :: FixSubC -> FixSubC
    aliasInFixSubC sbc = x

    aliasInFixWfC :: FixWfC -> FixWfC
    aliasInFixWfC = x-}


--------------------------------------------------------------------------------
-- | TERMINATION TYPE ----------------------------------------------------------
--------------------------------------------------------------------------------
makeDecrIndex :: (Var, Template SpecType, [Var]) -> CG [Int]
makeDecrIndex (x, Assumed t, args)
  = do dindex <- makeDecrIndexTy x t args
       case dindex of
         Left msg -> addWarning msg >> return []
         Right i -> return i
makeDecrIndex (x, Asserted t, args)
  = do dindex <- makeDecrIndexTy x t args
       case dindex of
         Left msg -> addWarning msg >> return []
         Right i  -> return i
makeDecrIndex _ = return []

makeDecrIndexTy :: Var -> SpecType -> [Var] -> CG (Either (TError t) [Int])
makeDecrIndexTy x st args
  = do spDecr <- gets specDecr
       autosz <- gets autoSize
       hint   <- checkHint' autosz (L.lookup x spDecr)
       case dindex autosz of
         Nothing -> return $ Left msg
         Just i  -> return $ Right $ fromMaybe [i] hint
    where
       ts   = ty_args trep
       tvs  = zip ts args
       msg  = ErrTermin (getSrcSpan x) [F.pprint x] (text "No decreasing parameter")
       cenv = makeNumEnv ts
       trep = toRTypeRep $ unOCons st

       p autosz (t, v)   = isDecreasing autosz cenv t && not (isIdTRecBound v)
       checkHint' autosz = checkHint x ts (isDecreasing autosz cenv)
       dindex     autosz = L.findIndex (p autosz) tvs


recType :: F.Symbolic a
        => S.HashSet TyCon
        -> (([a], [Int]), (t, [Int], SpecType))
        -> SpecType
recType _ ((_, []), (_, [], t))
  = t

recType autoenv ((vs, indexc), (_, index, t))
  = makeRecType autoenv t v dxt index
  where v    = (vs !!)  <$> indexc
        dxt  = (xts !!) <$> index
        xts  = zip (ty_binds trep) (ty_args trep)
        trep = toRTypeRep $ unOCons t

checkIndex :: (NamedThing t, PPrint t, PPrint a)
           => (t, [a], Template (RType c tv r), [Int])
           -> CG [Maybe (RType c tv r)]
checkIndex (x, vs, t, index)
  = do mapM_ (safeLogIndex msg1 vs) index
       mapM  (safeLogIndex msg2 ts) index
    where
       loc   = getSrcSpan x
       ts    = ty_args $ toRTypeRep $ unOCons $ unTemplate t
       msg1  = ErrTermin loc [xd] ("No decreasing" <+> F.pprint index <-> "-th argument on" <+> xd <+> "with" <+> F.pprint vs)
       msg2  = ErrTermin loc [xd] "No decreasing parameter"
       xd    = F.pprint x

makeRecType :: (Enum a1, Eq a1, Num a1, F.Symbolic a)
            => S.HashSet TyCon
            -> SpecType
            -> [a]
            -> [(F.Symbol, SpecType)]
            -> [a1]
            -> SpecType
makeRecType autoenv t vs dxs is
  = mergecondition t $ fromRTypeRep $ trep {ty_binds = xs', ty_args = ts'}
  where
    (xs', ts') = unzip $ replaceN (last is) (safeFromLeft "makeRecType" $ makeDecrType autoenv vdxs) xts
    vdxs       = zip vs dxs
    xts        = zip (ty_binds trep) (ty_args trep)
    trep       = toRTypeRep $ unOCons t

unOCons :: RType c tv r -> RType c tv r
unOCons (RAllT v t r)      = RAllT v (unOCons t) r
unOCons (RAllP p t)        = RAllP p $ unOCons t
unOCons (RFun x i tx t r)  = RFun x i (unOCons tx) (unOCons t) r
unOCons (RRTy _ _ OCons t) = unOCons t
unOCons t                  = t

mergecondition :: RType c tv r -> RType c tv r -> RType c tv r
mergecondition (RAllT _ t1 _) (RAllT v t2 r2)          = RAllT v (mergecondition t1 t2) r2
mergecondition (RAllP _ t1) (RAllP p t2)               = RAllP p (mergecondition t1 t2)
mergecondition (RRTy xts r OCons t1) t2                = RRTy xts r OCons (mergecondition t1 t2)
mergecondition (RFun _ _ t11 t12 _) (RFun x2 i t21 t22 r2) = RFun x2 i (mergecondition t11 t21) (mergecondition t12 t22) r2
mergecondition _ t                                     = t

safeLogIndex :: Error -> [a] -> Int -> CG (Maybe a)
safeLogIndex err ls n
  | n >= length ls = addWarning err >> return Nothing
  | otherwise      = return $ Just $ ls !! n

checkHint :: (NamedThing a, PPrint a, PPrint a1)
          => a -> [a1] -> (a1 -> Bool) -> Maybe [Int] -> CG (Maybe [Int])
checkHint _ _ _ Nothing
  = return Nothing

checkHint x _ _ (Just ns) | L.sort ns /= ns
  = addWarning (ErrTermin loc [dx] (text "The hints should be increasing")) >> return Nothing
  where
    loc = getSrcSpan x
    dx  = F.pprint x

checkHint x ts f (Just ns)
  = mapM (checkValidHint x ts f) ns <&> (Just . catMaybes)

checkValidHint :: (NamedThing a, PPrint a, PPrint a1)
               => a -> [a1] -> (a1 -> Bool) -> Int -> CG (Maybe Int)
checkValidHint x ts f n
  | n < 0 || n >= length ts = addWarning err >> return Nothing
  | f (ts L.!! n)           = return $ Just n
  | otherwise               = addWarning err >> return Nothing
  where
    err = ErrTermin loc [xd] (vcat [ "Invalid Hint" <+> F.pprint (n+1) <+> "for" <+> xd
                                   , "in"
                                   , F.pprint ts ])
    loc = getSrcSpan x
    xd  = F.pprint x

--------------------------------------------------------------------------------
consCBLet :: CGEnv -> CoreBind -> CG CGEnv
--------------------------------------------------------------------------------
consCBLet γ cb = do
  oldtcheck <- gets tcheck
  isStr     <- doTermCheck (getConfig γ) cb
  -- TODO: yuck.
  modify $ \s -> s { tcheck = oldtcheck && isStr }
  γ' <- consCB (oldtcheck && isStr) isStr γ cb
  modify $ \s -> s{tcheck = oldtcheck}
  return γ'

--------------------------------------------------------------------------------
-- | Constraint Generation: Corebind -------------------------------------------
--------------------------------------------------------------------------------
consCBTop :: Config -> TargetInfo -> CGEnv -> CoreBind -> CG CGEnv
--------------------------------------------------------------------------------
consCBTop cfg info cgenv cb
  | all (trustVar cfg info) xs
  = foldM addB cgenv xs
    where
       xs   = bindersOf cb
       tt   = trueTy (typeclass cfg) . varType
       addB γ x = tt x >>= (\t -> γ += ("derived", F.symbol x, t))

consCBTop _ _ γ cb
  = do oldtcheck <- gets tcheck
       -- lazyVars  <- specLazy <$> get
       isStr     <- doTermCheck (getConfig γ) cb
       modify $ \s -> s { tcheck = oldtcheck && isStr}
       -- remove invariants that came from the cb definition
       let (γ', i) = removeInvariant γ cb                 --- DIFF
       γ'' <- consCB (oldtcheck && isStr) isStr (γ'{cgVar = topBind cb}) cb
       modify $ \s -> s { tcheck = oldtcheck}
       return $ restoreInvariant γ'' i                    --- DIFF
    where
      topBind (NonRec v _)  = Just v
      topBind (Rec [(v,_)]) = Just v
      topBind _             = Nothing

trustVar :: Config -> TargetInfo -> Var -> Bool
trustVar cfg info x = not (checkDerived cfg) && derivedVar (giSrc info) x

derivedVar :: TargetSrc -> Var -> Bool
derivedVar src x = S.member x (giDerVars src)

doTermCheck :: Config -> Bind Var -> CG Bool
doTermCheck cfg bind = do
  lazyVs    <- gets specLazy
  termVs    <- gets specTmVars
  let skip   = any (\x -> S.member x lazyVs || nocheck x) xs
  let chk    = not (structuralTerm cfg) || any (`S.member` termVs) xs
  return     $ chk && not skip
  where
    nocheck  = if typeclass cfg then GM.isEmbeddedDictVar else GM.isInternal
    xs       = bindersOf bind

-- nonStructTerm && not skip

-- RJ: AAAAAAARGHHH!!!!!! THIS CODE IS HORRIBLE!!!!!!!!!
consCBSizedTys :: CGEnv -> [(Var, CoreExpr)] -> CG CGEnv
consCBSizedTys γ xes
  = do xets     <- forM xes $ \(x, e) -> fmap (x, e,) (varTemplate γ (x, Just e))
       autoenv  <- gets autoSize
       ts       <- mapM (T.mapM refreshArgs) (thd3 <$> xets)
       let vs    = zipWith collectArgs' ts es
       is       <- mapM makeDecrIndex (zip3 vars ts vs) >>= checkSameLens
       let xeets = (\vis -> [(vis, x) | x <- zip3 vars is $ map unTemplate ts]) <$> zip vs is
       _ <- mapM checkIndex (zip4 vars vs ts is) >>= checkEqTypes . L.transpose
       let rts   = (recType autoenv <$>) <$> xeets
       let xts   = zip vars ts
       γ'       <- foldM extender γ xts
       let γs    = zipWith makeRecInvariants [γ' `setTRec` zip vars rts' | rts' <- rts] (filter (not . noMakeRec) <$> vs)
       let xets' = zip3 vars es ts
       mapM_ (uncurry $ consBind True) (zip γs xets')
       return γ'
  where
       noMakeRec      = if allowTC then GM.isEmbeddedDictVar else GM.isPredVar
       allowTC        = typeclass (getConfig γ)
       (vars, es)     = unzip xes
       dxs            = F.pprint <$> vars
       collectArgs'   = GM.collectArguments . length . ty_binds . toRTypeRep . unOCons . unTemplate
       checkEqTypes :: [[Maybe SpecType]] -> CG [[SpecType]]
       checkEqTypes x = mapM (checkAll' err1 toRSort) (catMaybes <$> x)
       checkSameLens  = checkAll' err2 length
       err1           = ErrTermin loc dxs $ text "The decreasing parameters should be of same type"
       err2           = ErrTermin loc dxs $ text "All Recursive functions should have the same number of decreasing parameters"
       loc            = getSrcSpan (head vars)

       checkAll' _   _ []            = return []
       checkAll' err f (x:xs)
         | all (== f x) (f <$> xs) = return (x:xs)
         | otherwise                = addWarning err >> return []

consCBWithExprs :: CGEnv -> [(Var, CoreExpr)] -> CG CGEnv
consCBWithExprs γ xes
  = do xets     <- forM xes $ \(x, e) -> fmap (x, e,) (varTemplate γ (x, Just e))
       texprs   <- gets termExprs
       let xtes  = mapMaybe (`lookup'` texprs) xs
       let ts    = safeFromAsserted err . thd3 <$> xets
       ts'      <- mapM refreshArgs ts
       let xts   = zip xs (Asserted <$> ts')
       γ'       <- foldM extender γ xts
       let γs    = makeTermEnvs γ' xtes xes ts ts'
       let xets' = zip3 xs es (Asserted <$> ts')
       mapM_ (uncurry $ consBind True) (zip γs xets')
       return γ'
  where (xs, es) = unzip xes
        lookup' k m | Just x <- M.lookup k m = Just (k, x)
                    | otherwise              = Nothing
        err      = "Constant: consCBWithExprs"

makeTermEnvs :: CGEnv -> [(Var, [F.Located F.Expr])] -> [(Var, CoreExpr)]
             -> [SpecType] -> [SpecType]
             -> [CGEnv]
makeTermEnvs γ xtes xes ts ts' = setTRec γ . zip xs <$> rts
  where
    vs   = zipWith collectArgs' ts ces
    syms = fst5 . bkArrowDeep <$> ts
    syms' = fst5 . bkArrowDeep <$> ts'
    sus' = zipWith mkSub syms syms'
    sus  = zipWith mkSub syms ((F.symbol <$>) <$> vs)
    ess  = (\x -> safeFromJust (err x) (x `L.lookup` xtes)) <$> xs
    tes  = zipWith (\su es -> F.subst su <$> es)  sus ess
    tes' = zipWith (\su es -> F.subst su <$> es)  sus' ess
    rss  = zipWith makeLexRefa tes' <$> (repeat <$> tes)
    rts  = zipWith (addObligation OTerm) ts' <$> rss
    (xs, ces)    = unzip xes
    mkSub ys ys' = F.mkSubst [(x, F.EVar y) | (x, y) <- zip ys ys']
    collectArgs' = GM.collectArguments . length . ty_binds . toRTypeRep
    err x        = "Constant: makeTermEnvs: no terminating expression for " ++ GM.showPpr x

addObligation :: Oblig -> SpecType -> RReft -> SpecType
addObligation o t r  = mkArrow αs πs xts $ RRTy [] r o t2
  where
    (αs, πs, t1) = bkUniv t
    ((xs, is, ts, rs), t2) = bkArrow t1
    xts              = zip4 xs is ts rs

--------------------------------------------------------------------------------
consCB :: Bool -> Bool -> CGEnv -> CoreBind -> CG CGEnv
--------------------------------------------------------------------------------
-- do termination checking
consCB True _ γ (Rec xes)
  = do texprs <- gets termExprs
       modify $ \i -> i { recCount = recCount i + length xes }
       let xxes = mapMaybe (`lookup'` texprs) xs
       if null xxes
         then consCBSizedTys γ xes
         else check xxes <$> consCBWithExprs γ xes
    where
      xs = map fst xes
      check ys r | length ys == length xs = r
                 | otherwise              = panic (Just loc) msg
      msg        = "Termination expressions must be provided for all mutually recursive binders"
      loc        = getSrcSpan (head xs)
      lookup' k m = (k,) <$> M.lookup k m

-- don't do termination checking, but some strata checks?
consCB _ False γ (Rec xes)
  = do xets     <- forM xes $ \(x, e) -> (x, e,) <$> varTemplate γ (x, Just e)
       modify     $ \i -> i { recCount = recCount i + length xes }
       let xts    = [(x, to) | (x, _, to) <- xets]
       γ'        <- foldM extender (γ `setRecs` (fst <$> xts)) xts
       mapM_ (consBind True γ') xets
       return γ'

-- don't do termination checking, and don't do any strata checks either?
consCB _ _ γ (Rec xes)
  = do xets   <- forM xes $ \(x, e) -> fmap (x, e,) (varTemplate γ (x, Just e))
       modify $ \i -> i { recCount = recCount i + length xes }
       let xts = [(x, to) | (x, _, to) <- xets]
       γ'     <- foldM extender (γ `setRecs` (fst <$> xts)) xts
       mapM_ (consBind True γ') xets
       return γ'

-- | NV: Dictionaries are not checked, because
-- | class methods' preconditions are not satisfied
consCB _ _ γ (NonRec x _) | isDictionary x
  = do t  <- trueTy (typeclass (getConfig γ)) (varType x)
       extender γ (x, Assumed t)
    where
       isDictionary = isJust . dlookup (denv γ)

consCB _ _ γ (NonRec x def)
  | Just (w, τ) <- grepDictionary def
  , Just d      <- dlookup (denv γ) w
  = do st       <- mapM (trueTy (typeclass (getConfig γ))) τ
       mapM_ addW (WfC γ <$> st)
       let xts   = dmap (fmap (f st)) d
       let  γ'   = γ { denv = dinsert (denv γ) x xts }
       t        <- trueTy (typeclass (getConfig γ)) (varType x)
       extender γ' (x, Assumed t)
   where
    f [t']    (RAllT α te _) = subsTyVarMeet' (ty_var_value α, t') te
    f (t':ts) (RAllT α te _) = f ts $ subsTyVarMeet' (ty_var_value α, t') te
    f _ _ = impossible Nothing "consCB on Dictionary: this should not happen"

consCB _ _ γ (NonRec x e)
  = do to  <- varTemplate γ (x, Nothing)
       to' <- consBind False γ (x, e, to) >>= addPostTemplate γ
       extender γ (x, makeSingleton γ (simplify e) <$> to')

grepDictionary :: CoreExpr -> Maybe (Var, [Type])
grepDictionary = go []
  where
    go ts (App (Var w) (Type t)) = Just (w, reverse (t:ts))
    go ts (App e (Type t))       = go (t:ts) e
    go ts (App e (Var _))        = go ts e
    go ts (Let _ e)              = go ts e
    go _ _                       = Nothing

--------------------------------------------------------------------------------
consBind :: Bool -> CGEnv -> (Var, CoreExpr, Template SpecType) -> CG (Template SpecType)
--------------------------------------------------------------------------------
consBind _ _ (x, _, Assumed t)
  | RecSelId {} <- idDetails x -- don't check record selectors with assumed specs
  = return $ F.notracepp ("TYPE FOR SELECTOR " ++ show x) $ Assumed t

consBind isRec' γ (x, e, Asserted spect)
  = do let γ'       = γ `setBind` x
           (_,πs,_) = bkUniv spect
       cgenv    <- foldM addPToEnv γ' πs
       cconsE cgenv e (weakenResult (typeclass (getConfig γ)) x spect)
       when (F.symbol x `elemHEnv` holes γ) $
         -- have to add the wf constraint here for HOLEs so we have the proper env
         addW $ WfC cgenv $ fmap killSubst spect
       addIdA x (defAnn isRec' spect)
       return $ Asserted spect

consBind isRec' γ (x, e, Internal spect)
  = do let γ'       = γ `setBind` x
           (_,πs,_) = bkUniv spect
       γπ    <- foldM addPToEnv γ' πs
       let γπ' = γπ {cerr = Just $ ErrHMeas (getLocation γπ) (pprint x) (text explanation)}
       cconsE γπ' e spect
       when (F.symbol x `elemHEnv` holes γ) $
         -- have to add the wf constraint here for HOLEs so we have the proper env
         addW $ WfC γπ $ fmap killSubst spect
       addIdA x (defAnn isRec' spect)
       return $ Internal spect
  where
    explanation = "Cannot give singleton type to the function definition."

consBind isRec' γ (x, e, Assumed spect)
  = do let γ' = γ `setBind` x
       γπ    <- foldM addPToEnv γ' πs
       cconsE γπ e =<< true (typeclass (getConfig γ)) spect
       addIdA x (defAnn isRec' spect)
       return $ Asserted spect
    where πs   = ty_preds $ toRTypeRep spect

consBind isRec' γ (x, e, Unknown)
  = do t'    <- consE (γ `setBind` x) e
       t     <- topSpecType x t'
       addIdA x (defAnn isRec' t)
       when (GM.isExternalId x) (addKuts x t)
       return $ Asserted t

killSubst :: RReft -> RReft
killSubst = fmap killSubstReft

killSubstReft :: F.Reft -> F.Reft
killSubstReft = trans kv () ()
  where
    kv    = defaultVisitor { txExpr = ks }
    ks _ (F.PKVar k _) = F.PKVar k mempty
    ks _ p             = p

defAnn :: Bool -> t -> Annot t
defAnn True  = AnnRDf
defAnn False = AnnDef

addPToEnv :: CGEnv
          -> PVar RSort -> CG CGEnv
addPToEnv γ π
  = do γπ <- γ += ("addSpec1", pname π, pvarRType π)
       foldM (+=) γπ [("addSpec2", x, ofRSort t) | (t, x, _) <- pargs π]

extender :: F.Symbolic a => CGEnv -> (a, Template SpecType) -> CG CGEnv
extender γ (x, Asserted t)
  = case lookupREnv (F.symbol x) (assms γ) of
      Just t' -> γ += ("extender", F.symbol x, t')
      _       -> γ += ("extender", F.symbol x, t)
extender γ (x, Assumed t)
  = γ += ("extender", F.symbol x, t)
extender γ _
  = return γ

data Template a
  = Asserted a
  | Assumed a
  | Internal a
  | Unknown
  deriving (Functor, F.Foldable, T.Traversable)

deriving instance (Show a) => (Show (Template a))

instance PPrint a => PPrint (Template a) where
  pprintTidy k (Asserted t) = "Asserted" <+> pprintTidy k t
  pprintTidy k (Assumed  t) = "Assumed"  <+> pprintTidy k t
  pprintTidy k (Internal t) = "Internal" <+> pprintTidy k t
  pprintTidy _ Unknown      = "Unknown"

unTemplate :: Template t -> t
unTemplate (Asserted t) = t
unTemplate (Assumed t)  = t
unTemplate (Internal t) = t
unTemplate _            = panic Nothing "Constraint.Generate.unTemplate called on `Unknown`"

addPostTemplate :: CGEnv
                -> Template SpecType
                -> CG (Template SpecType)
addPostTemplate γ (Asserted t) = Asserted <$> addPost γ t
addPostTemplate γ (Assumed  t) = Assumed  <$> addPost γ t
addPostTemplate γ (Internal t) = Internal  <$> addPost γ t
addPostTemplate _ Unknown      = return Unknown

safeFromAsserted :: [Char] -> Template t -> t
safeFromAsserted _ (Asserted t) = t
safeFromAsserted msg _ = panic Nothing $ "safeFromAsserted:" ++ msg

-- | @varTemplate@ is only called with a `Just e` argument when the `e`
-- corresponds to the body of a @Rec@ binder.
varTemplate :: CGEnv -> (Var, Maybe CoreExpr) -> CG (Template SpecType)
varTemplate γ (x, eo) = varTemplate' γ (x, eo) >>= mapM (topSpecType x)

-- | @lazVarTemplate@ is like `varTemplate` but for binders that are *not*
--   termination checked and hence, the top-level refinement / KVar is
--   stripped out. e.g. see tests/neg/T743.hs
-- varTemplate :: CGEnv -> (Var, Maybe CoreExpr) -> CG (Template SpecType)
-- lazyVarTemplate γ (x, eo) = dbg <$> (topRTypeBase <$>) <$> varTemplate' γ (x, eo)
--   where
--    dbg   = traceShow ("LAZYVAR-TEMPLATE: " ++ show x)

varTemplate' :: CGEnv -> (Var, Maybe CoreExpr) -> CG (Template SpecType)
varTemplate' γ (x, eo)
  = case (eo, lookupREnv (F.symbol x) (grtys γ), lookupREnv (F.symbol x) (assms γ), lookupREnv (F.symbol x) (intys γ)) of
      (_, Just t, _, _) -> Asserted <$> refreshArgsTop (x, t)
      (_, _, _, Just t) -> Internal <$> refreshArgsTop (x, t)
      (_, _, Just t, _) -> Assumed  <$> refreshArgsTop (x, t)
      (Just e, _, _, _) -> do t  <- freshTyExpr (typeclass (getConfig γ)) (RecBindE x) e (exprType e)
                              addW (WfC γ t)
                              Asserted <$> refreshArgsTop (x, t)
      (_,      _, _, _) -> return Unknown

-- | @topSpecType@ strips out the top-level refinement of "derived var"
topSpecType :: Var -> SpecType -> CG SpecType
topSpecType x t = do
  info <- gets ghcI
  return $ if derivedVar (giSrc info) x then topRTypeBase t else t

--------------------------------------------------------------------------------
-- | Bidirectional Constraint Generation: CHECKING -----------------------------
--------------------------------------------------------------------------------
cconsE :: CGEnv -> CoreExpr -> SpecType -> CG ()
--------------------------------------------------------------------------------
cconsE g e t = do
  -- NOTE: tracing goes here
  -- traceM $ printf "cconsE:\n  expr = %s\n  exprType = %s\n  lqType = %s\n" (showPpr e) (showPpr (exprType e)) (showpp t)
  cconsE' g e t

--------------------------------------------------------------------------------
cconsE' :: CGEnv -> CoreExpr -> SpecType -> CG ()
--------------------------------------------------------------------------------
cconsE' γ (Case e x τ cases) t
  = do γ'  <- consCBLet γ (NonRec x e)
       γs  <- forM cases $ cconsCase γ' x t nonDefAlts

       case lookupREnv (F.symbol x) (renv γ') of
         Just (RApp (RQTyCon _ ut qs vs _) ts _ _) -> do
           forM_ (respectCases γs qs) $ \(u, q, bs, syms, cγ) -> do
            let baseT  = rTypeSort (emb cγ) $ appQuotTyCon ut vs ts
                vSub   = zip vs $ map (const () <$>) ts
            checkRespectability cγ syms qCodomain (applyCase cγ baseT) u (applySub vSub q) bs
         _                                       -> return ()
    where
      qCodomain :: Maybe QuotientSpec
      qCodomain = case t of
        RApp (RQTyCon n _ _ _ _) _ _ _ -> M.lookup (F.val n) $ cgQuotTyCons γ
        _                              -> Nothing

      applySub :: [(RTyVar, RSort)] -> RQuotient -> RQuotient
      applySub ss q = q
        { rqtVars = subts ss <$> rqtVars q
        }

      applyCase :: CGEnv -> F.Sort -> F.Expr -> CG (Maybe F.Expr)
      applyCase cγ ut r = do
        adts    <- gets cgADTs
        let dm   = dataConMap adts
        let expr = coreToLogic True (Case (Var x) x τ cases)
        case runToLogic (emb cγ) mempty dm (\m -> todo Nothing ("coreToLogic not working applyCase: " ++ m)) expr of
          Left  er -> error $ show er
          Right ce -> Just <$> normaliseWithBind cγ (F.symbol x) ut ce r

      respectCases :: [CGEnv] -> [F.Symbol] -> [(QuotientUnifier, RQuotient, Expr CoreBndr, [F.Symbol], CGEnv)]
      respectCases γs qs
        = [ (u, q, ae, map F.symbol bndrs, γ')
          | (a, bndrs, ae, γ') <- fullNonDefAlts γs
          , q              <- mapMaybe (`M.lookup` cgQuotients γ) qs
          , let u = unifyWithQuotient a bndrs q
          , isUnified u
          ]

      isUnified :: QuotientUnifier -> Bool
      isUnified DidNotUnify = False
      isUnified _           = True

      fullNonDefAlts :: [CGEnv] -> [(AltCon, [CoreBndr], Expr CoreBndr, CGEnv)]
      fullNonDefAlts γs = [ (a, bndrs, ae, γ') | (γ', Alt a bndrs ae) <- zip γs cases, a /= DEFAULT ]

      nonDefAlts = [a | Alt a _ _ <- cases, a /= DEFAULT]
      _msg = "cconsE' #nonDefAlts = " ++ show (length nonDefAlts)

cconsE' γ e t
  | Just (Rs.PatSelfBind _x e') <- Rs.lift e
  = cconsE' γ e' t

  | Just (Rs.PatSelfRecBind x e') <- Rs.lift e
  = let γ' = γ { grtys = insertREnv (F.symbol x) t (grtys γ)}
     in void $ consCBLet γ' (Rec [(x, e')])

cconsE' γ e@(Let b@(NonRec x _) ee) t
  = do sp <- gets specLVars
       let γ' = removeFreeBinder (F.symbol x) γ
       if x `S.member` sp
         then cconsLazyLet γ' e t
         else do γ''  <- consCBLet γ' b
                 cconsE γ'' ee t

cconsE' γ e (RAllP p t)
  = cconsE γ' e t''
  where
    t'         = replacePredsWithRefs su <$> t
    su         = (uPVar p, pVartoRConc p)
    (css, t'') = splitConstraints (typeclass (getConfig γ)) t'
    γ'         = L.foldl' addConstraints γ css

cconsE' γ (Let b e) t
  = do γ'  <- consCBLet γ b
       cconsE γ' e t

cconsE' γ (Lam α e) (RAllT α' t r) | isTyVar α
  = do γ' <- updateEnvironment γ α
       addForAllConstraint γ' α e (RAllT α' t r)
       cconsE (addFreeBinder (F.symbol α) γ') e $ subsTyVarMeet' (ty_var_value α', rVar α) t

cconsE' γ (Lam x e) (RFun y i ty t r)
  | not (isTyVar x)
  = do γ' <- γ += ("cconsE", x', ty)
       cconsE (addFreeBinder (F.symbol x) γ') e t'
       addFunctionConstraint γ x e (RFun x' i ty t' r')
       addIdA x (AnnDef ty)
  where
    x'  = F.symbol x
    t'  = t `F.subst1` (y, F.EVar x')
    r'  = r `F.subst1` (y, F.EVar x')

cconsE' γ (Tick tt e) t
  = cconsE (γ `setLocation` Sp.Tick tt) e t

cconsE' γ (Cast e co) t
  -- See Note [Type classes with a single method]
  | Just f <- isClassConCo co
  = cconsE γ (f e) t

cconsE' γ e@(Cast e' c) t
  = do t' <- castTy γ (exprType e) e' c
       addC (SubC γ (F.notracepp ("Casted Type for " ++ GM.showPpr e ++ "\n init type " ++ showpp t) t') t) ("cconsE Cast: " ++ GM.showPpr e)

{-
cconsE' γ e (RApp (RQTyCon _ ut _ tvs _) ts _ _)
  = cconsE' γ e (appQuotTyCon ut tvs ts)-}

cconsE' γ e t
  = do  te  <- consE γ e
        te' <- instantiatePreds γ e te >>= addPost γ

        let sub
              = if isCheckDataConApp γ then case te' of
                  RApp (RQTyCon _ ut _ vs _) ts _ _ -> SubC γ (appQuotTyCon ut vs ts) t
                  _ -> SubC γ te' t
                else
                  SubC γ te' t

        addC sub ("cconsE: " ++ "\n t = " ++ showpp t ++ "\n te = " ++ showpp te ++ GM.showPpr e)

lambdaSingleton :: CGEnv -> F.TCEmb TyCon -> Var -> CoreExpr -> CG (UReft F.Reft)
lambdaSingleton γ tce x e
  | higherOrderFlag γ
  = lamExpr γ e >>= \case
      Just e' -> return $ uTop $ F.exprReft $ F.ELam (F.symbol x, sx) e'
      _ -> return mempty
  where
    sx = typeSort tce $ Ghc.expandTypeSynonyms $ varType x
lambdaSingleton _ _ _ _
  = return mempty

addForAllConstraint :: CGEnv -> Var -> CoreExpr -> SpecType -> CG ()
addForAllConstraint γ _ _ (RAllT rtv rt rr)
  | F.isTauto rr
  = return ()
  | otherwise
  = do t'       <- true (typeclass (getConfig γ)) rt
       let truet = RAllT rtv $ unRAllP t'
       addC (SubC γ (truet mempty) $ truet rr) "forall constraint true"
  where unRAllP (RAllT a t r) = RAllT a (unRAllP t) r
        unRAllP (RAllP _ t)   = unRAllP t
        unRAllP t             = t
addForAllConstraint γ _ _ _
  = impossible (Just $ getLocation γ) "addFunctionConstraint: called on non function argument"

addFunctionConstraint :: CGEnv -> Var -> CoreExpr -> SpecType -> CG ()
addFunctionConstraint γ x e (RFun y i ty t r)
  = do ty'      <- true (typeclass (getConfig γ)) ty
       t'       <- true (typeclass (getConfig γ)) t
       let truet = RFun y i ty' t'
       lamE <- lamExpr γ e
       case (lamE, higherOrderFlag γ) of
          (Just e', True) -> do tce    <- gets tyConEmbed
                                let sx  = typeSort tce $ varType x
                                let ref = uTop $ F.exprReft $ F.ELam (F.symbol x, sx) e'
                                addC (SubC γ (truet ref) $ truet r)    "function constraint singleton"
          _ -> addC (SubC γ (truet mempty) $ truet r) "function constraint true"
addFunctionConstraint γ _ _ _
  = impossible (Just $ getLocation γ) "addFunctionConstraint: called on non function argument"

splitConstraints :: TyConable c
                 => Bool -> RType c tv r -> ([[(F.Symbol, RType c tv r)]], RType c tv r)
splitConstraints allowTC (RRTy cs _ OCons t)
  = let (css, t') = splitConstraints allowTC t in (cs:css, t')
splitConstraints allowTC (RFun x i tx@(RApp c _ _ _) t r) | isErasable c
  = let (css, t') = splitConstraints allowTC  t in (css, RFun x i tx t' r)
  where isErasable = if allowTC then isEmbeddedDict else isClass
splitConstraints _ t
  = ([], t)

-------------------------------------------------------------------
-- | @instantiatePreds@ peels away the universally quantified @PVars@
--   of a @RType@, generates fresh @Ref@ for them and substitutes them
--   in the body.
-------------------------------------------------------------------
instantiatePreds :: CGEnv
                 -> CoreExpr
                 -> SpecType
                 -> CG SpecType
instantiatePreds γ e (RAllP π t)
  = do r     <- freshPredRef γ e π
       instantiatePreds γ e $ replacePreds "consE" t [(π, r)]

instantiatePreds _ _ t0
  = return t0


-------------------------------------------------------------------
cconsLazyLet :: CGEnv
             -> CoreExpr
             -> SpecType
             -> CG ()
cconsLazyLet γ (Let (NonRec x ex) e) t
  = do tx <- trueTy (typeclass (getConfig γ)) (varType x)
       γ' <- (γ, "Let NonRec") +++= (x', ex, tx)
       cconsE γ' e t
    where
       x' = F.symbol x

cconsLazyLet _ _ _
  = panic Nothing "Constraint.Generate.cconsLazyLet called on invalid inputs"

--------------------------------------------------------------------------------
-- | Bidirectional Constraint Generation: SYNTHESIS ----------------------------
--------------------------------------------------------------------------------
consE :: CGEnv -> CoreExpr -> CG SpecType
--------------------------------------------------------------------------------
consE γ e
  | patternFlag γ
  , Just p <- Rs.lift e
  = consPattern γ (F.notracepp "CONSE-PATTERN: " p) (exprType e)

-- NV CHECK 3 (unVar and does this hack even needed?)
-- NV (below) is a hack to type polymorphic axiomatized functions
-- no need to check this code with flag, the axioms environment with
-- is empty if there is no axiomatization.

-- [NOTE: PLE-OPT] We *disable* refined instantiation for
-- reflected functions inside proofs.

-- If datacon definitions have references to self for fancy termination,
-- ignore them at the construction.
consE γ (Var x) | GM.isDataConId x
  = do t0 <- varRefType γ x
       -- NV: The check is expected to fail most times, so
       --     it is cheaper than direclty fmap ignoreSelf.
       let hasSelf = selfSymbol `elem` F.syms t0
       let t = if hasSelf
                then fmap ignoreSelf <$> t0
                else t0
       addLocA (Just x) (getLocation γ) (varAnn γ x t)
       return t

consE γ (Var x)
  = do t <- varRefType γ x
       addLocA (Just x) (getLocation γ) (varAnn γ x t)
       return t

consE _ (Lit c)
  = refreshVV $ uRType $ literalFRefType c

consE γ e'@(App e a@(Type τ))
  = do RAllT α te _ <- checkAll ("Non-all TyApp with expr", e) γ <$> consE (setIsCheckDataConApp False γ) e
       t            <- if not (nopolyinfer (getConfig γ)) && isPos α && isGenericVar (ty_var_value α) te
                         then freshTyType (typeclass (getConfig γ)) TypeInstE e τ
                         else trueTy (typeclass (getConfig γ)) τ
       addW          $ WfC γ t
       t'           <- refreshVV t
       tt0          <- instantiatePreds γ e' (subsTyVarMeet' (ty_var_value α, t') te)
       let tt        = makeSingleton γ (simplify e') $ subsTyReft γ (ty_var_value α) τ tt0
       case rTVarToBind α of
         Just (x, _) -> return $ maybe (checkUnbound (setIsCheckDataConApp False γ) e' x tt a) (F.subst1 tt . (x,)) (argType τ)
         Nothing     -> return tt
  where
    isPos α = not (extensionality (getConfig γ)) || rtv_is_pol (ty_var_info α)

consE γ e'@(App e a) | Just aDict <- getExprDict γ a
  = case dhasinfo (dlookup (denv γ) aDict) (getExprFun γ e) of
      Just riSig -> return $ fromRISig riSig
      _          -> do
        ([], πs, te) <- bkUniv <$> consE γ e
        te'          <- instantiatePreds γ e' $ foldr RAllP te πs
        (γ', te''')  <- dropExists γ te'
        te''         <- dropConstraints γ te'''
        updateLocA {- πs -}  (exprLoc e) te''
        let RFun x _ tx t _ = checkFun ("Non-fun App with caller ", e') γ te''
        cconsE (setIsCheckDataConApp False γ') a tx
        addPost γ'        $ maybe (checkUnbound γ' e' x t a) (F.subst1 t . (x,)) (argExpr γ a)

consE γ e'@(App e a)
  = do ([], πs, te) <- bkUniv <$> consE γ {- GM.tracePpr ("APP-EXPR: " ++ GM.showPpr (exprType e)) -} e
       te1        <- instantiatePreds γ e' $ foldr RAllP te πs
       (γ', te2)  <- dropExists γ te1
       te3        <- dropConstraints γ te2
       updateLocA (exprLoc e) te3
       let RFun x _ tx t _ = checkFun ("Non-fun App with caller ", e') γ te3

       isDC <- isDCApp e

       cconsE (setIsCheckDataConApp isDC γ') a tx
       makeSingleton γ' (simplify e') <$> addPost γ' (maybe (checkUnbound γ' e' x t a) (F.subst1 t . (x,)) (argExpr γ $ simplify a))

consE γ (Lam α e) | isTyVar α
  = do γ' <- updateEnvironment γ α
       t' <- consE (setIsCheckDataConApp False γ') e
       return $ RAllT (makeRTVar $ rTyVar α) t' mempty

consE γ  e@(Lam x e1)
  = do tx      <- freshTyType (typeclass (getConfig γ)) LamE (Var x) τx
       γ'      <- γ += ("consE", F.symbol x, tx)
       t1      <- consE (setIsCheckDataConApp False γ') e1
       addIdA x $ AnnDef tx
       addW     $ WfC γ tx
       tce     <- gets tyConEmbed
       lamSing <- lambdaSingleton γ tce x e1
       return   $ RFun (F.symbol x) (mkRFInfo $ getConfig γ) tx t1 lamSing
    where
      FunTy { ft_arg = τx } = exprType e

consE γ e@(Let _ _)
  = cconsFreshE LetE (setIsCheckDataConApp False γ) e

consE γ e@(Case _ _ _ [_])
  | Just p@Rs.PatProject{} <- Rs.lift e
  = consPattern (setIsCheckDataConApp False γ) p (exprType e)

consE γ e@(Case _ _ _ cs)
  = cconsFreshE (caseKVKind cs) (setIsCheckDataConApp False γ) e

consE γ (Tick tt e)
  = do t <- consE (setLocation (setIsCheckDataConApp False γ) (Sp.Tick tt)) e
       addLocA Nothing (GM.tickSrcSpan tt) (AnnUse t)
       return t

-- See Note [Type classes with a single method]
consE γ (Cast e co)
  | Just f <- isClassConCo co
  = consE γ (f e)

consE γ e@(Cast e' c)
  = castTy γ (exprType e) e' c

consE γ e@(Coercion _)
   = trueTy (typeclass (getConfig γ)) $ exprType e

consE _ e@(Type t)
  = panic Nothing $ "consE cannot handle type " ++ GM.showPpr (e, t)

isDCApp :: CoreExpr -> CG Bool
isDCApp (App e _) = isDCApp e
isDCApp (Var v)   = gets (L.elem v . map fst . dataConTys)
isDCApp _         = return False

caseKVKind ::[Alt Var] -> KVKind
caseKVKind [Alt (DataAlt _) _ (Var _)] = ProjectE
caseKVKind cs                      = CaseE (length cs)

updateEnvironment :: CGEnv  -> TyVar -> CG CGEnv
updateEnvironment γ a
  | isValKind (tyVarKind a)
  = γ += ("varType", F.symbol $ varName a, kindToRType $ tyVarKind a)
  | otherwise
  = return γ

getExprFun :: CGEnv -> CoreExpr -> Var
getExprFun γ e          = go e
  where
    go (App x (Type _)) = go x
    go (Var x)          = x
    go _                = panic (Just (getLocation γ)) msg
    msg                 = "getFunName on \t" ++ GM.showPpr e

-- | `exprDict e` returns the dictionary `Var` inside the expression `e`
getExprDict :: CGEnv -> CoreExpr -> Maybe Var
getExprDict γ           =  go
  where
    go (Var x)          = case dlookup (denv γ) x of {Just _ -> Just x; Nothing -> Nothing}
    go (Tick _ e)       = go e
    go (App a (Type _)) = go a
    go (Let _ e)        = go e
    go _                = Nothing

--------------------------------------------------------------------------------
-- | With GADTs and reflection, refinements can contain type variables,
--   as 'coercions' (see ucsd-progsys/#1424). At application sites, we
--   must also substitute those from the refinements (not just the types).
--      https://github.com/ucsd-progsys/liquidhaskell/issues/1424
--
--   see: tests/ple/{pos,neg}/T1424.hs
--
--------------------------------------------------------------------------------

subsTyReft :: CGEnv -> RTyVar -> Type -> SpecType -> SpecType
subsTyReft γ a t = mapExprReft (\_ -> F.applyCoSub coSub)
  where
    coSub        = M.fromList [(F.symbol a, typeSort (emb γ) t)]

--------------------------------------------------------------------------------
-- | Type Synthesis for Special @Pattern@s -------------------------------------
--------------------------------------------------------------------------------
consPattern :: CGEnv -> Rs.Pattern -> Type -> CG SpecType

{- [NOTE] special type rule for monadic-bind application

    G |- e1 ~> m tx     G, x:tx |- e2 ~> m t
    -----------------------------------------
          G |- (e1 >>= \x -> e2) ~> m t
 -}

consPattern γ (Rs.PatBind e1 x e2 _ _ _ _ _) _ = do
  tx <- checkMonad (msg, e1) γ <$> consE γ e1
  γ' <- γ += ("consPattern", F.symbol x, tx)
  addIdA x (AnnDef tx)
  consE γ' e2
  where
    msg = "This expression has a refined monadic type; run with --no-pattern-inline: "

{- [NOTE] special type rule for monadic-return

           G |- e ~> et
    ------------------------
      G |- return e ~ m et
 -}
consPattern γ (Rs.PatReturn e m _ _ _) t = do
  et    <- F.notracepp "Cons-Pattern-Ret" <$> consE γ e
  mt    <- trueTy (typeclass (getConfig γ))  m
  tt    <- trueTy (typeclass (getConfig γ))  t
  return (mkRAppTy mt et tt) -- /// {-    $ RAppTy mt et mempty -}

{- [NOTE] special type rule for field projection, is
          t  = G(x)       ti = Proj(t, i)
    -----------------------------------------
      G |- case x of C [y1...yn] -> yi : ti
 -}

consPattern γ (Rs.PatProject xe _ τ c ys i) _ = do
  let yi = ys !! i
  t    <- (addW . WfC γ) <<= freshTyType (typeclass (getConfig γ)) ProjectE (Var yi) τ
  γ'   <- caseEnv γ xe [] (DataAlt c) ys (Just [i])
  ti   <- {- γ' ??= yi -} varRefType γ' yi
  addC (SubC γ' ti t) "consPattern:project"
  return t

consPattern γ (Rs.PatSelfBind _ e) _ =
  consE γ e

consPattern γ p@Rs.PatSelfRecBind{} _ =
  cconsFreshE LetE γ (Rs.lower p)

mkRAppTy :: SpecType -> SpecType -> SpecType -> SpecType
mkRAppTy mt et RAppTy{}          = RAppTy mt et mempty
mkRAppTy _  et (RApp c [_] [] _) = RApp c [et] [] mempty
mkRAppTy _  _  _                 = panic Nothing "Unexpected return-pattern"

checkMonad :: (Outputable a) => (String, a) -> CGEnv -> SpecType -> SpecType
checkMonad x g = go . unRRTy
 where
   go (RApp _ ts [] _)
     | not (null ts) = last ts
   go (RAppTy _ t _) = t
   go t              = checkErr x g t

unRRTy :: SpecType -> SpecType
unRRTy (RRTy _ _ _ t) = unRRTy t
unRRTy t              = t

--------------------------------------------------------------------------------
castTy  :: CGEnv -> Type -> CoreExpr -> Coercion -> CG SpecType
castTy' :: CGEnv -> Type -> CoreExpr -> CG SpecType
--------------------------------------------------------------------------------
castTy γ t e (AxiomInstCo ca _ _)
  = fromMaybe <$> castTy' γ t e <*> lookupNewType (coAxiomTyCon ca)

castTy γ t e (SymCo (AxiomInstCo ca _ _))
  = do mtc <- lookupNewType (coAxiomTyCon ca)
       F.forM_ mtc (cconsE γ e)
       castTy' γ t e

castTy γ t e _
  = castTy' γ t e


castTy' γ τ (Var x)
  = do t0 <- trueTy (typeclass (getConfig γ)) τ
       tx <- varRefType γ x
       let t = mergeCastTys t0 tx
       let ce = if typeclass (getConfig γ) && noADT (getConfig γ) then F.expr x
                else eCoerc (typeSort (emb γ) $ Ghc.expandTypeSynonyms $ varType x)
                       (typeSort (emb γ) τ)
                       $ F.expr x
       return (t `strengthen` uTop (F.uexprReft ce) {- `F.meet` tx -})
  where eCoerc s t e
         | s == t    = e
         | otherwise = F.ECoerc s t e

castTy' γ t (Tick _ e)
  = castTy' γ t e

castTy' _ _ e
  = panic Nothing $ "castTy cannot handle expr " ++ GM.showPpr e


{-
mergeCastTys tcorrect trefined
  tcorrect has the correct GHC skeleton,
  trefined has the correct refinements (before coercion)
  mergeCastTys keeps the trefined when the two GHC types match
-}

mergeCastTys :: SpecType -> SpecType -> SpecType
mergeCastTys t1 t2
  | toType False t1 == toType False t2
  = t2
mergeCastTys (RApp c1 ts1 ps1 r1) (RApp c2 ts2 _ _)
  | c1 == c2
  = RApp c1 (zipWith mergeCastTys ts1 ts2) ps1 r1
mergeCastTys t _
  = t

{-
showCoercion :: Coercion -> String
showCoercion (AxiomInstCo co1 co2 co3)
  = "AxiomInstCo " ++ showPpr co1 ++ "\t\t " ++ showPpr co2 ++ "\t\t" ++ showPpr co3 ++ "\n\n" ++
    "COAxiom Tycon = "  ++ showPpr (coAxiomTyCon co1) ++ "\nBRANCHES\n" ++ concatMap showBranch bs
  where
    bs = fromBranchList $ co_ax_branches co1
    showBranch ab = "\nCoAxiom \nLHS = " ++ showPpr (coAxBranchLHS ab) ++
                    "\nRHS = " ++ showPpr (coAxBranchRHS ab)
showCoercion (SymCo c)
  = "Symc :: " ++ showCoercion c
showCoercion c
  = "Coercion " ++ showPpr c
-}

isClassConCo :: Coercion -> Maybe (Expr Var -> Expr Var)
-- See Note [Type classes with a single method]
isClassConCo co
  | Pair t1 t2 <- coercionKind co
  , isClassPred t2
  , (tc,ts) <- splitTyConApp t2
  , [dc]    <- tyConDataCons tc
  , [tm]    <- map irrelevantMult (Ghc.dataConOrigArgTys dc)
               -- tcMatchTy because we have to instantiate the class tyvars
  , Just _  <- ruleMatchTyX (mkUniqSet $ tyConTyVars tc) (mkRnEnv2 emptyInScopeSet) emptyTvSubstEnv tm t1
  = Just (\e -> mkCoreConApps dc $ map Type ts ++ [e])

  | otherwise
  = Nothing
  where
    ruleMatchTyX =ruleMatchTyKiX -- TODO: is this correct?

----------------------------------------------------------------------
-- Note [Type classes with a single method]
----------------------------------------------------------------------
-- GHC 7.10 encodes type classes with a single method as newtypes and
-- `cast`s between the method and class type instead of applying the
-- class constructor. Just rewrite the core to what we're used to
-- seeing..
--
-- specifically, we want to rewrite
--
--   e `cast` ((a -> b) ~ C)
--
-- to
--
--   D:C e
--
-- but only when
--
--   D:C :: (a -> b) -> C

--------------------------------------------------------------------------------
-- | @consFreshE@ is used to *synthesize* types with a **fresh template**.
--   e.g. at joins, recursive binders, polymorphic instantiations etc. It is
--   the "portal" that connects `consE` (synthesis) and `cconsE` (checking)
--------------------------------------------------------------------------------
cconsFreshE :: KVKind -> CGEnv -> CoreExpr -> CG SpecType
cconsFreshE kvkind γ e = do
  t   <- freshTyType (typeclass (getConfig γ)) kvkind e $ exprType e
  addW $ WfC γ t
  cconsE γ e t
  return t
--------------------------------------------------------------------------------

checkUnbound :: (Show a, Show a2, F.Subable a)
             => CGEnv -> CoreExpr -> F.Symbol -> a -> a2 -> a
checkUnbound γ e x t a
  | x `notElem` F.syms t = t
  | otherwise              = panic (Just $ getLocation γ) msg
  where
    msg = unlines [ "checkUnbound: " ++ show x ++ " is elem of syms of " ++ show t
                  , "In", GM.showPpr e, "Arg = " , show a ]


dropExists :: CGEnv -> SpecType -> CG (CGEnv, SpecType)
dropExists γ (REx x tx t) =         (, t) <$> γ += ("dropExists", x, tx)
dropExists γ t            = return (γ, t)

dropConstraints :: CGEnv -> SpecType -> CG SpecType
dropConstraints cgenv (RFun x i tx@(RApp c _ _ _) t r) | isErasable c
  = flip (RFun x i tx) r <$> dropConstraints cgenv t
  where
    isErasable = if typeclass (getConfig cgenv) then isEmbeddedDict else isClass
dropConstraints cgenv (RRTy cts _ OCons rt)
  = do γ' <- foldM (\γ (x, t) -> γ `addSEnv` ("splitS", x,t)) cgenv xts
       addC (SubC  γ' t1 t2)  "dropConstraints"
       dropConstraints cgenv rt
  where
    (xts, t1, t2) = envToSub cts

dropConstraints _ t = return t

-------------------------------------------------------------------------------------
cconsCase :: CGEnv -> Var -> SpecType -> [AltCon] -> CoreAlt -> CG CGEnv
-------------------------------------------------------------------------------------
cconsCase γ x t acs (Alt ac ys ce)
  = do cγ <- caseEnv γ x acs ac ys mempty
       let cγ' = addFreeBinders (map F.symbol ys) cγ
       cconsE cγ' ce t
       return cγ'

{-

case x :: List b of
  Emp -> e

  Emp :: tdc          forall a. {v: List a | cons v === 0}
  x   :: xt           List b
  ys  == binders      []

-}
-------------------------------------------------------------------------------------
caseEnv   :: CGEnv -> Var -> [AltCon] -> AltCon -> [Var] -> Maybe [Int] -> CG CGEnv
-------------------------------------------------------------------------------------
caseEnv γ x _   (DataAlt c) ys pIs = do

  let (x' : ys')   = F.symbol <$> (x:ys)
  xt0             <- checkTyCon ("checkTycon cconsCase", x) γ <$> γ ??= x
  let rt           = shiftVV xt0 x'
  tdc             <- γ ??= dataConWorkId c >>= refreshVV
  let (rtd,yts',_) = unfoldR tdc rt ys
  yts             <- projectTypes (typeclass (getConfig γ))  pIs yts'
  let ys''         = F.symbol <$> filter (not . if allowTC then GM.isEmbeddedDictVar else GM.isEvVar) ys
  let r1           = dataConReft   c   ys''
  let r2           = dataConMsReft rtd ys''
  let xt           = (xt0 `F.meet` rtd) `strengthen` uTop (r1 `F.meet` r2)
  let cbs          = safeZip "cconsCase" (x':ys')
                         (map (`F.subst1` (selfSymbol, F.EVar x'))
                         (xt0 : yts))
  cγ'             <- addBinders γ x' cbs
  addBinders cγ' x' [(x', substSelf <$> xt)]
  where allowTC    = typeclass (getConfig γ)

caseEnv γ x acs a _ _ = do
  let x'  = F.symbol x
  xt'    <- (`strengthen` uTop (altReft γ acs a)) <$> (γ ??= x)
  addBinders γ x' [(x', xt')]


------------------------------------------------------
-- SELF special substitutions
------------------------------------------------------

substSelf :: UReft F.Reft -> UReft F.Reft
substSelf (MkUReft r p) = MkUReft (substSelfReft r) p

substSelfReft :: F.Reft -> F.Reft
substSelfReft (F.Reft (v, e)) = F.Reft (v, F.subst1 e (selfSymbol, F.EVar v))

ignoreSelf :: F.Reft -> F.Reft
ignoreSelf = F.mapExpr (\r -> if selfSymbol `elem` F.syms r then F.PTrue else r)

--------------------------------------------------------------------------------
-- | `projectTypes` masks (i.e. true's out) all types EXCEPT those
--   at given indices; it is used to simplify the environment used
--   when projecting out fields of single-ctor datatypes.
--------------------------------------------------------------------------------
projectTypes :: Bool -> Maybe [Int] -> [SpecType] -> CG [SpecType]
projectTypes _ Nothing   ts = return ts
projectTypes allowTC (Just ints) ts = mapM (projT ints) (zip [0..] ts)
  where
    projT is (j, t)
      | j `elem` is       = return t
      | otherwise         = true allowTC t

altReft :: CGEnv -> [AltCon] -> AltCon -> F.Reft
altReft _ _ (LitAlt l)   = literalFReft l
altReft γ acs DEFAULT    = mconcat ([notLiteralReft l | LitAlt l <- acs] ++ [notDataConReft d | DataAlt d <- acs])
  where
    notLiteralReft   = maybe mempty F.notExprReft . snd . literalConst (emb γ)
    notDataConReft d | exactDC (getConfig γ)
                     = F.Reft (F.vv_, F.PNot (F.EApp (F.EVar $ makeDataConChecker d) (F.EVar F.vv_)))
                     | otherwise = mempty
altReft _ _ _        = panic Nothing "Constraint : altReft"

unfoldR :: SpecType -> SpecType -> [Var] -> (SpecType, [SpecType], SpecType)
unfoldR td (RApp _ ts rs _) ys = (t3, tvys ++ yts, ignoreOblig rt)
  where
        tbody              = instantiatePvs (instantiateTys td ts) (reverse rs)
        ((ys0,_,yts',_), rt) = safeBkArrow (F.notracepp msg $ instantiateTys tbody tvs')
        msg                = "INST-TY: " ++ F.showpp (td, ts, tbody, ys, tvs')
        yts''              = zipWith F.subst sus (yts'++[rt])
        (t3,yts)           = (last yts'', init yts'')
        sus                = F.mkSubst <$> L.inits [(x, F.EVar y) | (x, y) <- zip ys0 ys']
        (αs, ys')          = mapSnd (F.symbol <$>) $ L.partition isTyVar ys
        tvs' :: [SpecType]
        tvs'               = rVar <$> αs
        tvys               = ofType . varType <$> αs

unfoldR _  _                _  = panic Nothing "Constraint.hs : unfoldR"

instantiateTys :: SpecType -> [SpecType] -> SpecType
instantiateTys = L.foldl' go
  where
    go (RAllT α tbody _) t = subsTyVarMeet' (ty_var_value α, t) tbody
    go _ _                 = panic Nothing "Constraint.instantiateTy"

instantiatePvs :: SpecType -> [SpecProp] -> SpecType
instantiatePvs           = L.foldl' go
  where
    go (RAllP p tbody) r = replacePreds "instantiatePv" tbody [(p, r)]
    go t               _ = errorP "" ("Constraint.instantiatePvs: t = " ++ showpp t)

checkTyCon :: (Outputable a) => (String, a) -> CGEnv -> SpecType -> SpecType
checkTyCon _ _ t@RApp{} = t
checkTyCon x g t        = checkErr x g t

checkFun :: (Outputable a) => (String, a) -> CGEnv -> SpecType -> SpecType
checkFun _ _ t@RFun{} = t
checkFun x g t        = checkErr x g t

checkAll :: (Outputable a) => (String, a) -> CGEnv -> SpecType -> SpecType
checkAll _ _ t@RAllT{} = t
checkAll x g t         = checkErr x g t

checkErr :: (Outputable a) => (String, a) -> CGEnv -> SpecType -> SpecType
checkErr (msg, e) γ t         = panic (Just sp) $ msg ++ GM.showPpr e ++ ", type: " ++ showpp t
  where
    sp                        = getLocation γ

varAnn :: CGEnv -> Var -> t -> Annot t
varAnn γ x t
  | x `S.member` recs γ      = AnnLoc (getSrcSpan x)
  | otherwise                = AnnUse t

-----------------------------------------------------------------------
-- | Helpers: Creating Fresh Refinement -------------------------------
-----------------------------------------------------------------------
freshPredRef :: CGEnv -> CoreExpr -> PVar RSort -> CG SpecProp
freshPredRef γ e (PV _ (PVProp rsort) _ as)
  = do t    <- freshTyType (typeclass (getConfig γ))  PredInstE e (toType False rsort)
       args <- mapM (const fresh) as
       let targs = [(x, s) | (x, (s, y, z)) <- zip args as, F.EVar y == z ]
       γ' <- foldM (+=) γ [("freshPredRef", x, ofRSort τ) | (x, τ) <- targs]
       addW $ WfC γ' t
       return $ RProp targs t

freshPredRef _ _ (PV _ PVHProp _ _)
  = todo Nothing "EFFECTS:freshPredRef"


--------------------------------------------------------------------------------
-- | Helpers: Creating Refinement Types For Various Things ---------------------
--------------------------------------------------------------------------------
argType :: Type -> Maybe F.Expr
argType (LitTy (NumTyLit i))
  = mkI i
argType (LitTy (StrTyLit s))
  = mkS $ bytesFS s
argType (TyVarTy x)
  = Just $ F.EVar $ F.symbol $ varName x
argType t
  | F.symbol (GM.showPpr t) == anyTypeSymbol
  = Just $ F.EVar anyTypeSymbol
argType _
  = Nothing


argExpr :: CGEnv -> CoreExpr -> Maybe F.Expr
argExpr _ (Var v)     = Just $ F.eVar v
argExpr γ (Lit c)     = snd  $ literalConst (emb γ) c
argExpr γ (Tick _ e)  = argExpr γ e
argExpr γ (App e (Type _)) = argExpr γ e
argExpr _ _           = Nothing


lamExpr :: CGEnv -> CoreExpr -> CG (Maybe F.Expr)
lamExpr g e = do
    adts <- gets cgADTs
    allowTC <- gets cgiTypeclass
    let dm = dataConMap adts
    case runToLogic (emb g) mempty dm (\x -> todo Nothing ("coreToLogic not working lamExpr: " ++ x)) (coreToLogic allowTC e) of
               Left  _  -> return Nothing
               Right ce -> return (Just ce)

--------------------------------------------------------------------------------
(??=) :: (?callStack :: CallStack) => CGEnv -> Var -> CG SpecType
--------------------------------------------------------------------------------
γ ??= x = case M.lookup x' (lcb γ) of
            Just e  -> consE (γ -= x') e
            Nothing -> refreshTy tx
          where
            x' = F.symbol x
            tx = fromMaybe tt (γ ?= x')
            tt = ofType $ varType x


--------------------------------------------------------------------------------
varRefType :: (?callStack :: CallStack) => CGEnv -> Var -> CG SpecType
--------------------------------------------------------------------------------
varRefType γ x =
  varRefType' γ x <$> (γ ??= x) -- F.tracepp (printf "varRefType x = [%s]" (showpp x))

varRefType' :: CGEnv -> Var -> SpecType -> SpecType
varRefType' γ x t'
  | Just tys <- trec γ, Just tr  <- M.lookup x' tys
  = strengthen' tr xr
  | otherwise
  = strengthen' t' xr
  where
    xr = singletonReft x
    x' = F.symbol x
    strengthen'
      | higherOrderFlag γ
      = strengthenMeet
      | otherwise
      = strengthenTop

-- | create singleton types for function application
makeSingleton :: CGEnv -> CoreExpr -> SpecType -> SpecType
makeSingleton γ cexpr t
  | higherOrderFlag γ, App f x <- simplify cexpr
  = case (funExpr γ f, argForAllExpr x) of
      (Just f', Just x')
                 | not (if typeclass (getConfig γ) then GM.isEmbeddedDictExpr x else GM.isPredExpr x) -- (isClassPred $ exprType x)
                 -> strengthenMeet t (uTop $ F.exprReft (F.EApp f' x'))
      (Just f', Just _)
                 -> strengthenMeet t (uTop $ F.exprReft f')
      _ -> t
  | rankNTypes (getConfig γ)
  = case argExpr γ (simplify cexpr) of
       Just e' -> strengthenMeet t $ uTop (F.exprReft e')
       _       -> t
  | otherwise
  = t
  where
    argForAllExpr (Var x)
      | rankNTypes (getConfig γ)
      , Just e <- M.lookup x (forallcb γ)
      = Just e
    argForAllExpr e
      = argExpr γ e



funExpr :: CGEnv -> CoreExpr -> Maybe F.Expr

funExpr _ (Var v)
  = Just $ F.EVar (F.symbol v)

funExpr γ (App e1 e2)
  = case (funExpr γ e1, argExpr γ e2) of
      (Just e1', Just e2') | not (if typeclass (getConfig γ) then GM.isEmbeddedDictExpr e2 else GM.isPredExpr e2) -- (isClassPred $ exprType e2)
                           -> Just (F.EApp e1' e2')
      (Just e1', Just _)
                           -> Just e1'
      _                    -> Nothing

funExpr _ _
  = Nothing

simplify :: CoreExpr -> CoreExpr
simplify (Tick _ e)       = simplify e
simplify (App e (Type _)) = simplify e
simplify (App e1 e2)      = App (simplify e1) (simplify e2)
simplify (Lam x e) | isTyVar x = simplify e
simplify e                = e


singletonReft :: (F.Symbolic a) => a -> UReft F.Reft
singletonReft = uTop . F.symbolReft . F.symbol

-- | RJ: `nomeet` replaces `strengthenS` for `strengthen` in the definition
--   of `varRefType`. Why does `tests/neg/strata.hs` fail EVEN if I just replace
--   the `otherwise` case? The fq file holds no answers, both are sat.
strengthenTop :: (PPrint r, F.Reftable r) => RType c tv r -> r -> RType c tv r
strengthenTop (RApp c ts rs r) r'  = RApp c ts rs $ F.meet r r'
strengthenTop (RVar a r) r'        = RVar a       $ F.meet r r'
strengthenTop (RFun b i t1 t2 r) r'= RFun b i t1 t2 $ F.meet r r'
strengthenTop (RAppTy t1 t2 r) r'  = RAppTy t1 t2 $ F.meet r r'
strengthenTop (RAllT a t r)    r'  = RAllT a t    $ F.meet r r'
strengthenTop t _                  = t

-- TODO: this is almost identical to RT.strengthen! merge them!
strengthenMeet :: (PPrint r, F.Reftable r) => RType c tv r -> r -> RType c tv r
strengthenMeet (RApp c ts rs r) r'  = RApp c ts rs (r `F.meet` r')
strengthenMeet (RVar a r) r'        = RVar a       (r `F.meet` r')
strengthenMeet (RFun b i t1 t2 r) r'= RFun b i t1 t2 (r `F.meet` r')
strengthenMeet (RAppTy t1 t2 r) r'  = RAppTy t1 t2 (r `F.meet` r')
strengthenMeet (RAllT a t r) r'     = RAllT a (strengthenMeet t r') (r `F.meet` r')
strengthenMeet t _                  = t

-- topMeet :: (PPrint r, F.Reftable r) => r -> r -> r
-- topMeet r r' = r `F.meet` r'

--------------------------------------------------------------------------------
-- | Cleaner Signatures For Rec-bindings ---------------------------------------
--------------------------------------------------------------------------------
exprLoc                         :: CoreExpr -> Maybe SrcSpan
exprLoc (Tick tt _)             = Just $ GM.tickSrcSpan tt
exprLoc (App e a) | isType a    = exprLoc e
exprLoc _                       = Nothing

isType :: Expr CoreBndr -> Bool
isType (Type _)                 = True
isType a                        = eqType (exprType a) predType

-- | @isGenericVar@ determines whether the @RTyVar@ has no class constraints
isGenericVar :: RTyVar -> SpecType -> Bool
isGenericVar α st =  all (\(c, α') -> (α'/=α) || isGenericClass c ) (classConstrs st)
  where
    classConstrs t = [(c, ty_var_value α')
                        | (c, ts) <- tyClasses t
                        , t'      <- ts
                        , α'      <- freeTyVars t']
    isGenericClass c = className c `elem` [ordClassName, eqClassName] -- , functorClassName, monadClassName]

-- instance MonadFail CG where
--  fail msg = panic Nothing msg

instance MonadFail Data.Functor.Identity.Identity where
  fail msg = panic Nothing msg

--------------------------------------------------------------------------------
-- | Quotient utility functions          ---------------------------------------
--------------------------------------------------------------------------------
data QuotientUnifier
  = QDidSubsume F.Symbol F.QPattern [CoreBndr]  -- Substitution to apply to quotient
  | PDidSubsume (M.HashMap F.Symbol F.QPattern) -- Substitution to apply to case expression
  | LiteralUnified                              -- Literal unification; no substitution              
  | DidNotUnify                                 -- Failed to unify
  deriving Show

data ExprUnifier
  = UnifiedWith (M.HashMap F.Symbol F.QPattern) (M.HashMap F.Symbol F.Expr)
  | LiteralDidUnify
  | NoUnification
  deriving Show

data PatternUnifier
  = PatternUnifier (M.HashMap F.Symbol F.QPattern) (M.HashMap F.Symbol F.QPattern)
  | LiteralUnifier
  | DistinctPatterns
  deriving Show

substQPattern :: F.Symbol -> F.QPattern -> F.Expr -> F.Expr
substQPattern s q e = F.subst1 e (s, toExpr q)

mergeUnifiers :: S.HashSet F.Symbol -> ExprUnifier -> ExprUnifier -> ExprUnifier
mergeUnifiers _ NoUnification _   = NoUnification
mergeUnifiers _ _ NoUnification   = NoUnification
mergeUnifiers _ LiteralDidUnify e = e
mergeUnifiers _ e LiteralDidUnify = e
mergeUnifiers fvs (UnifiedWith l r) (UnifiedWith l' r')
  = maybe NoUnification (uncurry UnifiedWith) $ do
      nl <- mergePSubst fvs l l'
      nr <- mergeESubst fvs r r'
      return (nl, nr)

applyQSubst :: M.HashMap F.Symbol F.QPattern -> F.QPattern -> F.QPattern
applyQSubst s (F.QPVar v) = case M.lookup v s of
  Nothing -> F.QPVar v
  Just p  -> p
applyQSubst _ p@(F.QPLit _) = p
applyQSubst s (F.QPCons c ps) = F.QPCons c $ map (applyQSubst s) ps

unifiedPat :: S.HashSet F.Symbol -> F.QPattern -> F.QPattern -> Maybe F.QPattern
unifiedPat fvs p p' = case unifyPatterns fvs p p' of
  PatternUnifier u _  -> Just $ applyQSubst u p
  LiteralUnifier      -> Just p
  DistinctPatterns    -> Nothing

mergeESubst
  :: S.HashSet F.Symbol
  -> M.HashMap F.Symbol F.Expr
  -> M.HashMap F.Symbol F.Expr
  -> Maybe (M.HashMap F.Symbol F.Expr)
mergeESubst fvs s s' = if didUnify then Just uu else Nothing
  where
    (didUnify, uu) = M.foldlWithKey'
      (\(b, un) k e -> case M.lookup k un of
          Nothing -> (b, M.insert k e un)
          Just e' -> case unify (S.toList fvs) e e' of
            Nothing -> (False, un)
            Just np -> (b, M.insert k (F.subst np e) un)
      ) (True, s) s'

mergePSubst
  :: S.HashSet F.Symbol
  -> M.HashMap F.Symbol F.QPattern
  -> M.HashMap F.Symbol F.QPattern
  -> Maybe (M.HashMap F.Symbol F.QPattern)
mergePSubst fvs s s' = if didUnify then Just uu else Nothing
  where
    (didUnify, uu) = M.foldlWithKey'
      (\(b, un) k p -> case M.lookup k un of
          Nothing -> (b, M.insert k p un)
          Just p' -> case unifiedPat fvs p p' of
            Nothing -> (False, un)
            Just np -> (b, M.insert k np un)
      ) (True, s) s'

mergePatternUnifier :: S.HashSet F.Symbol -> PatternUnifier -> PatternUnifier -> PatternUnifier
mergePatternUnifier _ DistinctPatterns _ = DistinctPatterns
mergePatternUnifier _ _ DistinctPatterns = DistinctPatterns
mergePatternUnifier _ e LiteralUnifier   = e
mergePatternUnifier _ LiteralUnifier e   = e
mergePatternUnifier fvs (PatternUnifier l r) (PatternUnifier l' r')
  = maybe DistinctPatterns (uncurry PatternUnifier) $ do
      nl <- mergePSubst fvs l l'
      nr <- mergePSubst fvs r r'
      return (nl, nr)

unifyPatterns :: S.HashSet F.Symbol -> F.QPattern -> F.QPattern -> PatternUnifier
unifyPatterns fvs (F.QPVar v) (F.QPVar v')
  | v == v'         = LiteralUnifier
  | S.member v fvs  = PatternUnifier (M.singleton v $ F.QPVar v') mempty
  | S.member v' fvs = PatternUnifier mempty (M.singleton v' $ F.QPVar v)
  | otherwise       = DistinctPatterns
unifyPatterns fvs (F.QPVar v) p
  | S.member v fvs = PatternUnifier (M.singleton v p) mempty
  | otherwise      = DistinctPatterns
unifyPatterns fvs p (F.QPVar v)
  | S.member v fvs = PatternUnifier mempty $ M.singleton v p
  | otherwise      = DistinctPatterns
unifyPatterns _ (F.QPLit (F.I m)) (F.QPLit (F.I n))
  | m == n    = LiteralUnifier
  | otherwise = DistinctPatterns
unifyPatterns _ (F.QPLit (F.R x)) (F.QPLit (F.R y))
  | x == y    = LiteralUnifier
  | otherwise = DistinctPatterns
unifyPatterns _ (F.QPLit (F.L c s)) (F.QPLit (F.L c' s'))
  | c == c' && s == s' = LiteralUnifier
  | otherwise          = DistinctPatterns
unifyPatterns fvs (F.QPCons c ps) (F.QPCons c' ps')
  | c == c' && length ps == length ps' =
      let us = zipWith (unifyPatterns fvs) ps ps'
       in foldr (mergePatternUnifier fvs) LiteralUnifier us
  | otherwise                          = DistinctPatterns
unifyPatterns _ _ _ = DistinctPatterns

unifyExprWithPattern :: S.HashSet F.Symbol -> F.QPattern -> F.Expr -> ExprUnifier
unifyExprWithPattern fvs (F.QPVar v) (F.EVar v')
  | v == v'            = LiteralDidUnify
  | S.member v fvs     = UnifiedWith mempty (M.singleton v $ F.EVar v')
  | S.member v' fvs    = UnifiedWith (M.singleton v $ F.QPVar v) mempty
  | otherwise          = NoUnification
unifyExprWithPattern fvs (F.QPVar v) e
  | S.member v fvs     = UnifiedWith mempty (M.singleton v e)
  | otherwise          = NoUnification
unifyExprWithPattern fvs e (F.EVar v)
  | S.member v fvs     = UnifiedWith (M.singleton v e) mempty
  | otherwise          = NoUnification
unifyExprWithPattern _ (F.QPLit (F.I m)) (F.ECon (F.I n))
  | m == n             = LiteralDidUnify
  | otherwise          = NoUnification
unifyExprWithPattern _ (F.QPLit (F.R x)) (F.ECon (F.R y))
  | x == y             = LiteralDidUnify
  | otherwise          = NoUnification
unifyExprWithPattern _ (F.QPLit (F.L c s)) (F.ECon (F.L c' s'))
  | c == c' && s == s' = LiteralDidUnify
  | otherwise          = NoUnification
unifyExprWithPattern fvs (F.QPCons c ps) (F.EApp f a)
  = case getAppArgs f a of
      (F.EVar c', as)
        | c == c' && length as == length ps ->
            let us = zipWith (unifyExprWithPattern fvs) ps as
             in foldr (mergeUnifiers fvs) LiteralDidUnify us
        | otherwise -> NoUnification
      _ -> NoUnification
unifyExprWithPattern _ _ _ = NoUnification

unifyWithQuotient :: AltCon -> [CoreBndr] -> RQuotient -> QuotientUnifier
unifyWithQuotient con bndrs quotient = unifyP con (rqtLeft quotient)
  where
    unifyP :: AltCon -> F.QPattern -> QuotientUnifier
    unifyP ac (F.QPVar v)
      | M.member v qFreeVars
          = case altConPat ac bndrs of
              Just e  -> QDidSubsume v e bndrs
              Nothing -> DidNotUnify
      | otherwise = DidNotUnify
    unifyP (LitAlt (LitNumber _ m)) (F.QPLit (F.I n))
      | m == n    = LiteralUnified
      | otherwise = DidNotUnify
    unifyP (LitAlt (LitDouble x)) (F.QPLit (F.R y))
      | fromRational x == y = LiteralUnified
      | otherwise           = DidNotUnify
    unifyP (LitAlt (LitFloat x)) (F.QPLit (F.R y))
      | fromRational x == y = LiteralUnified
      | otherwise           = DidNotUnify
    unifyP (LitAlt (LitChar c)) (F.QPLit (F.L c' s))
      | isChar s && c == Text.head c' = LiteralUnified
      | otherwise                     = DidNotUnify
    unifyP (LitAlt (LitString str)) (F.QPLit (F.L str' s))
      | isString s && Text.decodeUtf8 str == str' = LiteralUnified
      | otherwise                                 = DidNotUnify
    unifyP (LitAlt _) _ = DidNotUnify
    unifyP (DataAlt c) (F.QPCons c' ps)
      | dcSymbol c == c' = PDidSubsume (M.fromList $ zip (map sym' bndrs) ps)
      | otherwise        = DidNotUnify
    unifyP _ _ = DidNotUnify

    altConPat :: AltCon -> [CoreBndr] -> Maybe F.QPattern
    altConPat ac bs = case ac of
      LitAlt (LitNumber _ n) -> Just $ F.QPLit (F.I n) 
      LitAlt (LitDouble x)   -> Just $ F.QPLit (F.R $ fromRational x)
      LitAlt (LitFloat x)    -> Just $ F.QPLit (F.R $ fromRational x)
      LitAlt (LitChar c)     -> Just $ F.QPLit (F.L (Text.singleton c) charSort)
      LitAlt (LitString str) -> Just $ F.QPLit (F.L (Text.decodeUtf8 str) strSort)
      LitAlt _               -> Nothing
      DataAlt c              -> Just $ F.QPCons (dcSymbol c) (map var' bs)
      DEFAULT                -> Nothing -- Should not occur

    dcSymbol :: Ghc.DataCon -> F.Symbol
    dcSymbol = F.symbol . Ghc.dataConWorkId

    sym' :: CoreBndr -> F.Symbol
    sym' = F.symbol -- . Ghc.getName

    var' :: CoreBndr -> F.QPattern
    var' = F.QPVar . sym'

    qFreeVars :: M.HashMap F.Symbol SpecType
    qFreeVars = rqtVars quotient

checkRespectability
  :: CGEnv
  -> [F.Symbol]         -- | Case binders
  -> Maybe QuotientSpec -- | Codomain (maybe a quotient type)
  -> (F.Expr -> CG (Maybe F.Expr))
  -> QuotientUnifier
  -> RQuotient
  -> Expr CoreBndr
  -> CG ()
checkRespectability γ bs τ f u q e = coreExpr >>= \case
  Nothing    -> return ()
  Just coreE -> case u of
    QDidSubsume v p _ -> do
      let right = substQPattern v p $ rqtRight q
          prec  = getQuotientReft q
      addEquationC (substQPattern v p <$> prec) domain coreE right
      where
        domain :: [(F.Symbol, SpecType)]
        domain
          =   M.toList (M.delete v $ rqtVars q)
          ++ mapMaybe (\x -> (x,) <$> lookupREnv x (renv γ)) bs
    PDidSubsume m    -> do
      let left = F.subst (F.Su $ toExpr <$> m) coreE
      addEquationC (getQuotientReft q) domain left $ rqtRight q
      where
        domain :: [(F.Symbol, SpecType)]
        domain = M.toList $ rqtVars q
    LiteralUnified -> addEquationC (getQuotientReft q) domain coreE (rqtRight q)
      where
        domain :: [(F.Symbol, SpecType)]
        domain = M.toList $ rqtVars q
    DidNotUnify    -> return ()
  where
    addEquationC :: Maybe F.Expr -> [(F.Symbol, SpecType)] -> F.Expr -> F.Expr -> CG ()
    addEquationC prec domain left right = do
      mcexpr <- f right
      -- _ <- error $ show τ
      case mcexpr of
        Just cexpr -> do
          γ' <- foldlM addEEnv γ domain -- (map (\(s, t) -> (s, elimQuotTyCons t)) domain)
    
          {-
          let expr
                = addPrecondition $ case allRewrites γ' left cexpr of
                    [] -> F.PAtom F.Eq left cexpr
                    rs -> F.POr (F.PAtom F.Eq left cexpr : rs)-}

          let rws
                = case τ of
                    Nothing   -> []
                    Just spec ->
                      let (rs, fvs) = qRewrites spec
                          fvSet     = S.union (S.fromList (fvs ++ map fst domain)) (binders γ)
                          getRW rwr = (rwResult rwr , rwCond rwr)
                       in [ addPrecondition (andM rlpc rrpc) <$> simplifyEq rl rr
                          | (rl, rlpc) <- (left, Nothing)  : map getRW (S.toList $ getRewrites fvSet rs left)
                          , (rr, rrpc) <- (cexpr, Nothing) : map getRW (S.toList $ getRewrites fvSet rs cexpr)
                          ]

          case sequence rws of
            Nothing -> return ()
            Just [ex] -> mkConstraint γ' (addPrecondition prec ex) ""
            Just es   -> mkConstraint γ' (addPrecondition prec $ F.POr es) ""
        Nothing -> return ()
    
    allQuotients :: QuotientSpec -> [RQuotient]
    allQuotients spec = mapMaybe (`M.lookup` cgQuotients γ) (qsQuots spec)

    qRewrites :: QuotientSpec -> ([Rewrite], [F.Symbol])
    qRewrites spec
      = let addRw (rws, ss) rq
              = ( Rewrite (rqtLeft rq) (rqtRight rq) (getQuotientReft rq) : rws
                , ss ++ M.keys (rqtVars rq)
                )
         in F.foldl' addRw ([], []) $ allQuotients spec

    addPrecondition :: Maybe F.Expr -> F.Expr -> F.Expr
    addPrecondition prec post
      = case prec of
          Nothing -> post
          Just pc -> F.PImp pc post

    mkConstraint :: CGEnv -> F.Expr -> String -> CG ()
    mkConstraint γ' p = addC (SubR γ' (OQuot (rqtName q)) $ uReft (F.vv_, p))

    coreExpr :: CG (Maybe F.Expr)
    coreExpr = runToLogic' γ e "checkRespectability"

getQuotientReft :: RQuotient -> Maybe F.Expr
getQuotientReft q
  = case mapMaybe (filterTrivial . (F.reftPred . ur_reft <$>) . getReft) (M.elems $ rqtVars q) of
      [] -> Nothing
      es -> Just $ F.PAnd es
    where
      filterTrivial :: Maybe F.Expr -> Maybe F.Expr
      filterTrivial (Just F.PTrue) = Nothing 
      filterTrivial e              = e

      getReft :: SpecType -> Maybe RReft
      getReft (RVar _ r)       = Just r
      getReft (RFun _ _ _ _ r) = Just r
      getReft (RAllT _ _ r)    = Just r
      getReft (RAllP {})       = Nothing
      getReft (RApp _ _ _ r)   = Just r
      getReft (RAllE {})       = Nothing
      getReft (REx {})         = Nothing
      getReft (RExprArg _)     = Nothing
      getReft (RAppTy _ _ r)   = Just r
      getReft (RRTy _ r _ _)   = Just r
      getReft (RHole r)        = Just r

runToLogic' :: CGEnv -> CoreExpr -> String -> CG (Maybe F.Expr)
runToLogic' γ e msg = do
  adts    <- gets cgADTs
  allowTC <- gets cgiTypeclass
  let dm = dataConMap adts
  return $ case runToLogic (emb γ) mempty dm (\x -> todo Nothing ("coreToLogic not working " ++ msg ++ ": " ++ x)) (coreToLogic allowTC e) of
    Left  _  -> Nothing
    Right ce -> Just ce

-- | Simplified rewriting (achieved via unification with QPatterns)
-- | Possible improvement would be to use full rewriting of LH; requires some work (and caution) to achieve this
data Rewrite = Rewrite
  { rwPattern      :: F.QPattern
  , rwExpr         :: F.Expr
  , rwPrecondition :: Maybe F.Expr
  } deriving Show

data RewriteResult = RWResult
  { rwCond   :: Maybe F.Expr                  -- | The rewriting precondition
  , rwResult :: F.Expr                        -- | The resulting expression
  , rwSubst  :: M.HashMap F.Symbol F.QPattern -- | The substitution applied
  } deriving Show

instance Eq RewriteResult where
  (RWResult c r _) == (RWResult c' r' _) = c == c' && r == r'

instance Hashable RewriteResult where
  hashWithSalt n (RWResult c r _) = hashWithSalt (hashWithSalt n c) r

mapResultExpr :: (F.Expr -> F.Expr) -> RewriteResult -> RewriteResult
mapResultExpr f rw = rw { rwResult = f (rwResult rw) }

getRewrites
  :: S.HashSet F.Symbol
  -> [Rewrite]
  -> F.Expr
  -> S.HashSet RewriteResult
getRewrites fvs rws e
  = let inRws    = getInnerRewrites fvs rws e
        outRws   = tryRewrite fvs rws e
     in S.unions
          [ S.fromList inRws
          , S.fromList outRws
          , S.fromList (concatMap appOuter inRws)
          , S.fromList (concatMap appInner outRws)
          ]
    where
      merge
        :: M.HashMap F.Symbol F.QPattern
        -> Maybe F.Expr
        -> RewriteResult
        -> Maybe RewriteResult
      merge s p r@(RWResult q ex _)
        = RWResult (andM p q) ex <$> mergePSubst fvs s (rwSubst r)

      appOuter :: RewriteResult -> [RewriteResult]
      appOuter (RWResult p ex sub)
        = mapMaybe (merge sub p) $ tryRewrite fvs rws ex

      appInner :: RewriteResult -> [RewriteResult]
      appInner (RWResult p ex sub)
        = mapMaybe (merge sub p) $ getInnerRewrites fvs rws ex

andM :: Maybe F.Expr -> Maybe F.Expr -> Maybe F.Expr
andM (Just p) Nothing                      = Just p
andM Nothing (Just p)                      = Just p
andM (Just (F.PAnd ps)) (Just (F.PAnd qs)) = Just $ F.PAnd (ps ++ qs)
andM (Just (F.PAnd ps)) (Just p)           = Just $ F.PAnd (p : ps)
andM (Just p) (Just (F.PAnd ps))           = Just $ F.PAnd (p : ps)
andM (Just p) (Just q)                     = Just $ F.PAnd [p, q]
andM Nothing Nothing                       = Nothing

andMerge :: F.Expr -> F.Expr -> F.Expr
andMerge (F.PAnd ps) (F.PAnd qs) = F.PAnd (ps ++ qs)
andMerge (F.PAnd ps) p           = F.PAnd (p : ps)
andMerge p           (F.PAnd ps) = F.PAnd (p : ps)
andMerge p           q           = F.PAnd [p, q]

andMerges :: [F.Expr] -> F.Expr
andMerges [p] = p
andMerges ps  = L.foldl' andMerge (F.PAnd []) ps

orMerge :: F.Expr -> F.Expr -> F.Expr
orMerge (F.POr ps) (F.POr qs) = F.POr (ps ++ qs)
orMerge (F.POr ps) p          = F.POr (p : ps)
orMerge p          (F.POr ps) = F.POr (p : ps)
orMerge p          q          = F.POr [p, q]

orMerges :: [F.Expr] -> F.Expr
orMerges [p] = p
orMerges ps  = L.foldl' andMerge (F.POr []) ps

-- | Only handles cases for expressions of a quotient type where we can deduce that
-- | its subexpressions inhabit the same quotient type. Can probably do something with
-- | ECst here.
getInnerRewrites
  :: S.HashSet F.Symbol
  -> [Rewrite]
  -> F.Expr
  -> [RewriteResult]
getInnerRewrites fvs rws (F.ENeg e)
  = (\(RWResult p e' s) -> RWResult p (F.ENeg e') s) <$> (S.toList $ getRewrites fvs rws e)
getInnerRewrites fvs rws (F.EBin o l r)
  = rewriteBinWith (F.EBin o) fvs rws l r
getInnerRewrites fvs rws (F.EIte p i e) = rewriteBinWith (F.EIte p) fvs rws i e
getInnerRewrites _ _ _ = mempty

rewriteBinWith
  :: (F.Expr -> F.Expr -> F.Expr)
  -> S.HashSet F.Symbol
  -> [Rewrite]
  -> F.Expr
  -> F.Expr
  -> [RewriteResult]
rewriteBinWith f fvs rws l r
  = catMaybes
      [ RWResult (andM pl pr) (f l' r') <$> mergePSubst fvs sl sr
      | RWResult pl l' sl <- rewritesL
      , RWResult pr r' sr <- rewritesR
      ] ++ map (mapResultExpr (`f` r)) rewritesL ++ map (mapResultExpr (f l)) rewritesR
    where
      rewritesL = S.toList $ getRewrites fvs rws l
      rewritesR = S.toList $ getRewrites fvs rws r

tryRewrite
  :: S.HashSet F.Symbol
  -> [Rewrite]
  -> F.Expr
  -> [RewriteResult]
tryRewrite fvs rws ex = mapMaybe (doTry ex) rws
  where
    doTry :: F.Expr -> Rewrite -> Maybe RewriteResult
    doTry e rw
      = case unifyExprWithPattern fvs (rwPattern rw) e of
          NoUnification    -> Nothing 
          LiteralDidUnify  -> Just (RWResult (rwPrecondition rw) (rwExpr rw) mempty)
          UnifiedWith s s' -> Just (RWResult (F.subst (F.Su s') $ rwPrecondition rw) (F.subst (F.Su s') $ rwExpr rw) s)

-- | Essentially NBE for expressions (doesn't evaluate *everything*)
--   Assumes that expressions are well-typed.

data NBEEnv = NBE
  { nbeDefs     :: !(M.HashMap F.Symbol F.Expr)
  -- ^ Definitions that can be unfolded (caution: possible infinite recursion)
  , nbeSelectors :: M.HashMap F.Symbol (F.Symbol, Int)
  -- ^ Selectors such that a selector symbol maps to its data constructor and projection index
  , nbeDataCons :: S.HashSet F.Symbol
  -- ^ Reflected data constructors
  , nbeGuards   :: ![F.Expr]
  -- ^ List of axioms in the current context (should be normalised)
  }

type NBE a = ST.StateT NBEEnv CG a

initNBEEnv :: CGEnv -> CG NBEEnv
initNBEEnv _ = do
  dcons <- gets dataConTys
  let rws = concatMap makeSimplify dcons
  return NBE
    { nbeDefs      = mempty
    , nbeSelectors = M.fromList $ mapMaybe makeSel rws
    , nbeDataCons  = S.fromList (F.smDC <$> rws)
    , nbeGuards    = [F.PTrue]
    }
  where
    makeSel rw
      | F.EVar x <- F.smBody rw
      = (F.smName rw,) . (F.smDC rw,) <$> L.elemIndex x (F.smArgs rw)
      | otherwise
      = Nothing

normaliseWithBind :: CGEnv -> F.Symbol -> F.Sort -> F.Expr -> F.Expr -> CG F.Expr
normaliseWithBind γ sym ty e arg = do
  nbeEnv <- initNBEEnv γ
  runNBE nbeEnv $ normaliseLam sym ty e arg

runNBE :: NBEEnv -> NBE a -> CG a
runNBE = flip ST.evalStateT

getDefinition :: F.Symbol -> NBE (Maybe F.Expr)
getDefinition sym = ST.gets (M.lookup sym . nbeDefs)

isDataCons :: F.Symbol -> NBE Bool
isDataCons sym = ST.gets (S.member sym . nbeDataCons)

getSelector :: F.Symbol -> NBE (Maybe (F.Symbol, Int))
getSelector sym = ST.gets (M.lookup sym . nbeSelectors)

withGuard :: F.Expr -> NBE a -> NBE a
withGuard e = ST.withStateT (\s -> s { nbeGuards = e : nbeGuards s })

guardTruth :: F.Expr -> NBE (Maybe Bool)
guardTruth F.PTrue  = return $ Just True
guardTruth F.PFalse = return $ Just False
guardTruth e = ST.gets $ \s -> go (nbeGuards s) e
  where
    go :: [F.Expr] -> F.Expr -> Maybe Bool
    go guards (F.PAnd es)
      = F.foldl' (\mb e' -> (&&) <$> mb <*> go guards e') (Just True) $ flattenAnd es
    go guards ex@(F.POr es)
      | F.any (== ex) guards = Just True
      | otherwise
          = F.foldl'
              (\mb e' ->
                if fromMaybe False mb then
                  Just True
                else
                  go guards e'
              ) (Just False) (flattenOr es)
    go guards ex@(F.EIte p et ef)
      | F.any (== ex) guards                    = Just True
      | fromMaybe False (go guards p)           = go guards et
      | fromMaybe False (go guards (F.PNot p))  = go guards ef
      | otherwise                               = Just False
    go guards ex
      | F.any (== ex)        guards = Just True
      | F.any (== F.PNot e)  guards = Just False
      | otherwise                   = Nothing

{-
simplifyIf :: F.Expr -> F.Expr -> F.Expr -> F.Expr
simplifyIf p i@(F.EIte q ti te) e
  | te == e   = simplifyIf (andMerge p q) ti e
  | otherwise = case e of
      F.EIte r fi fe
        | fi == i -> simplifyIf (orMerge p r) i fe
      _ -> F.EIte p i e
simplifyIf p i e@(F.EIte q fi fe)
  | fi == i   = simplifyIf (orMerge p q) i fe
  | otherwise = F.EIte p i e
simplifyIf p i e = F.EIte p i e-}

simplifyIf' :: F.Expr -> F.Expr -> F.Expr -> (F.Expr, F.Expr, F.Expr)
simplifyIf' p i@(F.EIte q ti te) e
  | te == e   = simplifyIf' (andMerge p q) ti e
  | otherwise = case e of
      F.EIte r fi fe
        | fi == i -> simplifyIf' (orMerge p r) i fe
      _ -> (p, i, e)
simplifyIf' p i e@(F.EIte q fi fe)
  | fi == i   = simplifyIf' (orMerge p q) i fe
  | otherwise = (p, i, e)
simplifyIf' p i e = (p, i, e)

{-

-- | Simplification to be done after rewriting normalised terms
-- |   > Handles nested if expressions made by case expressions
simplifyE :: F.Expr -> F.Expr
simplifyE (F.EApp f a)      = F.EApp (simplifyE f) (simplifyE a)
simplifyE (F.ENeg e)        = F.ENeg (simplifyE e)
simplifyE (F.EBin o x y)    = F.EBin o (simplifyE x) (simplifyE y)
simplifyE (F.EIte p i e)    = simplifyIf p i e
simplifyE (F.ELam x e)      = F.ELam x (simplifyE e)
simplifyE (F.ECst e t)      = F.ECst (simplifyE e) t
simplifyE (F.ETApp e t)     = F.ETApp (simplifyE e) t
simplifyE (F.ETAbs e s)     = F.ETAbs (simplifyE e) s
simplifyE (F.PAnd ps)       = F.PAnd (map simplifyE ps)
simplifyE (F.POr ps)        = F.POr  (map simplifyE ps)
simplifyE (F.PNot p)        = F.PNot (simplifyE p)
simplifyE (F.PImp p q)      = F.PImp (simplifyE p) (simplifyE q)
simplifyE (F.PIff x y)      = F.PIff (simplifyE x) (simplifyE y)
simplifyE (F.PAtom r x y)   = F.PAtom r (simplifyE x) (simplifyE y)
simplifyE (F.PAll s e)      = F.PAll s (simplifyE e)
simplifyE (F.PExist s e)    = F.PExist s (simplifyE e)
simplifyE (F.PGrad k s g e) = F.PGrad k s g (simplifyE e)
simplifyE (F.ECoerc s t e)  = F.ECoerc s t (simplifyE e)
simplifyE e                 = e-}

-- | An improved version of the Eq instance (does no interpretation, so is semi-definitional)
-- | Essentially performs basic structural transformations to find equalities
{-isEquivalent :: F.Expr -> F.Expr -> Bool
isEquivalent = go mempty
  where
    go :: S.HashSet (F.Symbol, F.Symbol) -> F.Expr -> F.Expr -> Bool
    go _  (F.ESym x)     (F.ESym y)      = x == y
    go ss (F.EVar x)     (F.EVar y)      = x == y || S.member (x, y) ss
    go ss (F.EApp f a)   (F.EApp g b)    = go ss f g && go ss a b
    go ss (F.ENeg x)     (F.ENeg y)      = go ss x y
    go ss (F.EBin o w x) (F.EBin o' y z) = o == o' && go ss w y && go ss x z
    go ss (F.EIte p i e) (F.EIte q x y)  = go ss p q && go ss i x && go ss e y
    go ss (F.ECst e t)   (F.ECst e' u)   = t == u && go ss e e'
    go ss (F.ELam (s, t) e) (F.ELam (s', t') e')
      = t == t' && go (S.insert (s, s') ss) e e'
    go ss (F.ETApp e t)  (F.ETApp e' u)  = t == u && go ss e e'
    go ss (F.ETAbs e s)  (F.ETAbs e' s') = go (S.insert (s, s') ss) e e'
    go ss (F.PAnd ps)    (F.PAnd qs)     = null (L.deleteFirstsBy (go ss) ps qs)
    go ss (F.POr ps)     (F.POr qs)      = null (L.deleteFirstsBy (go ss) ps qs)
    go ss (F.PAnd [p])   (F.POr [q])     = go ss p q
    go ss (F.PNot p)     (F.PNot q)      = go ss p q
    go ss (F.PImp p q)   (F.PImp p' q')  = go ss p p' && go ss q q'
    go ss (F.PIff p q)   (F.PIff p' q')  = go ss p p' && go ss q q'
    go ss (F.PAtom r x y) (F.PAtom r' x' y')
      = r == r' && go ss x x' && go ss y y'
    go _  (F.PKVar k s)  (F.PKVar k' s') = k == k' && s == s'
    go ss (F.PAll sts e) (F.PAll sts' e')
      =  length sts == length sts'
      && let isEq (b', ss') ((sy, t), (sy', t')) = (b' && t == t', S.insert (sy, sy') ss')
             (b, s') = L.foldl' isEq (True, ss) $ zip sts sts'
          in b && go s' e e'
    go ss (F.PExist sts e) (F.PExist sts' e')
      =  length sts == length sts'
      && let isEq (b', ss') ((sy, t), (sy', t')) = (b' && t == t', S.insert (sy, sy') ss')
             (b, s') = L.foldl' isEq (True, ss) $ zip sts sts'
          in b && go s' e e'
    go ss (F.PGrad k s g e) (F.PGrad k' s' g' e')
      = k == k' && s == s' && g == g' && go ss e e'
    go ss (F.ECoerc t u e) (F.ECoerc t' u' e')
      = t == t' && u == u' && go ss e e'
    go _ _ _ = False-}

-- | Simplifies an equality
-- | Nothing represents triviality (equality always holds)
simplifyEq :: F.Expr -> F.Expr -> Maybe F.Expr
simplifyEq = go mempty
  where
    go :: S.HashSet (F.Symbol, F.Symbol) -> F.Expr -> F.Expr -> Maybe F.Expr
    go _ l@(F.ESym s) r@(F.ESym s')
      | s == s'   = Nothing
      | otherwise = Just $ F.PAtom F.Eq l r
    go ss l@(F.EVar x) r@(F.EVar y)
      | x == y             = Nothing
      | S.member (x, y) ss = Nothing
      | otherwise          = Just $ F.PAtom F.Eq l r
    go ss l@(F.EApp f a) r@(F.EApp g b)
      = case (go ss f g, go ss a b) of
          (Nothing, Nothing) -> Nothing
          _                  -> Just $ F.PAtom F.Eq l r
    go ss (F.ENeg x) (F.ENeg y) = go ss x y
    go ss l@(F.EBin o x y) r@(F.EBin o' x' y')
      | o == o'   = case (go ss x x', go ss y y') of
          (Nothing, Nothing) -> Nothing
          _                  -> Just $ F.PAtom F.Eq l r
      | otherwise = Just $ F.PAtom F.Eq l r
    go ss l@(F.EIte p il el) r@(F.EIte q ir er)
      = let (p', il', el') = simplifyIf' p il el
            (q', ir', er') = simplifyIf' q ir er
        in case (go ss p' q', go ss il' ir', go ss el' er') of
              (Nothing, Nothing, Nothing) -> Nothing
              (Just pr, Nothing, Nothing) -> Just pr
              (_, _, _)                   -> Just $ F.PAtom F.Eq l r
    go ss l@(F.ECst e t) r@(F.ECst e' u)
      | t == u    = go ss e e'
      | otherwise = Just $ F.PAtom F.Eq l r
    go ss l@(F.ELam (s, t) e) r@(F.ELam (s', t') e')
      | t == t'   = go (S.insert (s, s') ss) e e'
      | otherwise = Just $ F.PAtom F.Eq l r
    go ss l@(F.ETApp e t) r@(F.ETApp e' u)
      | t == u    = go ss e e'
      | otherwise = Just $ F.PAtom F.Eq l r
    go ss (F.ETAbs e s) (F.ETAbs e' s') = go (S.insert (s, s') ss) e e'
    go ss (F.PAnd ps) (F.PAnd qs)
      = let isDup x y = isNothing $ go ss x y
            ps'       = L.nubBy isDup ps
            qs'       = L.nubBy isDup qs
            ps''      = L.deleteFirstsBy (\x y -> isNothing $ go ss x y) ps' qs'
            qs''      = L.deleteFirstsBy (\x y -> isNothing $ go ss x y) qs' ps'
         in case (ps'', qs'') of
              ([], []) -> Nothing
              _        -> Just $ F.PAtom F.Eq (andMerges ps'') (andMerges qs'')
    go ss (F.POr ps) (F.POr qs)
      = let isDup x y = isNothing $ go ss x y
            ps'       = L.nubBy isDup ps
            qs'       = L.nubBy isDup qs
            ps''      = L.deleteFirstsBy (\x y -> isNothing $ go ss x y) ps' qs'
            qs''      = L.deleteFirstsBy (\x y -> isNothing $ go ss x y) qs' ps'
         in case (ps', qs') of
              ([], []) -> Nothing
              _        -> Just $ F.PAtom F.Eq (orMerges ps'') (orMerges qs'')
    go ss l@(F.PImp p q) r@(F.PImp p' q')
      = case (go ss p p', go ss q q') of
          (Nothing, Nothing) -> Nothing
          (Nothing, Just u)  -> Just $ F.PImp p u
          _                  -> Just $ F.PAtom F.Eq l r
    go ss l@(F.PIff p q) r@(F.PIff p' q')
      = case (go ss p p', go ss q q') of
          (Nothing, Nothing) -> Nothing
          _                  -> Just $ F.PAtom F.Eq l r
    go _ l@(F.PKVar k s) r@(F.PKVar k' s')
      | k == k' && s == s' = Nothing
      | otherwise          = Just $ F.PAtom F.Eq l r
    go ss l@(F.PAll st e) r@(F.PAll st' e')
      | st == st' = go ss e e'
      | otherwise = Just $ F.PAtom F.Eq l r
    go ss l@(F.PExist st e) r@(F.PExist st' e')
      | st == st' = go ss e e'
      | otherwise = Just $ F.PAtom F.Eq l r
    go ss l@(F.PGrad k s g e) r@(F.PGrad k' s' g' e')
      | k == k' && s == s' && g == g' = go ss e e'
      | otherwise                     = Just $ F.PAtom F.Eq l r
    go ss l@(F.ECoerc t u e) r@(F.ECoerc t' u' e')
      | t == t' && u == u' = go ss e e'
      | otherwise          = Just $ F.PAtom F.Eq l r
    go _ l r = Just $ F.PAtom F.Eq l r

-- P <=> Q
--   ==
-- P <=> R

-- P => Q == R

-- | Central NBE function operating on a binding, open term and argument that
-- | taken together represent the application of a lambda function (useful for quotients).
normaliseLam
  :: F.Symbol -- | Name of variable occurring freely in open term
  -> F.Sort   -- | Type of variable occurring freely in open term
  -> F.Expr   -- | Open term containing the above free variable
  -> F.Expr   -- | Argument to be substituted for free variable
  -> NBE F.Expr
normaliseLam sym ty (F.ECst e t) arg = flip F.ECst t <$> normaliseLam sym ty e arg
normaliseLam _   _  (F.ESym s)   _   = return $ F.ESym s
normaliseLam _   _  (F.ECon c)   _ = return $ F.ECon c
normaliseLam sym _  (F.EVar v)   arg
  | v == sym  = return arg
  | otherwise = getDefinition v >>= \case
      Just e  -> return e
      Nothing -> return $ F.EVar v
normaliseLam sym ty (F.EApp e a) arg = do
  e' <- normaliseLam sym ty e arg
  a' <- normaliseLam sym ty a arg
  case getAppArgs e' a' of
    (f@(F.EVar v), as)
      | F.isTestSymbol v -> case as of
          [r] -> normaliseTest v r
          _   -> return $ F.foldl' F.EApp f as
      | otherwise        -> getSelector v >>= \case
          Just sel -> case as of
            [r] -> return $ normaliseSelector v sel r
            _   -> return $ F.foldl' F.EApp f as
          Nothing  -> return $ F.foldl' F.EApp f as
    (f, as)        -> normaliseApp f as
normaliseLam sym ty (F.ENeg e) arg = do
  e' <- normaliseLam sym ty e arg
  return $ applyNeg e'
normaliseLam sym ty (F.EBin op e1 e2) arg = do
  e1' <- normaliseLam sym ty e1 arg
  e2' <- normaliseLam sym ty e2 arg
  return $ F.applyConstantFolding op e1' e2'
normaliseLam sym ty (F.EIte p ie ee) arg = do
  p'  <- normaliseLam sym ty p arg

  guardTruth p' >>= \case
    Just True  -> normaliseLam sym ty ie arg
    Just False -> normaliseLam sym ty ee arg
    Nothing    ->
          F.EIte p'
      <$> withGuard p' (normaliseLam sym ty ie arg)
      <*> withGuard (applyNot p') (normaliseLam sym ty ee arg)
normaliseLam sym ty (F.ELam (sym', ty') e) arg
  | sym == sym' = F.ELam (sym', ty') <$> normaliseLam sym' ty' e (F.EVar sym')
  | otherwise   = do
      f <- normaliseLam sym' ty' e (F.EVar sym')
      F.ELam (sym', ty') <$> normaliseLam sym ty f arg
normaliseLam sym ty (F.ETApp e t) arg = flip F.ETApp t <$> normaliseLam sym ty e arg
normaliseLam sym ty (F.ETAbs e s) arg = flip F.ETAbs s <$> normaliseLam sym ty e arg
normaliseLam sym ty (F.PAnd es)   arg = do
  (b, es') <-
    F.foldlM ( \(b, fs) e -> do
      e' <- normaliseLam sym ty e arg
      guardTruth e' >>= \case
        Just True  -> return (b     , fs)
        Just False -> return (False , fs)
        Nothing    -> return (b     , e' : fs)
    ) (True, []) es

  case (b, es') of
    (True  , []) -> return F.PTrue
    (False , _ ) -> return F.PFalse
    (_     , fs) -> return $ F.PAnd fs
normaliseLam sym ty (F.POr es) arg = do
  (b, es') <-
    F.foldlM ( \(b, fs) e -> do
      e' <- normaliseLam sym ty e arg
      guardTruth e' >>= \case
        Just True  -> return (True, fs)
        Just False -> return (b, fs)
        Nothing    -> return (b, e' : fs)
    ) (False, []) es

  case (b, es') of
    (True  , _ ) -> return F.PTrue
    (False , []) -> return F.PFalse
    (_     , fs) -> return $ F.POr fs
normaliseLam sym ty (F.PNot e) arg = do
  e' <- normaliseLam sym ty e arg

  guardTruth e' >>= \case
    Just True  -> return F.PFalse
    Just False -> return F.PTrue
    Nothing    -> return $ F.PNot e'
normaliseLam sym ty (F.PImp e1 e2) arg = do
  e1' <- normaliseLam sym ty e1 arg
  e2' <- normaliseLam sym ty e2 arg

  guardTruth e1' >>= \case
    Just False -> return F.PTrue
    Just True  -> guardTruth e2' >>= \case
      Just True  -> return F.PTrue
      Just False -> return F.PFalse
      Nothing    -> return e2'
    Nothing    -> guardTruth e2' >>= \case
      Just True  -> return F.PTrue
      Just False -> return $ F.PNot e1'
      Nothing    -> return $ F.PImp e1' e2'
normaliseLam sym ty (F.PIff e1 e2) arg = do
  e1' <- normaliseLam sym ty e1 arg
  e2' <- normaliseLam sym ty e2 arg
  b1  <- guardTruth e1'
  b2  <- guardTruth e2'

  case (b1, b2) of
    (Just x, Just y)
      | x == y    -> return F.PTrue
      | otherwise -> return F.PFalse
    (Just True , Nothing) -> return e2'
    (Just False, Nothing) -> return $ F.PNot e2'
    (Nothing,  Just True) -> return e1'
    (Nothing, Just False) -> return $ F.PNot e1'
    (Nothing  ,  Nothing) -> return $ F.PIff e1' e2'
normaliseLam sym ty (F.PAtom r e1 e2) arg = do
  e1' <- normaliseLam sym ty e1 arg
  e2' <- normaliseLam sym ty e2 arg
  return $ F.applyBooleanFolding r e1' e2'
normaliseLam _ _ e@(F.PKVar _ _) _ = return e
normaliseLam sym ty (F.PAll [] e) arg = normaliseLam sym ty e arg
normaliseLam _ _ e@(F.PAll _ _) _ = return e
normaliseLam sym ty (F.PExist [] e) arg = normaliseLam sym ty e arg
normaliseLam _ _ e@(F.PExist _ _) _ = return e
normaliseLam _ _ e@(F.PGrad {}) _ = return e
normaliseLam sym ty (F.ECoerc t u e) arg
  | t == u    = normaliseLam sym ty e arg
  | otherwise = F.ECoerc t u <$> normaliseLam sym ty e arg

normaliseTest :: F.Symbol -> F.Expr -> NBE F.Expr
normaliseTest tst (F.EVar v)
  | F.testSymbol v == tst = return F.PTrue
  | otherwise             = do
      isDC <- isDataCons v
      return $ if isDC then F.PFalse else F.EApp (F.EVar tst) (F.EVar v)
normaliseTest tst e@(F.EApp e1 e2) = do
  case fst (getAppArgs e1 e2) of
    F.EVar v
      | F.testSymbol v == tst -> return F.PTrue
      | otherwise             -> do
          isDC <- isDataCons v
          return $ if isDC then F.PFalse else F.EApp (F.EVar tst) e
    _ -> return $ F.EApp (F.EVar tst) e
normaliseTest tst e = return $ F.EApp (F.EVar tst) e

normaliseSelector :: F.Symbol -> (F.Symbol, Int) -> F.Expr -> F.Expr
normaliseSelector sel (dc, n) a@(F.EApp e1 e2)
  = case getAppArgs e1 e2 of
      (F.EVar v , as)
        | v == dc -> as !! n
      _ -> F.EApp (F.EVar sel) a
normaliseSelector sel _ a = F.EApp (F.EVar sel) a

-- Should only be called with normalised expressions; no input expressions should
-- be independently reducible.
normaliseApp :: F.Expr -> [F.Expr] -> NBE F.Expr
normaliseApp (F.EVar v)           as       = return $ F.foldl' F.EApp (F.EVar v) as
normaliseApp (F.ELam (sym, ty) e) [a]      = normaliseLam sym ty e a
normaliseApp (F.ELam (sym, ty) e) (a : as) = do
  f <- normaliseLam sym ty e a
  normaliseApp f as
normaliseApp (F.ECst e t)         as       = flip F.ECst t <$> normaliseApp e as
normaliseApp (F.ETAbs e sym)      as       = flip F.ETAbs sym <$> normaliseApp e as
normaliseApp (F.ETApp e ty)       as       = flip F.ETApp ty <$> normaliseApp e as
normaliseApp (F.EIte p e1 e2)     as       =
      F.EIte p
  <$> withGuard p (normaliseApp e1 as)
  <*> withGuard (F.PNot p) (normaliseApp e2 as) 
normaliseApp f                    []       = return f
normaliseApp f                    as       = return $ F.foldl' F.EApp f as

applyNot :: F.Expr -> F.Expr
applyNot F.PTrue  = F.PFalse
applyNot F.PFalse = F.PTrue
applyNot e        = F.PNot e

applyNeg :: F.Expr -> F.Expr
applyNeg (F.ECon (F.I m)) = F.ECon (F.I (- m))
applyNeg (F.ECon (F.R x)) = F.ECon (F.R (- x))
applyNeg e = F.ENeg e

getAppArgs :: F.Expr -> F.Expr -> (F.Expr, [F.Expr])
getAppArgs f a = go [a] f
  where
    go acc (F.EApp g e) = go (e:acc) g
    go acc e            = (e, acc)      

flattenOr :: [F.Expr] -> [F.Expr]
flattenOr = flattenWith $ F.foldl' flatten (False, [])
  where
    flatten :: (Bool, [F.Expr]) -> F.Expr -> (Bool, [F.Expr])
    flatten (_, es') (F.POr es) = (True, es' ++ es)
    flatten (b, es)  e          = (b, e : es)

flattenAnd :: [F.Expr] -> [F.Expr]
flattenAnd = flattenWith $ F.foldl' flatten (False, [])
  where
    flatten :: (Bool, [F.Expr]) -> F.Expr -> (Bool, [F.Expr])
    flatten (_, es') (F.PAnd es) = (True, es' ++ es)
    flatten (b, es)  e           = (b, e : es)

flattenWith :: ([F.Expr] -> (Bool, [F.Expr])) -> [F.Expr] -> [F.Expr]
flattenWith flattenAll es = case flattenAll es of
  (False , es') -> es'
  (True  , es') -> flattenWith flattenAll es'
