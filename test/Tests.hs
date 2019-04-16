{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Tests where

import           Test.Tasty.HUnit as HUnit
import           Test.Tasty.QuickCheck
import           Test.QuickCheck.Monadic as QM
import qualified Data.List as List
import           Control.Monad
import           Control.Retry
import           Control.Monad.Trans.Class
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Concurrent.Supervisor as Supervisor

--------------------------------------------------------------------------------
type IOProperty = PropertyM IO

-- How much a thread will live.
newtype TTL = TTL Int deriving Show

-- | Generate a random thread live time between 0.5 sec and 2 secs.
randomLiveTime :: Gen Int
randomLiveTime = choose (500000, 2000000)

instance Arbitrary TTL where
  arbitrary = TTL <$> randomLiveTime

data ThreadAction =
    Live
  | DieAfter TTL --natural death
  | ThrowAfter TTL
  deriving Show

instance Arbitrary ThreadAction where
  arbitrary = do
    act <- elements [const Live, DieAfter, ThrowAfter]
    ttl <- arbitrary
    return $ act ttl

-- We cannot easily deal with async exceptions
-- being thrown at us.
data ExecutionPlan = ExecutionPlan {
    toSpawn :: Int
  , actions :: [ThreadAction]
  } deriving Show

instance Arbitrary ExecutionPlan where
  arbitrary = do
    ts <- choose (1,20)
    acts <- vectorOf ts arbitrary
    return $ ExecutionPlan ts acts

--------------------------------------------------------------------------------
howManyRestarted :: ExecutionPlan -> Int
howManyRestarted (ExecutionPlan _ acts) = length . filter pred_ $ acts
  where
    pred_ (ThrowAfter _) = True
    pred_ _ = False

--------------------------------------------------------------------------------
howManyLiving :: ExecutionPlan -> Int
howManyLiving (ExecutionPlan _ acts) = length . filter pred_ $ acts
  where
    pred_ Live = True
    pred_ _ = False

--------------------------------------------------------------------------------
assertActiveThreads :: Supervisor -> (Int -> Bool) -> IOProperty ()
assertActiveThreads sup p = do
  ac <- lift (activeChildren sup)
  QM.assert (p ac)

--------------------------------------------------------------------------------
qToList :: TQueue SupervisionEvent -> IO [SupervisionEvent]
qToList q = do
  nextEl <- atomically (tryReadTQueue q)
  case nextEl of
    (Just el) -> (el :) <$> qToList q
    Nothing -> return []

--------------------------------------------------------------------------------
assertContainsNMsg :: (SupervisionEvent -> Bool)
                   -> Int
                   -> [SupervisionEvent]
                   -> IO ()
assertContainsNMsg _ 0 _ = HUnit.assertBool "" True
assertContainsNMsg _ x [] = do
  HUnit.assertBool ("assertContainsNMsg: list exhausted and " ++ show x ++ " left.") False
assertContainsNMsg matcher !n (x:xs) = case matcher x of
  True  -> assertContainsNMsg matcher (n - 1) xs
  False -> assertContainsNMsg matcher n xs

--------------------------------------------------------------------------------
assertContainsNDiedMsg :: Int -> [SupervisionEvent] -> IOProperty ()
assertContainsNDiedMsg n e = lift $ assertContainsNMsg matches n e
  where
    matches ChildDied{} = True
    matches _ = False

--------------------------------------------------------------------------------
assertContainsNRestartMsg :: Int -> [SupervisionEvent] -> IOProperty ()
assertContainsNRestartMsg n e = lift $ assertContainsNMsg matches n e
  where
    matches ChildRestarted{} = True
    matches _ = False

--------------------------------------------------------------------------------
assertContainsNFinishedMsg :: Int -> [SupervisionEvent] -> IOProperty ()
assertContainsNFinishedMsg n e = lift $ assertContainsNMsg matches n e
  where
    matches ChildFinished{} = True
    matches _ = False

--------------------------------------------------------------------------------
assertContainsNLimitReached :: Int -> [SupervisionEvent] -> IO ()
assertContainsNLimitReached = assertContainsNMsg matches
  where
    matches ChildRestartLimitReached{} = True
    matches _ = False

--------------------------------------------------------------------------------
assertContainsRestartMsg :: [SupervisionEvent] -> ThreadId -> IOProperty ()
assertContainsRestartMsg [] _ = QM.assert False
assertContainsRestartMsg (x:xs) tid = case x of
  (ChildRestarted old _ _ _) ->
    if old == tid then QM.assert True else assertContainsRestartMsg xs tid
  _ -> assertContainsRestartMsg xs tid

--------------------------------------------------------------------------------
testShowInstancesLaws :: Assertion
testShowInstancesLaws = do
  let l = LetterEpoch 0
  let c = ChildEpoch  0
  HUnit.assert (show l == "LetterEpoch 0s")
  HUnit.assert (show c == "ChildEpoch 0s")

--------------------------------------------------------------------------------
-- Control.Concurrent.Supervisor tests
test1SupThreadNoEx :: IOProperty ()
test1SupThreadNoEx = forAllM randomLiveTime $ \ttl -> do
  sup <- lift $ newSupervisor OneForOne
  _ <- lift (forkSupervised sup fibonacciRetryPolicy (forever $ threadDelay ttl))
  assertActiveThreads sup (== 1)
  lift $ shutdownSupervisor sup

--------------------------------------------------------------------------------
test1SupThreadPrematureAsyncDemise :: IOProperty ()
test1SupThreadPrematureAsyncDemise = forAllM randomLiveTime $ \ttl -> do
  sup <- lift $ newSupervisor OneForOne
  tid <- lift (forkSupervised sup fibonacciRetryPolicy (forever $ threadDelay ttl))
  lift $ do
    throwTo tid ThreadKilled
    threadDelay ttl
  -- Due to the fact an `AsyncException` was thrown, the thread shouldn't have been
  -- restarted.
  assertActiveThreads sup (== 0)
  q <- lift $ qToList (eventStream sup)
  assertContainsNRestartMsg 0 q
  assertContainsNDiedMsg 1 q
  lift $ shutdownSupervisor sup

--------------------------------------------------------------------------------
test1SupThreadPrematureDemise :: IOProperty ()
test1SupThreadPrematureDemise = forAllM randomLiveTime $ \ttl -> do
  sup <- lift $ newSupervisor OneForOne
  tid <- lift (forkSupervised sup fibonacciRetryPolicy (forever $ threadDelay ttl))
  lift $ do
    throwTo tid (AssertionFailed "You must die")
    threadDelay ttl --give time to restart the thread
  assertActiveThreads sup (== 1)
  q <- lift $ qToList (eventStream sup)
  assertContainsNRestartMsg 1 q
  lift $ shutdownSupervisor sup

--------------------------------------------------------------------------------
test1SupSpvrPrematureDemise :: IOProperty ()
test1SupSpvrPrematureDemise = forAllM randomLiveTime $ \ttl -> do
  sup1 <- lift $ newSupervisor OneForOne
  sup2 <- lift $ newSupervisor OneForOne
  tid <- lift  $ Supervisor.monitorWith fibonacciRetryPolicy sup1 sup2
  lift $ do
    throwTo tid (AssertionFailed "You must die")
    threadDelay ttl --give time to restart the thread
  assertActiveThreads sup1 (== 1)
  q <- lift $ qToList (eventStream sup1)
  assertContainsNRestartMsg 1 q
  lift $ shutdownSupervisor sup1
  -- TODO: Assert sup2 has been shutdown as result.

--------------------------------------------------------------------------------
test1SupSpvrDouble :: IOProperty ()
test1SupSpvrDouble = forAllM randomLiveTime $ \ttl -> do
  sup1 <- lift $ newSupervisor OneForOne
  sup2 <- lift $ newSupervisor OneForOne
  sup3 <- lift $ newSupervisor OneForOne
  tid  <- lift  $ Supervisor.monitorWith fibonacciRetryPolicy sup1 sup2
  tid2 <- lift  $ Supervisor.monitorWith fibonacciRetryPolicy sup3 sup2
  QM.assert (tid == tid2)
  lift $ do
    throwTo tid (AssertionFailed "You must die")
    threadDelay ttl --give time to restart the thread
  assertActiveThreads sup1 (== 1)
  q <- lift $ qToList (eventStream sup1)
  assertContainsNRestartMsg 1 q
  lift $ shutdownSupervisor sup1
  -- TODO: Assert sup2 has been shutdown as result.

--------------------------------------------------------------------------------
fromAction :: Supervisor -> ThreadAction -> IO ThreadId
fromAction s Live = forkSupervised s fibonacciRetryPolicy (forever $ threadDelay 100000000)
fromAction s (DieAfter (TTL ttl)) = forkSupervised s fibonacciRetryPolicy (threadDelay ttl)
fromAction s (ThrowAfter (TTL ttl)) = forkSupervised s fibonacciRetryPolicy (do
  threadDelay ttl
  throwIO $ AssertionFailed "die")

--------------------------------------------------------------------------------
maxWait :: [ThreadAction] -> Int
maxWait ta = go ta []
  where
    go [] [] = 0
    go [] acc = List.maximum acc
    go (Live:xs) acc = go xs acc
    go ((DieAfter (TTL t)):xs) acc = go xs (t : acc)
    go ((ThrowAfter (TTL t)):xs) acc = go xs (t : acc)

--------------------------------------------------------------------------------
-- In this test, we generate random IO actions for the threads to be
-- executed, then we calculate how many of them needs to be alive after all
-- the side effects strikes.
testKillingSpree :: IOProperty ()
testKillingSpree = forAllM arbitrary $ \ep@(ExecutionPlan _ acts) -> do
  sup <- lift $ newSupervisor OneForOne
  _ <- forM acts $ lift . fromAction sup
  lift (threadDelay $ maxWait acts * 2)
  q <- lift $ qToList (eventStream sup)
  assertActiveThreads sup (>= howManyLiving ep)
  assertContainsNRestartMsg (howManyRestarted ep) q
  lift $ shutdownSupervisor sup

--------------------------------------------------------------------------------
-- In this test, we test that the supervisor does not leak memory by removing
-- children who finished
testSupCleanup :: IOProperty ()
testSupCleanup = forAllM (vectorOf 100 arbitrary) $ \ttls -> do
  let acts = map DieAfter ttls
  sup <- lift $ newSupervisor OneForOne
  _ <- forM acts $ lift . fromAction sup
  lift (threadDelay $ maxWait acts * 2)
  q <- lift $ qToList (eventStream sup)
  assertActiveThreads sup (== 0)
  assertContainsNFinishedMsg (length acts) q
  lift $ shutdownSupervisor sup

testTooManyRestarts :: Assertion
testTooManyRestarts = do
  sup <- newSupervisor OneForOne
  _ <- forkSupervised sup (limitRetries 5) $ error "die"
  threadDelay 2000000
  q <- qToList (eventStream sup)
  assertContainsNLimitReached 1 q
  shutdownSupervisor sup
