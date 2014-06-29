{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

{-|
    Translating from internal syntax to abstract syntax. Enables nice
    pretty printing of internal syntax.

    TODO

        - numbers on metas
        - fake dependent functions to independent functions
        - meta parameters
        - shadowing
-}
module Agda.Syntax.Translation.InternalToAbstract
  ( Reify(..)
  , NamedClause
  , reifyPatterns
  ) where

import Prelude hiding (mapM_, mapM)
import Control.Applicative
import Control.Arrow
import Control.Monad.State hiding (mapM_, mapM)
import Control.Monad.Error hiding (mapM_, mapM)
import Control.Monad.Reader hiding (mapM_, mapM)

import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Map as Map
import Data.List hiding (sort)
import Data.Traversable as Trav
import Data.Maybe
import Data.Monoid
import Data.Foldable (foldMap)

import Agda.Syntax.Literal
import Agda.Syntax.Position
import Agda.Syntax.Common hiding (Arg, Dom, NamedArg, ArgInfo)
import qualified Agda.Syntax.Common as Common
import Agda.Syntax.Info as Info
import Agda.Syntax.Abstract as A
import Agda.Syntax.Internal as I
import qualified Agda.Utils.VarSet as VSet

import Agda.TypeChecking.Monad as M hiding (MetaInfo)
import Agda.TypeChecking.Reduce
import {-# SOURCE #-} Agda.TypeChecking.Records
import Agda.TypeChecking.CompiledClause (CompiledClauses(Fail))
import Agda.TypeChecking.DisplayForm
import Agda.TypeChecking.Level
import {-# SOURCE #-} Agda.TypeChecking.Datatypes
import Agda.TypeChecking.Free
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.DropArgs

import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Permutation
import Agda.Utils.Size
import Agda.Utils.Tuple

#include "../../undefined.h"
import Agda.Utils.Impossible

-- Composition of reified applications ------------------------------------

napps :: Expr -> [I.NamedArg Expr] -> TCM Expr
napps e args = do
  dontShowImp <- not <$> showImplicitArguments
  let apply1 e arg | notVisible arg && dontShowImp = e
                   | otherwise = App exprInfo e arg
  foldl' apply1 e <$> reify args

apps :: Expr -> [I.Arg Expr] -> TCM Expr
apps e args = napps e $ map (fmap unnamed) args

reifyApp :: Expr -> [I.Arg Term] -> TCM Expr
reifyApp e vs = apps e =<< reifyIArgs vs

reifyIArg :: Reify i a => I.Arg i -> TCM (I.Arg a)
reifyIArg i = Common.Arg (argInfo i) <$> reify (unArg i)

reifyIArgs :: Reify i a => [I.Arg i] -> TCM [I.Arg a]
reifyIArgs = mapM reifyIArg

reifyIArg' :: I.Arg e -> TCM (A.Arg e)
reifyIArg' e = flip Common.Arg (unArg e) <$> reify (argInfo e)

reifyIArgs' :: [I.Arg e] -> TCM [A.Arg e]
reifyIArgs' = mapM reifyIArg'

-- Omitting information ---------------------------------------------------

exprInfo :: ExprInfo
exprInfo = ExprRange noRange

underscore :: Expr
underscore = A.Underscore $ Info.emptyMetaInfo

-- Conditional reification to omit terms that are not shown --------------

reifyWhenE :: Reify i Expr => Bool -> i -> TCM Expr
reifyWhenE True  i = reify i
reifyWhenE False t = return underscore

-- Reification ------------------------------------------------------------

class Reify i a | i -> a where
    reify     ::         i -> TCM a

    --   @reifyWhen False@ should produce an 'underscore'.
    --   This function serves to reify hidden/irrelevant things.
    reifyWhen :: Bool -> i -> TCM a
    reifyWhen _ = reify

instance Reify Name Name where
    reify = return

instance Reify Expr Expr where
    reifyWhen = reifyWhenE
    reify = return

instance Reify MetaId Expr where
    reifyWhen = reifyWhenE
    reify x@(MetaId n) = liftTCM $ do
      mi  <- mvInfo <$> lookupMeta x
      let mi' = Info.MetaInfo
                 { metaRange          = getRange $ miClosRange mi
                 , metaScope          = M.clScope $ miClosRange mi
                 , metaNumber         = Just n
                 , metaNameSuggestion = miNameSuggestion mi
                 }
          underscore = return $ A.Underscore mi'
      ifNotM shouldReifyInteractionPoints underscore $ {- else -}
        caseMaybeM (isInteractionMeta x) underscore $ \ ii@InteractionId{} ->
          return $ A.QuestionMark (mi' {metaNumber = Just n}) ii

instance Reify DisplayTerm Expr where
  reifyWhen = reifyWhenE
  reify d = case d of
    DTerm v -> reifyTerm False v
    DDot  v -> reify v
    DCon c vs -> apps (A.Con (AmbQ [c])) =<< reifyIArgs vs
    DDef f vs -> apps (A.Def f) =<< reifyIArgs vs
    DWithApp u us vs -> do
      (e, es) <- reify (u, us)
      reifyApp (if null es then e else A.WithApp exprInfo e es) vs

-- | @reifyDisplayForm f vs fallback@
--   tries to rewrite @f vs@ with a display form for @f@.
--   If successful, reifies the resulting display term,
--   otherwise, does @fallback@.
reifyDisplayForm :: QName -> I.Args -> TCM A.Expr -> TCM A.Expr
reifyDisplayForm f vs fallback = do
  ifNotM displayFormsEnabled fallback $ {- else -} do
  caseMaybeM (liftTCM $ displayForm f vs) fallback reify

-- | @reifyDisplayFormP@ tries to recursively
--   rewrite a lhs with a display form.
--
--   Note: we are not necessarily in the empty context upon entry!
reifyDisplayFormP :: A.SpineLHS -> TCM A.SpineLHS
reifyDisplayFormP lhs@(A.SpineLHS i f ps wps) =
  ifNotM displayFormsEnabled (return lhs) $ {- else -} do
    let vs = [ setHiding h $ defaultArg $ I.var i
             | (i, h) <- zip [0..] $ map getHiding ps
             ]
    -- Try to rewrite @f 0 1 2 ... |ps|-1@ to a dt.
    -- Andreas, 2014-06-11  Issue 1177:
    -- I thought we need to add the placeholders for ps to the context,
    -- because otherwise displayForm will not raise the display term
    -- and we will have variable clashes.
    -- But apparently, it has no influence...
    -- Ulf, can you add an explanation?
    md <- liftTCM $ -- addContext (replicate (length ps) "x") $
      displayForm f vs
    reportSLn "reify.display" 20 $
      "display form of " ++ show f ++ " " ++ show ps ++ " " ++ show wps ++ ":\n  " ++ show md
    case md of
      Just d  | okDisplayForm d ->
        -- In the display term @d@, @var i@ should be a placeholder
        -- for the @i@th pattern of @ps@.
        -- Andreas, 2014-06-11:
        -- Are we sure that @d@ did not use @var i@ otherwise?
        reifyDisplayFormP =<< displayLHS (map namedArg ps) wps d
      _ -> return lhs
  where
    okDisplayForm (DWithApp d ds []) =
      okDisplayForm d && all okDisplayTerm ds
    okDisplayForm (DTerm (I.Def f vs)) = all okElim vs
    okDisplayForm (DDef f vs) = all okDArg vs
    okDisplayForm DDot{} = False
    okDisplayForm DCon{} = False
    okDisplayForm DTerm{} = True -- False?
    okDisplayForm DWithApp{} = True -- False?

    okDisplayTerm (DTerm v) = okTerm v
    okDisplayTerm DDot{} = True
    okDisplayTerm DCon{} = True
    okDisplayTerm DDef{} = False
    okDisplayTerm _ = False

    okDArg = okDisplayTerm . unArg
    okArg = okTerm . unArg

    okElim (I.Apply a) = okArg a
    okElim (I.Proj{})  = False

    okTerm (I.Var _ []) = True
    okTerm (I.Con c vs) = all okArg vs
    okTerm (I.Def x []) = show x == "_" -- Handling wildcards in display forms
    okTerm _            = True -- False

    -- Flatten a dt into (parentName, parentArgs, withArgs).
    flattenWith :: DisplayTerm -> (QName, [I.Arg DisplayTerm], [DisplayTerm])
    flattenWith (DWithApp d ds1 ds2) = case flattenWith d of
      (f, vs, ds0) -> (f, vs, ds0 ++ ds1 ++ map (DTerm . unArg) ds2)
    flattenWith (DDef f vs) = (f, vs, [])     -- .^ hacky, but we should only hit this when printing debug info
    flattenWith (DTerm (I.Def f es)) =
      let vs = maybe __IMPOSSIBLE__ id $ mapM isApplyElim es
      in (f, map (fmap DTerm) vs, [])
    flattenWith _ = __IMPOSSIBLE__

    displayLHS :: [A.Pattern] -> [A.Pattern] -> DisplayTerm -> TCM A.SpineLHS
    displayLHS ps wps d = case flattenWith d of
      (f, vs, ds) -> do
        ds <- mapM termToPat ds
        vs <- mapM argToPat vs
        vs <- reifyIArgs' vs
        return $ SpineLHS i f vs (ds ++ wps)
--        return $ LHS i (LHSHead f vs) (ds ++ wps)
      where
        ci   = ConPatInfo False patNoRange
        argToPat arg = fmap unnamed <$> traverse termToPat arg

        termToPat :: DisplayTerm -> TCM A.Pattern

        termToPat (DTerm (I.Var n [])) = return $ ps !! n

        termToPat (DCon c vs)          = A.ConP ci (AmbQ [c]) <$> do
          mapM argToPat =<< reifyIArgs' vs

        termToPat (DTerm (I.Con c vs)) = A.ConP ci (AmbQ [conName c]) <$> do
          mapM (argToPat . fmap DTerm) =<< reifyIArgs' vs

        termToPat (DTerm (I.Def _ [])) = return $ A.WildP patNoRange
        termToPat (DDef _ [])          = return $ A.WildP patNoRange

        termToPat (DDot v)             = A.DotP patNoRange <$> termToExpr v
        termToPat v                    = A.DotP patNoRange <$> reify v -- __IMPOSSIBLE__

        len = genericLength ps

        argsToExpr = mapM (traverse termToExpr)

        -- TODO: restructure this to avoid having to repeat the code for reify
        termToExpr :: Term -> TCM A.Expr
        termToExpr v = do
          reportSLn "reify.display" 60 $ "termToExpr " ++ show v
          -- After unSpine, a Proj elimination is __IMPOSSIBLE__!
          case unSpine v of
            I.Con c vs ->
              apps (A.Con (AmbQ [conName c])) =<< argsToExpr vs
            I.Def f es -> do
              let vs = maybe __IMPOSSIBLE__ id $ mapM isApplyElim es
              apps (A.Def f) =<< argsToExpr vs
            I.Var n es -> do
              let vs = maybe __IMPOSSIBLE__ id $ mapM isApplyElim es
              -- Andreas, 2014-06-11  Issue 1177
              -- due to β-normalization in substitution,
              -- even the pattern variables @n < len@ can be
              -- applied to some args @vs@.
              e <- if n < len
                   then return $ A.patternToExpr $ ps !! n
                   else reify (I.var (n - len))
              apps e =<< argsToExpr vs
            _ -> return underscore

instance Reify Literal Expr where
  reifyWhen = reifyWhenE
  reify l@(LitInt    {}) = return (A.Lit l)
  reify l@(LitFloat  {}) = return (A.Lit l)
  reify l@(LitString {}) = return (A.Lit l)
  reify l@(LitChar   {}) = return (A.Lit l)
  reify l@(LitQName  {}) = return (A.Lit l)

instance Reify Term Expr where
  reifyWhen = reifyWhenE
  reify v = reifyTerm True v

reifyTerm :: Bool -> Term -> TCM Expr
reifyTerm expandAnonDefs v = do
    v <- unSpine <$> instantiate v
    case v of
      I.Var n es   -> do
          let vs = fromMaybe __IMPOSSIBLE__ $ allApplyElims es
          x  <- liftTCM $ nameOfBV n `catchError` \_ -> freshName_ ("@" ++ show n)
          reifyApp (A.Var x) vs
      I.Def x es   -> do
        let vs = fromMaybe __IMPOSSIBLE__ $ allApplyElims es
        reifyDisplayForm x vs $ reifyDef expandAnonDefs x vs
      I.Con c vs   -> do
        let x = conName c
        isR <- isGeneratedRecordConstructor x
        case isR of
          True -> do
            showImp <- showImplicitArguments
            let keep (a, v) = showImp || notHidden a
            r  <- getConstructorData x
            xs <- getRecordFieldNames r
            vs <- map unArg <$> reifyIArgs vs
            return $ A.Rec exprInfo $ map (unArg *** id) $ filter keep $ zip xs vs
          False -> reifyDisplayForm x vs $ do
            ci <- getConstInfo x
            let Constructor{conPars = np} = theDef ci
            -- if we are the the module that defines constructor x
            -- then we have to drop at least the n module parameters
            n  <- getDefFreeVars x
            -- the number of parameters is greater (if the data decl has
            -- extra parameters) or equal (if not) to n
            when (n > np) __IMPOSSIBLE__
            let h = A.Con (AmbQ [x])
            if null vs then return h else do
            es <- reifyIArgs vs
            -- Andreas, 2012-04-20: do not reify parameter arguments of constructor
            -- if the first regular constructor argument is hidden
            -- we turn it into a named argument, in order to avoid confusion
            -- with the parameter arguments which can be supplied in abstract syntax
            --
            -- Andreas, 2012-09-17: this does not remove all sources of confusion,
            -- since parameters could have the same name as regular arguments
            -- (see for example the parameter {i} to Data.Star.Star, which is also
            -- the first argument to the cons).
            -- @data Star {i}{I : Set i} ... where cons : {i :  I} ...@
            if (np == 0) then apps h es else do
              -- Get name of first argument from type of constructor.
              -- Here, we need the reducing version of @telView@
              -- because target of constructor could be a definition
              -- expanding into a function type.  See test/succeed/NameFirstIfHidden.agda.
              TelV tel _ <- telView (defType ci)
              case genericDrop np $ telToList tel of
                -- Andreas, 2012-09-18
                -- If the first regular constructor argument is hidden,
                -- we keep the parameters to avoid confusion.
                (Common.Dom info _ : _) | isHidden info -> do
                  let us = genericReplicate (np - n) $
                             setRelevance Relevant $ Common.Arg info underscore
                  apps h $ us ++ es
                -- otherwise, we drop all parameters
                _ -> apps h es
{- CODE FROM 2012-04-xx
              let doms = genericDrop np $ telToList tel
              reportSLn "syntax.reify.con" 30 $ unlines
                [ "calling nameFirstIfHidden"
                , "doms = " ++ show doms
                , "es   = " ++ show es
                , "n    = " ++ show n
                , "np   = " ++ show np
                ]
              napps h $ genericDrop (n - np) $ nameFirstIfHidden doms es
-}
--      I.Lam info b | isAbsurdBody b -> return $ A.AbsurdLam exprInfo $ getHiding info
      I.Lam info b    -> do
        (x,e) <- reify b
        info <- reify info
        return $ A.Lam exprInfo (DomainFree info x) e
        -- Andreas, 2011-04-07 we do not need relevance information at internal Lambda
      I.Lit l        -> reify l
      I.Level l      -> reify l
      I.Pi a b       -> case b of
          NoAbs _ b'
            | notHidden a -> uncurry (A.Fun $ exprInfo) <$> reify (a, b')
              -- Andreas, 2013-11-11 Hidden/Instance I.Pi must be A.Pi
              -- since (a) the syntax {A} -> B or {{A}} -> B is not legal
              -- and (b) the name of the binder might matter.
              -- See issue 951 (a) and 952 (b).
            | otherwise   -> mkPi b =<< reify a
          b               -> mkPi b =<< do
            ifM (domainFree a (absBody b))
              {- then -} (Common.Arg <$> reify (domInfo a) <*> pure underscore)
              {- else -} (reify a)
        where
          mkPi b (Common.Arg info a) = do
            (x, b) <- reify b
            return $ A.Pi exprInfo [TypedBindings noRange $ Common.Arg info (TBind noRange [x] a)] b
          -- We can omit the domain type if it doesn't have any free variables
          -- and it's mentioned in the target type.
          domainFree a b = do
            df <- asks envPrintDomainFreePi
            return $ and [df, freeIn 0 b, VSet.null $ allVars $ freeVars a]

      I.Sort s     -> reify s
      I.MetaV x es -> do
        let vs = fromMaybe __IMPOSSIBLE__ $ allApplyElims es
        x' <- reify x
        apps x' =<< reifyIArgs vs
      I.DontCare v -> A.DontCare <$> reifyTerm expandAnonDefs v
      I.Shared p   -> reifyTerm expandAnonDefs $ derefPtr p

    where
      -- Andreas, 2012-10-20  expand a copy in an anonymous module
      -- to improve error messages.
      -- Don't do this if we have just expanded into a display form,
      -- otherwise we loop!
      reifyDef :: Bool -> QName -> I.Args -> TCM Expr
      reifyDef True x@(QName m name) vs | A.isAnonymousModuleName m = do
        r <- reduceDefCopy x vs
        case r of
          YesReduction _ v -> do
            reportSLn "reify.anon" 60 $ unlines
              [ "reduction on defined ident. in anonymous module"
              , "x = " ++ show x
              , "v = " ++ show v
              ]
            reify v
          NoReduction () -> do
            reportSLn "reify.anon" 60 $ unlines
              [ "no reduction on defined ident. in anonymous module"
              , "x  = " ++ show x
              , "vs = " ++ show vs
              ]
            reifyDef' x vs
      reifyDef _ x vs = reifyDef' x vs

      reifyDef' :: QName -> I.Args -> TCM Expr
      reifyDef' x@(QName _ name) vs = do
        -- We should drop this many arguments from the local context.
        n <- getDefFreeVars x
        mdefn <- liftTCM $ (Just <$> getConstInfo x) `catchError` \_ -> return Nothing
        -- check if we have an absurd lambda
        let reifyAbsurdLambda cont =
              case theDef <$> mdefn of
                Just Function{ funCompiled = Just Fail, funClauses = [cl] }
                  | isAbsurdLambdaName x -> do
                    -- get hiding info from last pattern, which should be ()
                    let h = getHiding $ last (clausePats cl)
                    apps (A.AbsurdLam exprInfo h) =<< reifyIArgs vs
                _ -> cont
        reifyAbsurdLambda $ do
        (pad, vs :: [I.NamedArg Term]) <- do
          case mdefn of
            Nothing   -> return ([], map (fmap unnamed) $ genericDrop n vs)
            Just defn -> do
              let def = theDef defn
              -- This is tricky:
              --  * getDefFreeVars x tells us how many arguments
              --    are part of the local context
              --  * some of those arguments might have been dropped
              --    due to projection likeness
              --  * when showImplicits is on we'd like to see the dropped
              --    projection arguments

              -- These are the dropped projection arguments
              (np, pad, dom) <-
                  case def of
                      Function{ funProjection = Just Projection{ projIndex = np } } -> do
                        TelV tel _ <- telView (defType defn)
                        scope <- getScope
                        let (as, dom:_) = splitAt (np - 1) $ telToList tel
                            whocares = A.Underscore $ Info.emptyMetaInfo { metaScope = scope }
                        return (np, map (argFromDom . (fmap $ const whocares)) as, dom)
                      _ -> return (0, [], __IMPOSSIBLE__)
              -- Now pad' ++ vs' = drop n (pad ++ vs)
              pad' <- reifyIArgs' $ genericDrop n pad
              let vs'  :: [I.Arg Term]
                  vs'  = genericDrop (max 0 (n - size pad)) vs
              -- Andreas, 2012-04-21: get rid of hidden underscores {_}
              -- Keep non-hidden arguments of the padding
              showImp <- showImplicitArguments
              return (filter visible pad',
                if not (null pad) && showImp && notVisible (last pad)
                   then nameFirstIfHidden [dom] vs'
                   else map (fmap unnamed) vs')
        df <- displayFormsEnabled
        let extLam = case mdefn of
                      Nothing -> Nothing
                      Just defn -> case theDef defn of
                                    Function{ funExtLam = Just (h, nh) } -> Just (h + nh)
                                    _                                    -> Nothing
        if df && isJust extLam
          then do
           reportSLn "reify.def" 10 $ "reifying extended lambda with definition: x = " ++ show x
           info <- getConstInfo x
           --drop lambda lifted arguments
           cls <- mapM (reify . (QNamed x) . (dropArgs $ fromJust extLam)) $ defClauses info
           -- Karim: Currently Abs2Conc does not require a DefInfo thus we
           -- use __IMPOSSIBLE__.
           napps (A.ExtendedLam exprInfo __IMPOSSIBLE__ x cls) =<< reifyIArgs vs
          else do
           let apps = foldl' (\e a -> A.App exprInfo e (fmap unnamed a))
           napps (A.Def x `apps` pad) =<< reifyIArgs vs

-- | @nameFirstIfHidden n (a1->...an->{x:a}->b) ({e} es) = {x = e} es@
nameFirstIfHidden :: [I.Dom (String, t)] -> [I.Arg a] -> [I.NamedArg a]
nameFirstIfHidden _         []                    = []
nameFirstIfHidden []        (_ : _)               = __IMPOSSIBLE__
nameFirstIfHidden (dom : _) (Common.Arg info e : es) | isHidden info =
  Common.Arg info (Named (Just $ unranged $ fst $ unDom dom) e) :
  map (fmap unnamed) es
nameFirstIfHidden _         es                    = map (fmap unnamed) es

instance Reify i a => Reify (Named n i) (Named n a) where
  reify = traverse reify
  reifyWhen b = traverse (reifyWhen b)

-- | Skip reification of implicit and irrelevant args if option is off.
instance (Reify i a) => Reify (I.Arg i) (A.Arg a) where
  reify (Common.Arg info i) = liftM2 Common.Arg (reify info)
                                                (flip reifyWhen i =<< condition)
    where condition = (return (argInfoHiding info /= Hidden) `or2M` showImplicitArguments)
              `and2M` (return (argInfoRelevance info /= Irrelevant) `or2M` showIrrelevantArguments)
  reifyWhen b i = do info <- reify $ argInfo i
                     traverse (reifyWhen b) $ i { argInfo = info }

instance Reify Elim Expr where
  reifyWhen = reifyWhenE
  reify e = case e of
    I.Apply v -> appl "apply" <$> reify v
    I.Proj f  -> appl "proj"  <$> reify ((defaultArg $ I.Def f []) :: I.Arg Term)
    where
      appl :: String -> A.Arg Expr -> Expr
      appl s v = A.App exprInfo (A.Lit (LitString noRange s)) $ fmap unnamed v

type NamedClause = QNamed I.Clause
-- data NamedClause = NamedClause QName I.Clause

instance Reify ClauseBody RHS where
  reify NoBody     = return AbsurdRHS
  reify (Body v)   = RHS <$> reify v
  reify (Bind b)   = reify $ absBody b  -- the variables should already be bound

-- Local data types to shuffleDots
data DotBind = BindFirstExplicit | BindFirstImplicit | AlreadyBound deriving (Show)
data DoBind  = YesBind | NoBind | DontTouch deriving (Eq, Show)

-- The Monoid instance for Data.Map doesn't require that the values are a
-- monoid.
newtype MonoidMap k v = MonoidMap { unMonoidMap :: Map.Map k v }

instance (Ord k, Monoid v) => Monoid (MonoidMap k v) where
  mempty = MonoidMap Map.empty
  mappend (MonoidMap m1) (MonoidMap m2) = MonoidMap (Map.unionWith mappend m1 m2)

-- | Move dots on variables so that each variable is bound at its first
--   non-hidden occurrence (if any). If all occurrences are hidden it's bound
--   at the first occurrence.
shuffleDots :: ([A.NamedArg A.Pattern], [A.Pattern]) -> TCM ([A.NamedArg A.Pattern], [A.Pattern])
shuffleDots (ps, wps) = do
  return $ (`evalState` xs)
         $ (`runReaderT` NotHidden)
         $ (,) <$> redotArgs ps <*> redotPats wps
  where
    -- An argument is explicit if _all_ Arg's on the way are explicit. In the
    -- map we store if _any_ of the variable occurrences were explicit.
    implicit = All False
    explicit = All True
                                        -- compute binding strategy
    xs = Map.map (\(_, h) -> if getAny h then BindFirstExplicit else BindFirstImplicit)
       $ Map.filter (getAny . fst)      -- remove vars that don't appear dotted
       $ unMonoidMap
       $ argsVars explicit ps `mappend` foldMap (patVars explicit) wps

    -- Compute a map from pattern vars to (AppearsDotted, AppearsInANonHiddenPosition)
    argsVars h  = foldMap (argVars h)
    argVars h a = (foldMap $ foldMap $ patVars (h `mappend` h')) a
      where h' = if getHiding a == NotHidden then explicit else implicit
    patVars h p = case p of
      A.VarP x             -> MonoidMap $ Map.singleton x (Any False, Any $ getAll h)
      A.DotP _ (A.Var x)   -> MonoidMap $ Map.singleton x (Any True,  Any $ getAll h)
      A.DotP{}             -> mempty
      A.ConP _ _ ps        -> argsVars h ps
      A.DefP _ _ ps        -> argsVars h ps
      A.PatternSynP _ _ ps -> argsVars h ps
      A.WildP{}            -> mempty
      A.AbsurdP{}          -> mempty
      A.LitP{}             -> mempty
      A.ImplicitP{}        -> mempty
      A.AsP{}              -> __IMPOSSIBLE__

    shouldBind x = do
      xs <- get
      h  <- ask
      let b = case Map.lookup x xs of
                Nothing -> DontTouch
                Just s  -> case s of
                  BindFirstExplicit | h == NotHidden -> YesBind
                                    | otherwise      -> NoBind
                  BindFirstImplicit -> YesBind  -- in this case we know h isn't NotHidden
                  AlreadyBound -> NoBind
      when (b == YesBind) $ put $ Map.adjust (const AlreadyBound) x xs
      return b

    redotArgs = traverse redotArg
    redotArg a = hide $ traverse (traverse redotPat) a
      where hide | getHiding a /= NotHidden = local (const Hidden)
                 | otherwise                = id
    redotPats = traverse redotPat
    redotPat p = case p of
      A.VarP x             -> redotVar p x
      A.DotP _ (A.Var x)   -> redotVar p x
      A.DotP{}             -> pure p
      A.ConP i c ps        -> A.ConP i c <$> redotArgs ps
      A.DefP i f ps        -> A.DefP i f <$> redotArgs ps
      A.PatternSynP i x ps -> A.PatternSynP i x <$> redotArgs ps
      A.WildP{}            -> pure p
      A.AbsurdP{}          -> pure p
      A.LitP{}             -> pure p
      A.ImplicitP{}        -> pure p
      A.AsP{}              -> __IMPOSSIBLE__

    redotVar p x = do
      b <- shouldBind x
      return $ case b of
        DontTouch -> p
        YesBind   -> A.VarP x
        NoBind    -> A.DotP (Info.PatRange $ getRange p) (A.Var x)

-- | Removes implicit arguments that are not needed, that is, that don't bind
--   any variables that are actually used and doesn't do pattern matching.
stripImplicits :: ([A.NamedArg A.Pattern], [A.Pattern]) ->
                  TCM ([A.NamedArg A.Pattern], [A.Pattern])
stripImplicits (ps, wps) = do          -- v if show-implicit we don't need the names
  ifM showImplicitArguments (return (map (unnamed . namedThing <$>) ps, wps)) $ do
  let vars = dotVars (ps, wps)
  reportSLn "reify.implicit" 30 $ unlines
    [ "stripping implicits"
    , "  ps   = " ++ show ps
    , "  wps  = " ++ show wps
    , "  vars = " ++ show vars
    ]
  let allps       = ps ++ map defaultNamedArg wps
      sps         = blankDots $ foldl (.) (strip Set.empty) (map rearrangeBinding $ Set.toList vars) $ allps
      (ps', wps') = splitAt (length sps - length wps) sps
  reportSLn "reify.implicit" 30 $ unlines
    [ "  ps'  = " ++ show ps'
    , "  wps' = " ++ show (map namedArg wps')
    ]
  return (ps', map namedArg wps')
  where
    argsVars = Set.unions . map argVars
    argVars = patVars . namedArg
    patVars p = case p of
      A.VarP x      -> Set.singleton x
      A.ConP _ _ ps -> argsVars ps
      A.DefP _ _ ps -> Set.empty
      A.DotP _ e    -> Set.empty
      A.WildP _     -> Set.empty
      A.AbsurdP _   -> Set.empty
      A.LitP _      -> Set.empty
      A.ImplicitP _ -> Set.empty
      A.AsP _ _ p   -> patVars p
      A.PatternSynP _ _ _ -> __IMPOSSIBLE__ -- Set.empty

    -- Replace dot variables by ._ if they use implicitly bound variables. This
    -- is slightly nicer than making the implicts explicit.
    blankDots ps = (map . fmap . fmap . fmap) blank ps
      where
        bound = argsVars ps
        blank e | Set.null (Set.difference (dotVars e) bound) = e
                | otherwise = A.Underscore emptyMetaInfo

    -- Pick the "best" place to bind the variable. Best in this case
    -- is the left-most explicit binding site. But, of course we can't
    -- do this since binding site might be forced by a parent clause.
    -- Why? Because the binding site we pick might not exist in the
    -- generated with function if it corresponds to a dot pattern.
    rearrangeBinding x ps = ps

    strip dvs ps = stripArgs True ps
      where
        stripArgs _ [] = []
        stripArgs fixedPos (a : as) =
          case getHiding a of
            Hidden   | canStrip a as -> stripArgs False as
            Instance | canStrip a as -> stripArgs False as
            _                        -> stripName fixedPos (stripArg a) :
                                        stripArgs True as

        stripName True  = fmap (unnamed . namedThing)
        stripName False = id

        canStrip a as = and
          [ varOrDot p
          , noInterestingBindings p
          , all (flip canStrip []) $ takeWhile isUnnamedHidden as
          ]
          where p = namedArg a

        isUnnamedHidden x = notVisible x && nameOf (unArg x) == Nothing

        stripArg a = fmap (fmap stripPat) a

        stripPat p = case p of
          A.VarP _      -> p
          A.ConP i c ps -> A.ConP i c $ stripArgs True ps
          A.DefP _ _ _  -> p
          A.DotP _ e    -> p
          A.WildP _     -> p
          A.AbsurdP _   -> p
          A.LitP _      -> p
          A.ImplicitP _ -> p
          A.AsP i x p   -> A.AsP i x $ stripPat p
          A.PatternSynP _ _ _ -> __IMPOSSIBLE__ -- p

        noInterestingBindings p =
          Set.null $ dvs `Set.intersection` patVars p

        varOrDot A.VarP{}      = True
        varOrDot A.WildP{}     = True
        varOrDot A.DotP{}      = True
        varOrDot A.ImplicitP{} = True
        varOrDot _             = False

-- | @dotVars ps@ gives all the variables inside of dot patterns of @ps@
--   It is only invoked for patternish things. (Ulf O-tone!)
--   Use it for printing l.h.sides: which of the implicit arguments
--   have to be made explicit.
class DotVars a where
  dotVars  :: a -> Set Name
  isConPat :: a -> Bool
  isConPat _ = False

instance DotVars a => DotVars (A.Arg a) where
  dotVars a = if notVisible a && not (isConPat a)   -- Hidden constructor patterns are visible!
              then Set.empty
              else dotVars (unArg a)
  isConPat = isConPat . unArg

instance DotVars a => DotVars (Named s a) where
  dotVars = dotVars . namedThing
  isConPat = isConPat . namedThing

instance DotVars a => DotVars [a] where
  dotVars = Set.unions . map dotVars

instance (DotVars a, DotVars b) => DotVars (a, b) where
  dotVars (x, y) = Set.union (dotVars x) (dotVars y)

instance DotVars A.Clause where
  dotVars (A.Clause _ rhs []) = dotVars rhs
  dotVars (A.Clause _ rhs (_:_)) = __IMPOSSIBLE__ -- cannot contain where clauses?

instance DotVars A.Pattern where
  dotVars p = case p of
    A.VarP _      -> Set.empty   -- do not add pattern vars
    A.ConP _ _ ps -> dotVars ps
    A.DefP _ _ ps -> dotVars ps
    A.DotP _ e    -> dotVars e
    A.WildP _     -> Set.empty
    A.AbsurdP _   -> Set.empty
    A.LitP _      -> Set.empty
    A.ImplicitP _ -> Set.empty
    A.AsP _ _ p   -> dotVars p
    A.PatternSynP _ _ _ -> __IMPOSSIBLE__ -- Set.empty
  isConPat A.ConP{} = True
  isConPat A.LitP{} = True
  isConPat _        = False

-- | Getting all(!) variables of an expression.
--   It should only get free ones, but it does not matter to include
--   the bound ones.
instance DotVars A.Expr where
  dotVars e = case e of
    A.ScopedExpr _ e       -> dotVars e
    A.Var x                -> Set.singleton x -- add any expression variable
    A.Def _                -> Set.empty
    A.Con _                -> Set.empty
    A.Lit _                -> Set.empty
    A.QuestionMark{}       -> Set.empty
    A.Underscore _         -> Set.empty
    A.App _ e1 e2          -> dotVars (e1, e2)
    A.WithApp _ e es       -> dotVars (e, es)
    A.Lam _ _ e            -> dotVars e
    A.AbsurdLam _ _        -> Set.empty
    A.ExtendedLam _ _ _ cs -> dotVars cs
    A.Pi _ tel e           -> dotVars (tel, e)
    A.Fun _ a b            -> dotVars (a, b)
    A.Set _ _              -> Set.empty
    A.Prop _               -> Set.empty
    A.Let _ _ _            -> __IMPOSSIBLE__
    A.Rec _ es             -> dotVars $ map snd es
    A.RecUpdate _ e es     -> dotVars (e, map snd es)
    A.ETel _               -> __IMPOSSIBLE__
    A.QuoteGoal {}         -> __IMPOSSIBLE__
    A.QuoteContext {}      -> __IMPOSSIBLE__
    A.Quote {}             -> __IMPOSSIBLE__
    A.QuoteTerm {}         -> __IMPOSSIBLE__
    A.Unquote {}           -> __IMPOSSIBLE__
    A.DontCare v           -> dotVars v
    A.PatternSyn n         -> Set.empty

instance DotVars RHS where
  dotVars (RHS e) = dotVars e
  dotVars AbsurdRHS = Set.empty
  dotVars (WithRHS _ es clauses) = __IMPOSSIBLE__ -- NZ
  dotVars (RewriteRHS _ es rhs _) = __IMPOSSIBLE__ -- NZ

instance DotVars TypedBindings where
  dotVars (TypedBindings _ bs) = dotVars bs

instance DotVars TypedBinding where
  dotVars (TBind _ _ e) = dotVars e
  dotVars (TLet _ _)    = __IMPOSSIBLE__ -- Since the internal syntax has no let bindings left

reifyPatterns :: I.Telescope -> Permutation -> [I.NamedArg I.Pattern] -> TCM [A.NamedArg A.Pattern]
reifyPatterns tel perm ps = evalStateT (reifyArgs ps) 0
  where
    reifyArgs :: [I.NamedArg I.Pattern] -> StateT Nat TCM [A.NamedArg A.Pattern]
    reifyArgs is = mapM reifyArg is

    reifyArg :: I.NamedArg I.Pattern -> StateT Nat TCM (A.NamedArg A.Pattern)
    reifyArg i = stripNameFromExplicit <$>
                 traverse (traverse reifyPat) (setArgColors [] i) -- TODO guilhem

    stripNameFromExplicit a
      | getHiding a == NotHidden = fmap (unnamed . namedThing) a
      | otherwise                = a

    tick = do i <- get; put (i + 1); return i

    translate = (vars !!)
      where
        vars = permute (invertP perm) [0..]

    reifyPat :: I.Pattern -> StateT Nat TCM A.Pattern
    reifyPat p = case p of
      I.VarP "()" -> return $ A.AbsurdP patNoRange   -- HACK
      I.VarP s -> do
        i <- tick
        let j = translate i
        lift $ A.VarP <$> nameOfBV (size tel - 1 - j)
      I.DotP v -> do
        t <- lift $ reify v
        tick
        let vars = Set.map show (dotVars t)
            t'   = if Set.member "()" vars then underscore else t
        return $ A.DotP patNoRange t'
      I.LitP l  -> return $ A.LitP l
      I.ProjP d -> return $ A.DefP patNoRange d []
      I.ConP c mt ps -> A.ConP ci (AmbQ [conName c]) <$> reifyArgs ps
        where ci = flip ConPatInfo patNoRange $ maybe False fst mt

instance Reify NamedClause A.Clause where
  reify (QNamed f (I.Clause _ tel perm ps body _)) = addCtxTel tel $ do
    ps  <- reifyPatterns tel perm ps
    lhs <- liftTCM $ reifyDisplayFormP $ SpineLHS info f ps [] -- LHS info (LHSHead f ps) []
    nfv <- getDefFreeVars f
    lhs <- stripImps $ dropParams nfv lhs
    reportSLn "reify.clause" 60 $ "reifying NamedClause, lhs = " ++ show lhs
    rhs <- reify $ renameP (reverseP perm) <$> body
    reportSLn "reify.clause" 60 $ "reifying NamedClause, rhs = " ++ show rhs
    let result = A.Clause (spineToLhs lhs) rhs []
    reportSLn "reify.clause" 60 $ "reified NamedClause, result = " ++ show result
    return result
    where
      info = LHSRange noRange

      dropParams n (SpineLHS i f ps wps) = SpineLHS i f (genericDrop n ps) wps
      stripImps (SpineLHS i f ps wps) = do
        (ps, wps) <- stripImplicits =<< shuffleDots (ps, wps)
        return $ SpineLHS i f ps wps

instance Reify Type Expr where
    reifyWhen = reifyWhenE
    reify (I.El _ t) = reify t

instance Reify Sort Expr where
    reifyWhen = reifyWhenE
    reify s =
        do  s <- instantiateFull s
            case s of
                I.Type (I.Max [])                -> return $ A.Set exprInfo 0
                I.Type (I.Max [I.ClosedLevel n]) -> return $ A.Set exprInfo n
                I.Type a -> do
                  a <- reify a
                  return $ A.App exprInfo (A.Set exprInfo 0) (defaultNamedArg a)
                I.Prop       -> return $ A.Prop exprInfo
                I.Inf       -> A.Var <$> freshName_ "Setω"
                I.DLub s1 s2 -> do
                  lub <- freshName_ "dLub" -- TODO: hack
                  (e1,e2) <- reify (s1, I.Lam defaultArgInfo $ fmap Sort s2)
                  let app x y = A.App exprInfo x (defaultNamedArg y)
                  return $ A.Var lub `app` e1 `app` e2

instance Reify Level Expr where
  reifyWhen = reifyWhenE
  reify l = reify =<< reallyUnLevelView l

instance (Free i, Reify i a) => Reify (Abs i) (Name, a) where
  reify (NoAbs x v) = (,) <$> freshName_ x <*> reify v
  reify (Abs s v) = do

    -- If the bound variable is free in the body, then the name "_" is
    -- replaced by "z".
    s <- return $ if s == "_" && 0 `freeIn` v then "z" else s

    x <- freshName_ s
    e <- addCtx x dummyDom -- type doesn't matter
         $ reify v
    return (x,e)

instance Reify I.Telescope A.Telescope where
  reify EmptyTel = return []
  reify (ExtendTel arg tel) = do
    Common.Arg info e <- reify arg
    (x,bs)  <- reify tel
    let r = getRange e
    return $ TypedBindings r (Common.Arg info (TBind r [x] e)) : bs

instance Reify I.ArgInfo A.ArgInfo where
    reify i = flip (mapArgInfoColors.const) i <$> reify (argInfoColors i)

instance Reify i a => Reify (I.Dom i) (A.Arg a) where
    reify (Common.Dom info i) = liftM2 Common.Arg (reify info) (reify i)

instance Reify i a => Reify [i] [a] where
    reify = traverse reify

instance (Reify i1 a1, Reify i2 a2) => Reify (i1,i2) (a1,a2) where
    reify (x,y) = (,) <$> reify x <*> reify y

instance (Reify i1 a1, Reify i2 a2, Reify i3 a3) => Reify (i1,i2,i3) (a1,a2,a3) where
    reify (x,y,z) = (,,) <$> reify x <*> reify y <*> reify z

instance (Reify i1 a1, Reify i2 a2, Reify i3 a3, Reify i4 a4) => Reify (i1,i2,i3,i4) (a1,a2,a3,a4) where
    reify (x,y,z,w) = (,,,) <$> reify x <*> reify y <*> reify z <*> reify w

instance (Reify t t', Reify a a')
         => Reify (Judgement t a) (Judgement t' a') where
    reify (HasType i t) = HasType <$> reify i <*> reify t
    reify (IsSort  i t) = IsSort  <$> reify i <*> reify t
