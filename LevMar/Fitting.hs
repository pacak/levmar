{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

--------------------------------------------------------------------------------
-- |
-- Module      :  LevMar.Fitting
-- Copyright   :  (c) 2009 Roel van Dijk & Bas van Dijk
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  vandijk.roel@gmail.com, v.dijk.bas@gmail.com
-- Stability   :  Experimental
--
-- This module provides the Levenberg-Marquardt algorithm specialised
-- for curve-fitting.
--
-- For additional documentation see the documentation of the levmar C
-- library which this library is based on:
-- <http://www.ics.forth.gr/~lourakis/levmar/>
--
--------------------------------------------------------------------------------

module LevMar.Fitting
    ( -- * Model & Jacobian.
      Model
    , SimpleModel
    , Jacobian
    , SimpleJacobian

      -- * Levenberg-Marquardt algorithm.
    , LMA_I.LevMarable
    , levmar

    , LinearConstraints
    , noLinearConstraints
    , Matrix

    -- * Minimization options.
    , LMA_I.Options(..)
    , LMA_I.defaultOpts

      -- * Output
    , LMA_I.Info(..)
    , LMA_I.StopReason(..)
    , CovarMatrix

    , LMA_I.LevMarError(..)

      -- *Type-level machinery
    , Z, S, Nat
    , SizedList(..)
    , NFunction
    ) where

import Prelude hiding ( curry )
import qualified LevMar.Intermediate.Fitting as LMA_I
import LevMar.Utils ( LinearConstraints
                    , noLinearConstraints
                    , convertLinearConstraints
                    , Matrix
                    , CovarMatrix
                    , convertResult
                    )

import TypeLevelNat ( Z, S, Nat )
import SizedList    ( SizedList(..), toList, unsafeFromList, replace )
import NFunction    ( NFunction, ($*), Curry, curry )

import LevMar.Utils.AD  ( firstDeriv, constant )

-- From vector-space:
import Data.Derivative  ( (:~>), idD )
import Data.VectorSpace ( VectorSpace, Scalar )
import Data.Basis       ( HasBasis, Basis )

--------------------------------------------------------------------------------
-- Model & Jacobian.
--------------------------------------------------------------------------------

{- | A functional relation describing measurements represented as a function
from @m@ parameters and an x-value to an expected measurement.

For example, the quadratic function @f(x) = a*x^2 + b*x + c@ can be
written as:

@
type N3 = 'S' ('S' ('S' 'Z'))

quad :: 'Num' r => 'Model' N3 r r
quad a b c x = a*x^2 + b*x + c
@
-}
type Model m r a = NFunction m r (a -> r)

-- | This type synonym expresses that usually the @a@ in @'Model' m r a@
-- equals the type of the parameters.
type SimpleModel m r = Model m r r

{- | The jacobian of the 'Model' function. Expressed as a function from @n@
parameters and an x-value to the @m@ partial derivatives of the parameters.

See: <http://en.wikipedia.org/wiki/Jacobian_matrix_and_determinant>

For example, the jacobian of the quadratic function @f(x) = a*x^2 +
b*x + c@ can be written as:

@
type N3 = 'S' ('S' ('S' 'Z'))

quadJacob :: 'Num' r => 'Jacobian' N3 r r
quadJacob _ _ _ x =   x^2   -- with respect to a
                  ::: x     -- with respect to b
                  ::: 1     -- with respect to c
                  ::: 'Nil'
@

Notice you don't have to differentiate for @x@.
-}
type Jacobian m r a = NFunction m r (a -> SizedList m r)

-- | This type synonym expresses that usually the @a@ in @'Jacobian' m r a@
-- equals the type of the parameters.
type SimpleJacobian m r = Jacobian m r r

-- | Compute the 'Jacobian' of the 'Model' using Automatic Differentiation.
jacobianOf :: forall m r a. (Nat m, Curry m, HasBasis r, Basis r ~ (), VectorSpace (Scalar r))
           => Model m (r :~> r) a -> Jacobian m r a
jacobianOf model = curry jac
    where
      jac :: SizedList m r -> (a -> SizedList m r)
      (jac ps) x = unsafeFromList $ map combine $ zip [0..] $ toList ps
          where
            combine :: (Int, r) -> r
            combine (ix, p) = firstDeriv $ (model $* (replace ix idD $ fmap constant ps) :: a -> r :~> r) x p


--------------------------------------------------------------------------------
-- Levenberg-Marquardt algorithm.
--------------------------------------------------------------------------------

-- | The Levenberg-Marquardt algorithm specialised for curve-fitting.
levmar :: forall m k r a. (Nat m, Nat k, LMA_I.LevMarable r)
       => (Model m r a)                          -- ^ Model
       -> Maybe (Jacobian m r a)                 -- ^ Optional jacobian
       -> SizedList m r                          -- ^ Initial parameters
       -> [(a, r)]                               -- ^ Samples
       -> Integer                                -- ^ Maximum number of iterations
       -> LMA_I.Options r                        -- ^ Minimization options
       -> Maybe (SizedList m r)                  -- ^ Optional lower bounds
       -> Maybe (SizedList m r)                  -- ^ Optional upper bounds
       -> Maybe (LinearConstraints k m r)        -- ^ Optional linear constraints
       -> Maybe (SizedList m r)                  -- ^ Optional weights
       -> Either LMA_I.LevMarError (SizedList m r, LMA_I.Info r, CovarMatrix m r)
levmar model mJac params ys itMax opts mLowBs mUpBs mLinC mWghts =
    fmap convertResult $ LMA_I.levmar (convertModel model)
                                      (fmap convertJacob mJac)
                                      (toList params)
                                      ys
                                      itMax
                                      opts
                                      (fmap toList mLowBs)
                                      (fmap toList mUpBs)
                                      (fmap convertLinearConstraints mLinC)
                                      (fmap toList mWghts)
    where
      convertModel mdl = \ps   ->          mdl $* (unsafeFromList ps :: SizedList m r)
      convertJacob jac = \ps x -> toList ((jac $* (unsafeFromList ps :: SizedList m r)) x :: SizedList m r)


-- The End ---------------------------------------------------------------------
