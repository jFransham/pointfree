{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternGuards #-}
module Plugin.Pl.Transform (
    transform,
  ) where

import Plugin.Pl.Common
import Plugin.Pl.PrettyPrinter ()

import qualified Data.Map as M

import Data.Graph (stronglyConnComp, flattenSCC, flattenSCCs)
import Control.Monad.Trans.State

{-
nub :: Ord a => [a] -> [a]
nub = nub' S.empty where
  nub' _ [] = []
  nub' set (x:xs)
    | x `S.member` set = nub' set xs
    | otherwise = x: nub' (x `S.insert` set) xs
-}

occursP :: String -> Pattern -> Bool
occursP v (PVar v') = v == v'
occursP v (PTuple p1 p2) = v `occursP` p1 || v `occursP` p2
occursP v (PCons  p1 p2) = v `occursP` p1 || v `occursP` p2

freeIn :: String -> Expr -> Int
freeIn v (Var _ v') = fromEnum $ v == v'
freeIn v (Lambda pat e) = if v `occursP` pat then 0 else freeIn v e
freeIn v (App e1 e2) = freeIn v e1 + freeIn v e2
freeIn v (Let ds e') = if v `elem` map declName ds then 0 
  else freeIn v e' + sum [freeIn v e | Define _ e <- ds]

isFreeIn :: String -> Expr -> Bool
isFreeIn v e = freeIn v e > 0

tuple :: [Expr] -> Expr
tuple es  = foldr1 (\x y -> Var Inf "," `App` x `App` y) es

tupleP :: [String] -> Pattern
tupleP vs = foldr1 PTuple $ PVar `map` vs

dependsOn :: [Decl] -> Decl -> [Decl]
dependsOn ds d = [d' | d' <- ds, declName d' `isFreeIn` declExpr d]
  
unLet :: Expr -> Expr
unLet (App e1 e2) = App (unLet e1) (unLet e2)
unLet (Let [] e) = unLet e
unLet (Let ds e) = unLet $
  (Lambda (tupleP $ declName `map` dsYes) (Let dsNo e)) `App`
    (fix' `App` (Lambda (tupleP $ declName `map` dsYes)
                        (tuple  $ declExpr `map` dsYes)))
    where
  comps = stronglyConnComp [(d',d',dependsOn ds d') | d' <- ds]
  dsYes = flattenSCC $ head comps
  dsNo = flattenSCCs $ tail comps
  
unLet (Lambda v e) = Lambda v (unLet e)
unLet (Var f x) = Var f x

type Env = M.Map String String

-- It's a pity we still need that for the pointless transformation.
-- Otherwise a newly created id/const/... could be bound by a lambda
-- e.g. transform' (\id x -> x) ==> transform' (\id -> id) ==> id
alphaRename :: Expr -> Expr
alphaRename e = alpha e `evalState` M.empty where
  alpha :: Expr -> State Env Expr
  alpha (Var f v) = do fm <- get; return $ Var f $ maybe v id (M.lookup v fm)
  alpha (App e1 e2) = liftM2 App (alpha e1) (alpha e2)
  alpha (Let _ _) = assert False bt
  alpha (Lambda v e') = inEnv $ liftM2 Lambda (alphaPat v) (alpha e')

  -- act like a reader monad
  inEnv :: State s a -> State s a
  inEnv f = gets $ evalState f

  alphaPat (PVar v) = do
    fm <- get
    let v' = "$" ++ show (M.size fm)
    put $ M.insert v v' fm
    return $ PVar v'
  alphaPat (PTuple p1 p2) = liftM2 PTuple (alphaPat p1) (alphaPat p2)
  alphaPat (PCons p1 p2) = liftM2 PCons (alphaPat p1) (alphaPat p2)


transform :: Expr -> Expr
transform = transform' . alphaRename . unLet

-- Infinite generator of variable names.
varNames :: [String]
varNames = concatMap (flip replicateM usableChars) [1..]
  where
    usableChars = ['a'..'z']

-- First variable name not already in use
fresh :: [String] -> String
fresh variables = head . filter (not . flip elem variables) $ varNames

names :: Pattern -> [String]
names (PVar str)         = [str]
names (PCons pat0 pat1)  = names pat0 ++ names pat1
names (PTuple pat0 pat1) = names pat0 ++ names pat1

transform' :: Expr -> Expr
transform' = go []
  where
    go _ (Let {}) =
      assert False bt
    go _ (Var f v) =
      Var f v
    go vars (App e1 e2) =
      App (go vars e1) (go vars e2)
    go vars (Lambda (PTuple p1 p2) e) =
      go vars' $
        Lambda (PVar var) $ (Lambda p1 . Lambda p2 $ e) `App` f `App` s
      where
        vars' = names p1 ++ names p2 ++ vars
        var   = fresh vars'
        f     = Var Pref "fst" `App` Var Pref var
        s     = Var Pref "snd" `App` Var Pref var
    go vars (Lambda (PCons p1 p2) e) =
      go vars' $
        Lambda (PVar var) $ (Lambda p1 . Lambda p2 $ e) `App` f `App` s
      where
        vars' = names p1 ++ names p2 ++ vars
        var = fresh []
        f   = Var Pref "head" `App` Var Pref var
        s   = Var Pref "tail" `App` Var Pref var
    go vars (Lambda (PVar v) e) =
      go vars' $ getRidOfV e
      where
        vars' = v : vars

        getRidOfV (Var f v') | v == v'   = id'
                             | otherwise = const' `App` Var f v'
        getRidOfV l@(Lambda pat _) =
          assert (not $ v `occursP` pat) $ getRidOfV $ go vars'' l
          where
            vars'' = names pat ++ vars'
        getRidOfV (Let {}) = assert False bt
        getRidOfV e'@(App e1 e2)
          | fr1 && fr2 = scomb `App` getRidOfV e1 `App` getRidOfV e2
          | fr1 = flip' `App` getRidOfV e1 `App` e2
          | Var _ v' <- e2, v' == v = e1
          | fr2 = comp `App` e1 `App` getRidOfV e2
          | True = const' `App` e'
          where
            fr1 = v `isFreeIn` e1
            fr2 = v `isFreeIn` e2
