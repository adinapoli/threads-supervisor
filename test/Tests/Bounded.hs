{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Tests.Bounded where

import           Test.Tasty.HUnit as HUnit
import           Test.Tasty.QuickCheck
import           Test.QuickCheck.Monadic as QM
import qualified Data.List as List
import           Control.Monad
import           Control.Retry
import           Control.Monad.Trans.Class
import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Concurrent.Supervisor.Bounded

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
qToList :: TBQueue SupervisionEvent -> IO [SupervisionEvent]
qToList q = do
  nextEl <- atomically (tryReadTBQueue q)
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
assertContainsNRestartMsg :: Int -> [SupervisionEvent] -> IOProperty ()
assertContainsNRestartMsg n e = lift $ assertContainsNMsg matches n e
  where
    matches (ChildRestarted{}) = True
    matches _ = False

--------------------------------------------------------------------------------
assertContainsNFinishedMsg :: Int -> [SupervisionEvent] -> IOProperty ()
assertContainsNFinishedMsg n e = lift $ assertContainsNMsg matches n e
  where
    matches (ChildFinished{}) = True
    matches _ = False

--------------------------------------------------------------------------------
assertContainsNLimitReached :: Int -> [SupervisionEvent] -> IO ()
assertContainsNLimitReached = assertContainsNMsg matches
  where
    matches (ChildRestartLimitReached{}) = True
    matches _ = False

--------------------------------------------------------------------------------
assertContainsRestartMsg :: [SupervisionEvent] -> ThreadId -> IOProperty ()
assertContainsRestartMsg [] _ = QM.assert False
assertContainsRestartMsg (x:xs) tid = case x of
  ((ChildRestarted old _ _ _)) ->
    if old == tid then QM.assert True else assertContainsRestartMsg xs tid
  _ -> assertContainsRestartMsg xs tid

--------------------------------------------------------------------------------
-- Control.Concurrent.Supervisor tests
test1SupThreadNoEx :: IOProperty ()
test1SupThreadNoEx = forAllM randomLiveTime $ \ttl -> do
  supSpec <- lift newSupervisorSpec
  sup <- lift $ newSupervisor supSpec
  _ <- lift (forkSupervised sup oneForOne (forever $ threadDelay ttl))
  assertActiveThreads sup (== 1)
  lift $ shutdownSupervisor sup

--------------------------------------------------------------------------------
test1SupThreadPrematureDemise :: IOProperty ()
test1SupThreadPrematureDemise = forAllM randomLiveTime $ \ttl -> do
  supSpec <- lift newSupervisorSpec
  sup <- lift $ newSupervisor supSpec
  tid <- lift (forkSupervised sup oneForOne (forever $ threadDelay ttl))
  lift $ do
    throwTo tid (AssertionFailed "You must die")
    threadDelay ttl --give time to restart the thread
  assertActiveThreads sup (== 1)
  q <- lift $ qToList (eventStream sup)
  assertContainsNRestartMsg 1 q
  lift $ shutdownSupervisor sup

--------------------------------------------------------------------------------
fromAction :: Supervisor -> ThreadAction -> IO ThreadId
fromAction s Live = forkSupervised s oneForOne (forever $ threadDelay 100000000)
fromAction s (DieAfter (TTL ttl)) = forkSupervised s oneForOne (threadDelay ttl)
fromAction s (ThrowAfter (TTL ttl)) = forkSupervised s oneForOne (do
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
  supSpec <- lift newSupervisorSpec
  sup <- lift $ newSupervisor supSpec
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
  supSpec <- lift newSupervisorSpec
  sup <- lift $ newSupervisor supSpec
  _ <- forM acts $ lift . fromAction sup
  lift (threadDelay $ maxWait acts * 2)
  q <- lift $ qToList (eventStream sup)
  assertActiveThreads sup (== 0)
  assertContainsNFinishedMsg (length acts) q
  lift $ shutdownSupervisor sup

testTooManyRestarts :: Assertion
testTooManyRestarts = do
  supSpec <- newSupervisorSpec
  sup <- newSupervisor supSpec
  _ <- forkSupervised sup (OneForOne defaultRetryStatus $ limitRetries 5) $ error "die"
  threadDelay 2000000
  q <- qToList (eventStream sup)
  assertContainsNLimitReached 1 q
  shutdownSupervisor sup
