{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
import           Test.QuickCheck.Monadic
import           Tests
import qualified Tests.Bounded as B


--------------------------------------------------------------------------------
main :: IO ()
main = defaultMain allTests


--------------------------------------------------------------------------------
withQuickCheckDepth :: TestName -> Int -> [TestTree] -> TestTree
withQuickCheckDepth tn depth tests =
  localOption (QuickCheckTests depth) (testGroup tn tests)


--------------------------------------------------------------------------------
allTests :: TestTree
allTests = testGroup "All Tests" [
    withQuickCheckDepth "Control.Concurrent.Supervisor" 20 [
        testProperty "1 supervised thread, no exceptions" (monadicIO test1SupThreadNoEx)
      , testProperty "1 supervised thread, premature exception" (monadicIO test1SupThreadPrematureDemise)
      , testProperty "1 supervised supervisor, premature exception" (monadicIO test1SupSpvrPrematureDemise)
      , testProperty "killing spree" (monadicIO testKillingSpree)
      , testProperty "cleanup" (monadicIO testSupCleanup)
      , testCase "too many restarts" testTooManyRestarts
    ]
    , withQuickCheckDepth "Control.Concurrent.Supervisor.Bounded" 20 [
        testProperty "1 supervised thread, no exceptions" (monadicIO B.test1SupThreadNoEx)
      , testProperty "1 supervised thread, premature exception" (monadicIO B.test1SupThreadPrematureDemise)
      , testProperty "killing spree" (monadicIO B.testKillingSpree)
      , testProperty "cleanup" (monadicIO B.testSupCleanup)
      , testCase "too many restarts" B.testTooManyRestarts
    ]
  ]
