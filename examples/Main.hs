{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Concurrent.Supervisor
import Control.Concurrent
import Control.Exception
import Control.Concurrent.STM

job1 :: IO ()
job1 = do
  threadDelay 5000000
  fail "Dead"

job2 :: ThreadId -> IO ()
job2 tid = do
  threadDelay 3000000
  killThread tid

job3 :: IO ()
job3 = do
  threadDelay 5000000
  error "Oh boy, I'm good as dead"

job4 :: IO ()
job4 = threadDelay 7000000

job5 :: IO ()
job5 = threadDelay 100 >> error "dead"

main :: IO ()
main = bracketOnError (do
  supSpec <- newSupervisorSpec OneForOne

  sup1 <- newSupervisor supSpec
  sup2 <- newSupervisor supSpec

  sup2ThreadId <- sup1 `monitor` sup2
  putStrLn $ "Supervisor 2 has ThreadId: " ++ show sup2ThreadId

  _ <- forkSupervised sup2 fibonacciRetryPolicy job3

  j1 <- forkSupervised sup1 fibonacciRetryPolicy job1
  _ <- forkSupervised sup1 fibonacciRetryPolicy (job2 j1)
  _ <- forkSupervised sup1 fibonacciRetryPolicy job4
  _ <- forkSupervised sup1 fibonacciRetryPolicy job5
  _ <- forkIO (go (eventStream sup1))
  -- We kill sup2
  throwTo sup2ThreadId ThreadKilled
  return sup1) shutdownSupervisor (\_ -> threadDelay 10000000000)
  where
   go eS = do
     newE <- atomically $ readTQueue eS
     print newE
     go eS
