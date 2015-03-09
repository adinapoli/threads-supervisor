{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
import           Test.QuickCheck.Monadic
import           Tests


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
    withQuickCheckDepth "Control.Concurrent.Supervisor" 10 [
        testProperty "1 supervised thread, no exceptions" (monadicIO test1SupThreadNoEx)
      , testProperty "1 supervised thread, premature exception" (monadicIO test1SupThreadPrematureDemise)
      , testProperty "killing spree" (monadicIO testKillingSpree)
      , testProperty "cleanup" (monadicIO testSupCleanup)
      , testCase "too many restarts" testTooManyRestarts
    ]
  ]
