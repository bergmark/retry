{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE ViewPatterns          #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Retry
-- Copyright   :  Ozgun Ataman <ozgun.ataman@soostone.com>
-- License     :  BSD3
--
-- Maintainer  :  Ozgun Ataman
-- Stability   :  provisional
--
-- This module exposes combinators that can wrap arbitrary monadic
-- actions. They run the action and potentially retry running it with
-- some configurable delay for a configurable number of times.
--
-- The express purpose of this library is to make it easier to work
-- with IO and especially network IO actions that often experience
-- temporary failure that warrant retrying of the original action. For
-- example, a database query may time out for a while, in which case
-- we should delay a bit and retry the query.
----------------------------------------------------------------------------


module Control.Retry
    (
      -- * High Level Operation
      RetryPolicy (..)

    , retrying
    , recovering
    , recoverAll
    , logRetries

    -- * Retry Policies
    , constantDelay
    , exponentialBackoff
    , fibonacciBackoff
    , limitRetries
    , limitRetriesByDelay
    , capDelay

    -- * Re-export from Data.Monoid

    , (<>)

    ) where

-------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Data.Default.Class
import           Data.Monoid
import           Prelude                hiding (catch)
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- | A 'RetryPolicy' is a function that takes an iteration number and
-- possibly returns a delay in microseconds. *Nothing* implies we have
-- reached the retry limit.
--
-- Please note that 'RetryPolicy' is a 'Monoid'. You can collapse
-- multiple strategies into one using 'mappend' or '<>'. The semantics
-- of this combination are as follows:
--
-- 1. If either policy returns 'Nothing', the combined policy returns
-- 'Nothing'. This can be used to @inhibit@ after a number of retries,
-- for example.
--
-- 2. If both policies return a delay, the larger delay will be used.
-- This is quite natural when combining multiple policies to achieve a
-- certain effect.
--
-- Example:
--
-- One can easily define an exponential backoff policy with a limited
-- number of retries:
--
-- >> limitedBackoff = exponentialBackoff 50 <> limitRetries 5
--
-- Naturally, 'mempty' will retry immediately (delay 0) for an
-- unlimited number of retries, forming the identity for the 'Monoid'.
--
-- The default under 'def' implements a constant 50ms delay, up to 5 times:
--
-- >> def = constantDelay 50000 <> limitRetries 5
--
-- For anything more complex, just define your own 'RetryPolicy':
--
-- >> myPolicy = RetryPolicy $ \ n -> if n > 10 then Just 1000 else Just 10000
newtype RetryPolicy = RetryPolicy { getRetryPolicy :: Int -> Maybe Int }


instance Default RetryPolicy where
    def = constantDelay 50000 <> limitRetries 5

instance Monoid RetryPolicy where
    mempty = RetryPolicy $ (const (Just 0))
    (RetryPolicy a) `mappend` (RetryPolicy b) = RetryPolicy $ \ n -> do
      a' <- a n
      b' <- b n
      return $! max a' b'


-------------------------------------------------------------------------------
-- | Retry immediately, but only up to @n@ times.
limitRetries
    :: Int
    -- ^ Maximum number of retries.
    -> RetryPolicy
limitRetries i = RetryPolicy $ \ n -> if n >= i then Nothing else (Just 0)


-------------------------------------------------------------------------------
-- | Add an upperbound to a policy such that once the given time-delay
-- amount has been reached or exceeded, the policy will stop retrying
-- and fail.
limitRetriesByDelay
    :: Int
    -- ^ Time-delay limit in microseconds. 
    -> RetryPolicy
    -> RetryPolicy
limitRetriesByDelay i p = RetryPolicy $ \ n -> getRetryPolicy p n >>= limit
  where
    limit delay = if delay >= i then Nothing else Just delay


-------------------------------------------------------------------------------
-- | Implement a constant delay with unlimited retries.
constantDelay
    :: Int
    -- ^ Base delay in microseconds
    -> RetryPolicy
constantDelay delay = RetryPolicy (const (Just delay))


-------------------------------------------------------------------------------
-- | Grow delay exponentially each iteration.
exponentialBackoff
    :: Int
    -- ^ Base delay in microseconds
    -> RetryPolicy
exponentialBackoff base = RetryPolicy $ \ n -> Just (2^n * base)


-------------------------------------------------------------------------------
-- | Implement Fibonacci backoff.
fibonacciBackoff
    :: Int
    -- ^ Base delay in microseconds
    -> RetryPolicy
fibonacciBackoff base = RetryPolicy $ \ n -> Just $ fib (n + 1) (0, base)
    where
      fib 0 (a, _) = a
      fib !m (!a, !b) = fib (m-1) (b, a + b)


-------------------------------------------------------------------------------
-- | Set a time-upperbound for any delays that may be directed by the
-- given policy.  This function does not terminate the retrying.  The policy
-- `capDelay maxDelay (exponentialBackoff n)` will never stop retrying.  It
-- will reach a state where it retries forever with a delay of `maxDelay`
-- between each one.  To get termination you need to use one of the
-- 'limitRetries' function variants.
capDelay
    :: Int
    -- ^ A maximum delay in microseconds
    -> RetryPolicy
    -> RetryPolicy
capDelay limit p = RetryPolicy $ \ n -> min limit `fmap` (getRetryPolicy p) n


-------------------------------------------------------------------------------
-- | Retry combinator for actions that don't raise exceptions, but
-- signal in their type the outcome has failed. Examples are the
-- 'Maybe', 'Either' and 'EitherT' monads.
--
-- Let's write a function that always fails and watch this combinator
-- retry it 5 additional times following the initial run:
--
-- >>> import Data.Maybe
-- >>> let f = putStrLn "Running action" >> return Nothing
-- >>> retrying def (const $ return . isNothing) f
-- Running action
-- Running action
-- Running action
-- Running action
-- Running action
-- Running action
-- Nothing
--
-- Note how the latest failing result is returned after all retries
-- have been exhausted.
retrying :: MonadIO m
         => RetryPolicy
         -> (Int -> b -> m Bool)
         -- ^ An action to check whether the result should be retried.
         -- If True, we delay and retry the operation.
         -> m b
         -- ^ Action to run
         -> m b
retrying (RetryPolicy policy) chk f = go 0
    where
      go n = do
          res <- f
          chk' <- chk n res
          case chk' of
            True ->
              case (policy n) of
                Just delay -> do
                  liftIO (threadDelay delay)
                  go $! n+1
                Nothing -> return res
            False -> return res



-------------------------------------------------------------------------------
-- | Retry ALL exceptions that may be raised. To be used with caution;
-- this matches the exception on 'SomeException'.
--
-- See how the action below is run once and retried 5 more times
-- before finally failing for good:
--
-- >>> let f = putStrLn "Running action" >> error "this is an error"
-- >>> recoverAll def f
-- Running action
-- Running action
-- Running action
-- Running action
-- Running action
-- Running action
-- *** Exception: this is an error
recoverAll
#if MIN_VERSION_exceptions(0, 6, 0)
         :: (MonadIO m, MonadMask m)
#else
         :: (MonadIO m, MonadCatch m)
#endif
         => RetryPolicy
         -> m a
         -> m a
recoverAll set f = recovering set [h] f
    where
      h _ = Handler $ \ (_ :: SomeException) -> return True


-------------------------------------------------------------------------------
-- | Run an action and recover from a raised exception by potentially
-- retrying the action a number of times.
recovering
#if MIN_VERSION_exceptions(0, 6, 0)
           :: (MonadIO m, MonadMask m)
#else
           :: (MonadIO m, MonadCatch m)
#endif
           => RetryPolicy
           -- ^ Just use 'def' for default settings
           -> [(Int -> Handler m Bool)]
           -- ^ Should a given exception be retried? Action will be
           -- retried if this returns True.
           -> m a
           -- ^ Action to perform
           -> m a
recovering (RetryPolicy policy) hs f = mask $ \restore -> go restore 0
    where
      go restore = loop
        where
          loop n = do
            r <- try $ restore f
            case r of
              Right x -> return x
              Left e -> recover (e :: SomeException) hs
            where
              recover e [] = throwM e
              recover e ((($ n) -> Handler h) : hs')
                | Just e' <- fromException e = do
                    chk <- h e'
                    if chk
                      then case policy n of
                        Just delay -> do
                          liftIO $ threadDelay delay
                          loop $! n+1
                        Nothing -> throwM e'
                      else throwM e'
                | otherwise = recover e hs'


-------------------------------------------------------------------------------
-- | Helper function for constructing handler functions of the form required
-- by 'recovering'.
logRetries
    :: (Monad m, Show e, Exception e)
    => (e -> m Bool)
    -- ^ Test for whether action is to be retried
    -> (String -> m ())
    -- ^ How to report the generated warning message.
    -> Int
    -- ^ Retry number
    -> Handler m Bool
logRetries f report n = Handler $ \ e -> do
    res <- f e
    let msg = "[retry:" <> show n <> "] Encountered " <> show e <> ". " <>
              if res then "Retrying." else "Crashing."
    report msg
    return res


                              ------------------
                              -- Simple Tests --
                              ------------------



-- data TestException = TestException deriving (Show, Typeable)
-- data AnotherException = AnotherException deriving (Show, Typeable)

-- instance Exception TestException
-- instance Exception AnotherException


-- test = retrying def [h1,h2] f
--     where
--       f = putStrLn "Running action" >> throwM AnotherException
--       h1 = Handler $ \ (e :: TestException) -> return False
--       h2 = Handler $ \ (e :: AnotherException) -> return True
