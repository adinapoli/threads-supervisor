{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Tests where

import           Test.Tasty.HUnit as HUnit
import           Test.Tasty.QuickCheck
import           Test.Tasty.Hspec
import           Test.QuickCheck.Monadic as QM
import           Data.Configurator
import           Data.Configurator.Types
import           Network.HTTP.Conduit
import           Control.Monad
import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Concurrent.Supervisor
import           Data.Time
import qualified Data.List as List
import           Data.Serialize
import           Hermes.Server.Types
import           Hermes.Server.RuleEngine
import           Hermes.Types
import           Atlas.Types.Model hiding (void)
import           Atlas.MediaKey
import           Atlas.Hermes
import qualified Hermes.Server.API as API
import qualified Data.Aeson as JSON

import           Request
import           Expectation


--------------------------------------------------------------------------------
withDevelConfig :: (Config -> Assertion) -> Assertion
withDevelConfig f = do
  snapletConfig <- load [Required "snaplets/hermes/devel.cfg"]
  addToConfig [Required "devel.cfg"] snapletConfig
  f snapletConfig


--------------------------------------------------------------------------------
testServerInfo :: Assertion
testServerInfo = withDevelConfig $ \cfg -> do
  endpoint <- API.healthCheckEp cfg
  void $ simpleHttp endpoint


--------------------------------------------------------------------------------
withPositiveIds :: VideoMediaKey -> Bool
withPositiveIds VideoMediaKey{..} =
  (_VideoID . sva_video $ vmk_attribs) >= 0 &&
  (_UserID  . sva_user  $ vmk_attribs) >= 0


--------------------------------------------------------------------------------
testHermesCallbackSerialisation :: Property
testHermesCallbackSerialisation =
  forAll arbitrary $ \(clb :: HermesCallback) -> decode (encode clb) == Right clb


--------------------------------------------------------------------------------
testRetryWindowSerialisation :: Property
testRetryWindowSerialisation =
  forAll arbitrary $ \(win :: RetryWindow) -> decode (encode win) == Right win


--------------------------------------------------------------------------------
testPendingJobSerialisation :: Property
testPendingJobSerialisation =
  forAll arbitrary $ \(job@(PendingJob vmk _ _ _)) ->
    withPositiveIds vmk ==> decode (encode job) == Right job


--------------------------------------------------------------------------------
testAtlasNotificationSerialisation :: Property
testAtlasNotificationSerialisation =
  forAll arbitrary $ \(ntf@(AtlasNotification pnot _)) ->
    let (PendingNotification _ vmk _) = pnot
    in withPositiveIds vmk ==> decode (encode ntf) == Right ntf


--------------------------------------------------------------------------------
testUTCTimeSerialisation :: Property
testUTCTimeSerialisation =
  forAll arbitrary $ \(time :: UTCTime) ->
    decode (encode time) == Right time


--------------------------------------------------------------------------------
testDatabaseInstanceSerialisation :: Property
testDatabaseInstanceSerialisation =
  forAll arbitrary $ \(dbi :: DatabaseInstance) ->
    decode (encode dbi) == Right dbi


--------------------------------------------------------------------------------
testJobRuleSerialisation :: Property
testJobRuleSerialisation =
  forAll arbitrary $ \(jobRule :: JobRule) ->
    decode (encode jobRule) == Right jobRule


--------------------------------------------------------------------------------
testJobRuleJSON :: Property
testJobRuleJSON =
  forAll arbitrary $ \(jobRule :: JobRule) ->
    JSON.decode (JSON.encode jobRule) == Just jobRule


--------------------------------------------------------------------------------
testAcceptNewUploadGET :: Assertion
testAcceptNewUploadGET = withDevelConfig $ \cfg -> newGETUpload cfg >>= doReq_


--------------------------------------------------------------------------------
testAcceptNewUploadPOST :: IO (MVar ()) -> Assertion
testAcceptNewUploadPOST syncMVar = withDevelConfig $ \cfg -> do
  ServerMockRequest mockRq <- newPOSTUpload cfg
  void $ withManager $ httpLbs mockRq
  takeMVar =<< syncMVar

--------------------------------------------------------------------------------
testAcceptNewTranscodeLaterGET :: Assertion
testAcceptNewTranscodeLaterGET = withDevelConfig $ \cfg -> do
  ServerMockRequest mockRq <- newGETTranscodeLater cfg
  void $ withManager $ httpLbs mockRq


--------------------------------------------------------------------------------
testAcceptNewTranscodeLaterPOST :: IO (MVar ()) -> Assertion
testAcceptNewTranscodeLaterPOST syncMVar = withDevelConfig $ \cfg -> do
  ServerMockRequest mockRq <- newPOSTTranscodeLater cfg
  void $ withManager $ httpLbs mockRq
  takeMVar =<< syncMVar

--------------------------------------------------------------------------------
testAcceptNewDiscoKitGET :: Assertion
testAcceptNewDiscoKitGET = withDevelConfig $ \cfg -> do
  ServerMockRequest mockRq <- newGETDiscoveryKit cfg
  void $ withManager $ httpLbs mockRq


--------------------------------------------------------------------------------
testAcceptNewDiscoKitPOST :: IO (MVar ()) -> Assertion
testAcceptNewDiscoKitPOST syncMVar = withDevelConfig $ \cfg -> do
  ServerMockRequest mockRq <- newPOSTDiscoveryKit cfg
  void $ withManager $ httpLbs mockRq
  takeMVar =<< syncMVar


--------------------------------------------------------------------------------
ruleEngineHandlersSpec :: Spec
ruleEngineHandlersSpec = do
  describe "The RuleEngine Handlers" $ do
    testRuleEngineGET
    testRuleEnginePOST
    testRuleEngineDELETE


--------------------------------------------------------------------------------
testRuleEngineGET :: Spec
testRuleEngineGET = it "should list all rules" $ do
  withDevelConfig $ \cfg -> do
    res <- newGETRules cfg >>= doReq
    res `shouldHaveStatusCode` 200


--------------------------------------------------------------------------------
testRuleEnginePOST :: Spec
testRuleEnginePOST = it "should insert a new rule into the system" $ do
  withDevelConfig $ \cfg -> do
    let exampleRule = HasComment "foobar"
    res <- newPOSTRules cfg exampleRule >>= doReq
    res `shouldHaveStatusCode` 200


--------------------------------------------------------------------------------
testRuleEngineDELETE :: Spec
testRuleEngineDELETE = it "should delete a rule even if not there" $ do
  withDevelConfig $ \cfg -> do
    let exampleRule = HasComment "foobar"
    res <- newDELETERules cfg exampleRule >>= doReq
    res `shouldHaveStatusCode` 200

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
                   -> IOProperty ()
assertContainsNMsg _ 0 _ = QM.assert True
assertContainsNMsg _ x [] = lift $
  HUnit.assertBool ("assertContainsNMsg: list exhausted and " ++ show x ++ " left.") False
assertContainsNMsg matcher !n (x:xs) = case matcher x of
  True  -> assertContainsNMsg matcher (n - 1) xs
  False -> assertContainsNMsg matcher n xs

--------------------------------------------------------------------------------
assertContainsNRestartMsg :: Int -> [SupervisionEvent] -> IOProperty ()
assertContainsNRestartMsg = assertContainsNMsg matches
  where
    matches (ChildRestarted{}) = True
    matches _ = False

--------------------------------------------------------------------------------
assertContainsNFinishedMsg :: Int -> [SupervisionEvent] -> IOProperty ()
assertContainsNFinishedMsg = assertContainsNMsg matches
  where
    matches (ChildFinished{}) = True
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
  supSpec <- lift newSupervisor
  sup <- lift $ supervise supSpec
  _ <- lift (forkSupervised sup OneForOne (forever $ threadDelay ttl))
  assertActiveThreads sup (== 1)
  lift $ shutdownSupervisor sup

--------------------------------------------------------------------------------
test1SupThreadPrematureDemise :: IOProperty ()
test1SupThreadPrematureDemise = forAllM randomLiveTime $ \ttl -> do
  supSpec <- lift newSupervisor
  sup <- lift $ supervise supSpec
  tid <- lift (forkSupervised sup OneForOne (forever $ threadDelay ttl))
  lift $ do
    throwTo tid (AssertionFailed "You must die")
    threadDelay ttl --give time to restart the thread
  assertActiveThreads sup (== 1)
  q <- lift $ qToList (eventStream sup)
  assertContainsNRestartMsg 1 q
  lift $ shutdownSupervisor sup

--------------------------------------------------------------------------------
fromAction :: Supervisor -> ThreadAction -> IO ThreadId
fromAction s Live = forkSupervised s OneForOne (forever $ threadDelay 100000000)
fromAction s (DieAfter (TTL ttl)) = forkSupervised s OneForOne (threadDelay ttl)
fromAction s (ThrowAfter (TTL ttl)) = forkSupervised s OneForOne (do
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
  supSpec <- lift newSupervisor
  sup <- lift $ supervise supSpec
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
  supSpec <- lift newSupervisor
  sup <- lift $ supervise supSpec
  _ <- forM acts $ lift . fromAction sup
  lift (threadDelay $ maxWait acts * 2)
  q <- lift $ qToList (eventStream sup)
  assertActiveThreads sup (== 0)
  assertContainsNFinishedMsg (length acts) q
  lift $ shutdownSupervisor sup
