
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Control.Concurrent.Supervisor.Tutorial where

import Control.Concurrent.STM
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Supervisor

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

main :: IO ()
main = bracketOnError (do
  supSpec <- newSupervisor
  sup <- supervise supSpec
  j1 <- forkSupervised sup OneForOne job1
  _ <- forkSupervised sup OneForOne (job2 j1)
  _ <- forkSupervised sup OneForOne job3
  _ <- forkSupervised sup OneForOne job4
  _ <- forkIO (go (eventStream sup))
  return sup) shutdownSupervisor (\_ -> threadDelay 10000000000)
  where
   go eS = do
     newE <- atomically $ readTBQueue eS
     print newE
     go eS
