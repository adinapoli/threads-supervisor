{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Test.Tasty
import           Test.Tasty.Runners
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
import           Test.Tasty.Ingredients.Rerun
import qualified Test.Tasty.Hspec as Spec
import           Test.QuickCheck.Monadic
import           Tests
import           Shelly
import           Hermes.Utils
import           Control.Concurrent
import           Snap
import           StatsSpec
import           Database.PostgreSQL.Simple


localDb :: ConnectInfo
localDb = defaultConnectInfo { connectDatabase = "hermes_stats" }


--------------------------------------------------------------------------------
main :: IO ()
main = do
  conn <- connect localDb
  specs <- Spec.testSpec "RuleEngine" ruleEngineHandlersSpec
  sqlSpecs <- Spec.testSpec "Stats" (statsSpecs conn)
  defaultMainWithIngredients
    [ rerunningTests [ listingTests, consoleTestReporter ] ]
    (allTests specs sqlSpecs)


--------------------------------------------------------------------------------
-- Will handle /callback
handleCallback :: MVar () -> Snap ()
handleCallback mvar = liftIO $ putMVar mvar ()


--------------------------------------------------------------------------------
spawnServer :: IO (ThreadId, MVar ())
spawnServer = do
  -- We create an MVar which will be used as a sync mechanism
  -- between client and server.
  syncMVar <- newEmptyMVar
  -- Spawn a dead-simple server which will wait on "/callback"
  tid <- forkIO $ httpServe (setVerbose False $
                             setErrorLog ConfigNoLog $
                             setAccessLog ConfigNoLog $
                             setPort 9938 defaultConfig) $
                  route [("/callback", handleCallback syncMVar)]
  return (tid, syncMVar)


--------------------------------------------------------------------------------
withQuickCheckDepth :: TestName -> Int -> [TestTree] -> TestTree
withQuickCheckDepth tn depth tests =
  localOption (QuickCheckTests depth) (testGroup tn tests)


--------------------------------------------------------------------------------
allTests :: TestTree -> TestTree -> TestTree
allTests specs statsSpecs = withResource spawnServer (killThread . fst) $ \res ->
  testGroup "hermes server tests" [
      testCase "Server is responding on /server-info" testServerInfo
    , withQuickCheckDepth "Control.Concurrent.Supervisor" 10 [
        testProperty "1 supervised thread, no exceptions" (monadicIO test1SupThreadNoEx)
      , testProperty "1 supervised thread, premature exception" (monadicIO test1SupThreadPrematureDemise)
      , testProperty "killing spree" (monadicIO testKillingSpree)
      , testProperty "cleanup" (monadicIO testSupCleanup)
      ]
    , withQuickCheckDepth "Serialisation properties" 10000 [
        testProperty "Server can serialise/deserialise RetryWindow" testRetryWindowSerialisation
      , testProperty "Server can serialise/deserialise HermesCallback" testHermesCallbackSerialisation
      , testProperty "Server can serialise/deserialise PendingJob" testPendingJobSerialisation
      , testProperty "Server can serialise/deserialise AtlasNotification" testAtlasNotificationSerialisation
      , testProperty "Server can serialise/deserialise UTCTime" testUTCTimeSerialisation
      , testProperty "Server can serialise/deserialise DatabaseInstance" testDatabaseInstanceSerialisation
      , testProperty "Server can serialise/deserialise JobRule" testJobRuleSerialisation
      , testProperty "Server can encode/decode as JSON a JobRule" testJobRuleJSON
      ]
    , testCase "GET  /upload can accept new jobs" testAcceptNewUploadGET
    , testCase "POST /upload can accept new jobs" (testAcceptNewUploadPOST (fmap snd res))
    , testCase "GET  /transcode-later can accept new jobs" testAcceptNewTranscodeLaterGET
    , testCase "POST /transcode-later can accept new jobs" (testAcceptNewTranscodeLaterPOST (fmap snd res))
    , testCase "GET  /discovery-kit can accept new jobs" testAcceptNewDiscoKitGET
    , testCase "POST /discovery-kit can accept new jobs" (testAcceptNewDiscoKitPOST (fmap snd res))
    , testGroup "Handlers specific tests" [
        specs
      ]
    , testGroup "Stats API specific tests" [
        statsSpecs
      ]
  ]
