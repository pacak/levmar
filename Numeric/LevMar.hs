{-# LANGUAGE NoImplicitPrelude
           , UnicodeSyntax
           , ScopedTypeVariables
           , DeriveDataTypeable
  #-}

--------------------------------------------------------------------------------
-- |
-- Module:     Numeric.LevMar
-- Copyright:  (c) 2009 - 2010 Roel van Dijk & Bas van Dijk
-- License:    BSD-style (see the file LICENSE)
-- Maintainer: Roel van Dijk <vandijk.roel@gmail.com>
--             Bas van Dijk <v.dijk.bas@gmail.com>
-- Stability:  Experimental
--
-- For additional documentation see the documentation of the levmar C
-- library which this library is based on:
-- <http://www.ics.forth.gr/~lourakis/levmar/>
--
--------------------------------------------------------------------------------

module Numeric.LevMar
    ( -- * Model & Jacobian.
      Model
    , Jacobian

      -- * Levenberg-Marquardt algorithm.
    , LevMarable(levmar)

    , LinearConstraints

      -- * Minimization options.
    , Options(..)
    , defaultOpts

      -- * Output
    , Info(..)
    , StopReason(..)
    , CovarMatrix

    , LevMarError(..)
    ) where


-------------------------------------------------------------------------------
-- Imports
-------------------------------------------------------------------------------

-- from base:
import Control.Monad.Instances -- for 'instance Functor (Either a)'
import Control.Exception     ( Exception )
import Data.Typeable         ( Typeable )
import Data.Bool             ( otherwise )
import Data.Either           ( Either(Left, Right) )
import Data.Function         ( ($) )
import Data.List             ( lookup, map, concat, concatMap, length )
import Data.Maybe            ( Maybe(Nothing, Just)
                             , isJust, fromJust, fromMaybe
                             )
import Data.Ord              ( (<) )
import Foreign.Marshal.Array ( allocaArray, peekArray, pokeArray, withArray )
import Foreign.Ptr           ( Ptr, nullPtr, plusPtr )
import Foreign.Storable      ( Storable )
import Foreign.C.Types       ( CInt )
import Prelude               ( Enum, Fractional, Real, RealFrac
                             , Integer, Float, Double
                             , fromInteger, fromIntegral, realToFrac, toEnum
                             , (-), error, floor
                             )
import System.IO             ( IO )
import System.IO.Unsafe      ( unsafePerformIO )
import Text.Read             ( Read )
import Text.Show             ( Show )

-- from base-unicode-symbols:
import Data.Bool.Unicode     ( (∧), (∨) )
import Data.Eq.Unicode       ( (≡), (≢) )
import Data.Function.Unicode ( (∘) )
import Prelude.Unicode       ( (⋅) )

-- from bindings-levmar:
import qualified Bindings.LevMar as BLM

-- from levmar:
import qualified Bindings.LevMar.CurryFriendly as CF


--------------------------------------------------------------------------------
-- Model & Jacobian.
--------------------------------------------------------------------------------

{-| A functional relation describing measurements represented as a function
from a list of parameters to a list of expected measurements.

 * Ensure that the length of the parameters list equals the length of the
   initial parameters list in 'levmar'.

 * Ensure that the length of the ouput list equals the length of the samples
   list in 'levmar'.

For example:

@
hatfldc :: Model Double
hatfldc [p0, p1, p2, p3] = [ p0 - 1.0
                           , p0 - sqrt p1
                           , p1 - sqrt p2
                           , p3 - 1.0
                           ]
@
-}
type Model r = [r] → [r]

{-| The jacobian of the 'Model' function. Expressed as a function from a list
of parameters to a list of lists which for each expected measurement describes
the partial derivatives of the parameters.

See: <http://en.wikipedia.org/wiki/Jacobian_matrix_and_determinant>

 * Ensure that the length of the parameter list equals the length of the initial
   parameter list in 'levmar'.

 * Ensure that the output matrix has the dimension @n@/x/@m@ where @n@ is the
   number of samples and @m@ is the number of parameters.

For example the jacobian of the above @hatfldc@ model is:

@
hatfldc_jac :: Jacobian Double
hatfldc_jac _ p1 p2 _ = [ [1.0,  0.0,           0.0,           0.0]
                        , [1.0, -0.5 / sqrt p1, 0.0,           0.0]
                        , [0.0,  1.0,          -0.5 / sqrt p2, 0.0]
                        , [0.0,  0.0,           0.0,           1.0]
                        ]
@
-}
type Jacobian r = [r] → [[r]]


--------------------------------------------------------------------------------
-- Levenberg-Marquardt algorithm.
--------------------------------------------------------------------------------

-- | The Levenberg-Marquardt algorithm is overloaded to work on 'Double' and 'Float'.
class LevMarable r where

    -- | The Levenberg-Marquardt algorithm.
    levmar ∷ Model r                     -- ^ Model
           → Maybe (Jacobian r)          -- ^ Optional jacobian
           → [r]                         -- ^ Initial parameters
           → [r]                         -- ^ Samples
           → Integer                     -- ^ Maximum iterations
           → Options r                   -- ^ Minimization options
           → Maybe [r]                   -- ^ Optional lower bounds
           → Maybe [r]                   -- ^ Optional upper bounds
           → Maybe (LinearConstraints r) -- ^ Optional linear constraints
           → Maybe [r]                   -- ^ Optional weights
           → Either LevMarError ([r], Info r, CovarMatrix r)

instance LevMarable Float where
    levmar = gen_levmar CF.slevmar_der
                        CF.slevmar_dif
                        CF.slevmar_bc_der
                        CF.slevmar_bc_dif
                        CF.slevmar_lec_der
                        CF.slevmar_lec_dif
                        CF.slevmar_blec_der
                        CF.slevmar_blec_dif

instance LevMarable Double where
    levmar = gen_levmar CF.dlevmar_der
                        CF.dlevmar_dif
                        CF.dlevmar_bc_der
                        CF.dlevmar_bc_dif
                        CF.dlevmar_lec_der
                        CF.dlevmar_lec_dif
                        CF.dlevmar_blec_der
                        CF.dlevmar_blec_dif

{-| @gen_levmar@ takes the low-level C functions as arguments and
executes one of them depending on the optional jacobian and constraints.

Preconditions:

@
  length ys >= length ps

     isJust mLowBs && length (fromJust mLowBs) == length ps
  && isJust mUpBs  && length (fromJust mUpBs)  == length ps

  boxConstrained && (all $ zipWith (<=) (fromJust mLowBs) (fromJust mUpBs))
@
-}
gen_levmar ∷ ∀ cr r. (Storable cr, RealFrac cr, Real r, Fractional r)
           ⇒ CF.LevMarDer cr
           → CF.LevMarDif cr
           → CF.LevMarBCDer cr
           → CF.LevMarBCDif cr
           → CF.LevMarLecDer cr
           → CF.LevMarLecDif cr
           → CF.LevMarBLecDer cr
           → CF.LevMarBLecDif cr

           → Model r                     -- ^ Model
           → Maybe (Jacobian r)          -- ^ Optional jacobian
           → [r]                         -- ^ Initial parameters
           → [r]                         -- ^ Samples
           → Integer                     -- ^ Maximum iterations
           → Options r                   -- ^ Options
           → Maybe [r]                   -- ^ Optional lower bounds
           → Maybe [r]                   -- ^ Optional upper bounds
           → Maybe (LinearConstraints r) -- ^ Optional linear constraints
           → Maybe [r]                   -- ^ Optional weights
           → Either LevMarError ([r], Info r, CovarMatrix r)
gen_levmar f_der
           f_dif
           f_bc_der
           f_bc_dif
           f_lec_der
           f_lec_dif
           f_blec_der
           f_blec_dif
           model mJac ps ys itMax opts mLowBs mUpBs mLinC mWeights
    = unsafePerformIO ∘
        withArray (map realToFrac ps) $ \psPtr →
        withArray (map realToFrac ys) $ \ysPtr →
        withArray (map realToFrac $ optsToList opts) $ \optsPtr →
        allocaArray BLM.c'LM_INFO_SZ $ \infoPtr →
        allocaArray covarLen $ \covarPtr →
        BLM.withModel (convertModel model) $ \modelPtr → do

          let runDif ∷ CF.LevMarDif cr → IO CInt
              runDif f = f modelPtr
                           psPtr
                           ysPtr
                           (fromIntegral lenPs)
                           (fromIntegral lenYs)
                           (fromIntegral itMax)
                           optsPtr
                           infoPtr
                           nullPtr
                           covarPtr
                           nullPtr

          r ← case mJac of
                 Just jac → BLM.withJacobian (convertJacobian jac) $ \jacobPtr →
                               let runDer ∷ CF.LevMarDer cr → IO CInt
                                   runDer f = runDif $ f jacobPtr
                               in if boxConstrained
                                  then if linConstrained
                                       then withBoxConstraints (withLinConstraints $ withWeights runDer) f_blec_der
                                       else withBoxConstraints runDer f_bc_der
                                  else if linConstrained
                                       then withLinConstraints runDer f_lec_der
                                       else runDer f_der

                 Nothing → if boxConstrained
                            then if linConstrained
                                 then withBoxConstraints (withLinConstraints $ withWeights runDif) f_blec_dif
                                 else withBoxConstraints runDif f_bc_dif
                            else if linConstrained
                                 then withLinConstraints runDif f_lec_dif
                                 else runDif f_dif

          if r < 0
             -- we don't treat these two as an error
             ∧ r ≢ BLM.c'LM_ERROR_SINGULAR_MATRIX
             ∧ r ≢ BLM.c'LM_ERROR_SUM_OF_SQUARES_NOT_FINITE
            then return ∘ Left $ convertLevMarError r
            else do result ← peekArray lenPs psPtr
                    info   ← peekArray BLM.c'LM_INFO_SZ infoPtr

                    let covarPtrEnd = plusPtr covarPtr covarLen
                        convertCovarMatrix ptr
                            | ptr ≡ covarPtrEnd = return []
                            | otherwise = do row ← peekArray lenPs ptr
                                             rows ← convertCovarMatrix $ plusPtr ptr lenPs
                                             return $ row : rows

                    covar ← convertCovarMatrix covarPtr

                    return $ Right ( map realToFrac result
                                   , listToInfo info
                                   , map (map realToFrac) covar
                                   )
    where
      lenPs          = length ps
      lenYs          = length ys
      covarLen       = lenPs ⋅ lenPs
      (cMat, rhcVec) = fromJust mLinC

      -- Whether the parameters are constrained by a linear equation.
      linConstrained = isJust mLinC

      -- Whether the parameters are constrained by a bounding box.
      boxConstrained = isJust mLowBs ∨ isJust mUpBs

      withBoxConstraints f g =
          maybeWithArray ((fmap ∘ fmap) realToFrac mLowBs) $ \lBsPtr →
            maybeWithArray ((fmap ∘ fmap) realToFrac mUpBs) $ \uBsPtr →
              f $ g lBsPtr uBsPtr

      withLinConstraints f g =
          withArray (map realToFrac $ concat cMat) $ \cMatPtr →
            withArray (map realToFrac rhcVec) $ \rhcVecPtr →
              f ∘ g cMatPtr rhcVecPtr ∘ fromIntegral $ length cMat

      withWeights f g = maybeWithArray ((fmap ∘ fmap) realToFrac mWeights) $ f ∘ g

convertModel ∷ (Real r, Fractional r, Storable c, Real c, Fractional c)
             ⇒ Model r → BLM.Model c
convertModel model =
    \parPtr hxPtr numPar _ _ → do
      params ← peekArray (fromIntegral numPar) parPtr
      pokeArray hxPtr ∘ map realToFrac ∘ model $ map realToFrac params

convertJacobian ∷ (Real r, Fractional r, Storable c, Real c, Fractional c)
                ⇒ Jacobian r → BLM.Jacobian c
convertJacobian jac =
    \parPtr jPtr numPar _ _ → do
      params ← peekArray (fromIntegral numPar) parPtr
      pokeArray jPtr ∘ concatMap (map realToFrac) ∘ jac $ map realToFrac params

maybeWithArray ∷ Storable a ⇒ Maybe [a] → (Ptr a → IO b) → IO b
maybeWithArray Nothing   f = f nullPtr
maybeWithArray (Just xs) f = withArray xs f


-- | Linear constraints consisting of a constraints matrix, /kxm/ and
--   a right hand constraints vector, /kx1/ where /m/ is the number of
--   parameters and /k/ is the number of constraints.
type LinearConstraints r = ([[r]], [r])


--------------------------------------------------------------------------------
-- Minimization options.
--------------------------------------------------------------------------------

-- | Minimization options
data Options r =
    Opts { optScaleInitMu      ∷ r -- ^ Scale factor for initial /mu/.
         , optStopNormInfJacTe ∷ r -- ^ Stopping thresholds for @||J^T e||_inf@.
         , optStopNorm2Dp      ∷ r -- ^ Stopping thresholds for @||Dp||_2@.
         , optStopNorm2E       ∷ r -- ^ Stopping thresholds for @||e||_2@.
         , optDelta            ∷ r -- ^ Step used in the difference
                                   -- approximation to the Jacobian. If
                                   -- @optDelta<0@, the Jacobian is approximated
                                   -- with central differences which are more
                                   -- accurate (but slower!)  compared to the
                                   -- forward differences employed by default.
         } deriving (Read, Show)

-- | Default minimization options
defaultOpts ∷ Fractional r ⇒ Options r
defaultOpts = Opts { optScaleInitMu      = BLM.c'LM_INIT_MU
                   , optStopNormInfJacTe = BLM.c'LM_STOP_THRESH
                   , optStopNorm2Dp      = BLM.c'LM_STOP_THRESH
                   , optStopNorm2E       = BLM.c'LM_STOP_THRESH
                   , optDelta            = BLM.c'LM_DIFF_DELTA
                   }

optsToList ∷ Options r → [r]
optsToList (Opts mu  eps1  eps2  eps3  delta) =
                [mu, eps1, eps2, eps3, delta]


--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

-- | Information regarding the minimization.
data Info r = Info
  { infNorm2initE      ∷ r          -- ^ @||e||_2@             at initial parameters.
  , infNorm2E          ∷ r          -- ^ @||e||_2@             at estimated parameters.
  , infNormInfJacTe    ∷ r          -- ^ @||J^T e||_inf@       at estimated parameters.
  , infNorm2Dp         ∷ r          -- ^ @||Dp||_2@            at estimated parameters.
  , infMuDivMax        ∷ r          -- ^ @\mu/max[J^T J]_ii ]@ at estimated parameters.
  , infNumIter         ∷ Integer    -- ^ Number of iterations.
  , infStopReason      ∷ StopReason -- ^ Reason for terminating.
  , infNumFuncEvals    ∷ Integer    -- ^ Number of function evaluations.
  , infNumJacobEvals   ∷ Integer    -- ^ Number of jacobian evaluations.
  , infNumLinSysSolved ∷ Integer    -- ^ Number of linear systems solved,
                                    --   i.e. attempts for reducing error.
  } deriving (Read, Show)

listToInfo ∷ (RealFrac cr, Fractional r) ⇒ [cr] → Info r
listToInfo [a,b,c,d,e,f,g,h,i,j] =
    Info { infNorm2initE      = realToFrac a
         , infNorm2E          = realToFrac b
         , infNormInfJacTe    = realToFrac c
         , infNorm2Dp         = realToFrac d
         , infMuDivMax        = realToFrac e
         , infNumIter         = floor f
         , infStopReason      = toEnum $ floor g - 1
         , infNumFuncEvals    = floor h
         , infNumJacobEvals   = floor i
         , infNumLinSysSolved = floor j
         }
listToInfo _ = error "liftToInfo: wrong list length"

-- | Reason for terminating.
data StopReason
  = SmallGradient  -- ^ Stopped because of small gradient @J^T e@.
  | SmallDp        -- ^ Stopped because of small Dp.
  | MaxIterations  -- ^ Stopped because maximum iterations was reached.
  | SingularMatrix -- ^ Stopped because of singular matrix. Restart from current
                   --   estimated parameters with increased 'optScaleInitMu'.
  | SmallestError  -- ^ Stopped because no further error reduction is
                   --   possible. Restart with increased 'optScaleInitMu'.
  | SmallNorm2E    -- ^ Stopped because of small @||e||_2@.
  | InvalidValues  -- ^ Stopped because model function returned invalid values
                   --   (i.e. NaN or Inf). This is a user error.
    deriving (Read, Show, Enum)

-- | Covariance matrix corresponding to LS solution.
type CovarMatrix r = [[r]]


--------------------------------------------------------------------------------
-- Error
--------------------------------------------------------------------------------

data LevMarError
    = LevMarError                    -- ^ Generic error (not one of the others)
    | LapackError                    -- ^ A call to a lapack subroutine failed
                                     --   in the underlying C levmar library.
    | FailedBoxCheck                 -- ^ At least one lower bound exceeds the
                                     --   upper one.
    | MemoryAllocationFailure        -- ^ A call to @malloc@ failed in the
                                     --   underlying C levmar library.
    | ConstraintMatrixRowsGtCols     -- ^ The matrix of constraints cannot have
                                     --   more rows than columns.
    | ConstraintMatrixNotFullRowRank -- ^ Constraints matrix is not of full row
                                     --   rank.
    | TooFewMeasurements             -- ^ Cannot solve a problem with fewer
                                     --   measurements than unknowns.  In case
                                     --   linear constraints are provided, this
                                     --   error is also returned when the number
                                     --   of measurements is smaller than the
                                     --   number of unknowns minus the number of
                                     --   equality constraints.
      deriving (Show, Typeable)

-- Handy in case you want to thow a LevMarError as an exception:
instance Exception LevMarError

levmarCErrorToLevMarError ∷ [(CInt, LevMarError)]
levmarCErrorToLevMarError =
    [ (BLM.c'LM_ERROR,                                     LevMarError)
    , (BLM.c'LM_ERROR_LAPACK_ERROR,                        LapackError)
  --, (BLM.c'LM_ERROR_NO_JACOBIAN,                         can never happen)
  --, (BLM.c'LM_ERROR_NO_BOX_CONSTRAINTS,                  can never happen)
    , (BLM.c'LM_ERROR_FAILED_BOX_CHECK,                    FailedBoxCheck)
    , (BLM.c'LM_ERROR_MEMORY_ALLOCATION_FAILURE,           MemoryAllocationFailure)
    , (BLM.c'LM_ERROR_CONSTRAINT_MATRIX_ROWS_GT_COLS,      ConstraintMatrixRowsGtCols)
    , (BLM.c'LM_ERROR_CONSTRAINT_MATRIX_NOT_FULL_ROW_RANK, ConstraintMatrixNotFullRowRank)
    , (BLM.c'LM_ERROR_TOO_FEW_MEASUREMENTS,                TooFewMeasurements)
  --, (BLM.c'LM_ERROR_SINGULAR_MATRIX,                     we don't treat this as an error)
  --, (BLM.c'LM_ERROR_SUM_OF_SQUARES_NOT_FINITE,           we don't treat this as an error)
    ]

convertLevMarError ∷ CInt → LevMarError
convertLevMarError err = fromMaybe (error "Unknown levmar error") $
                         lookup err levmarCErrorToLevMarError


-- The End ---------------------------------------------------------------------