{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-| Use @threads-supervisor@ if you want the "poor-man's Erlang supervisors".
    @threads-supervisor@ is an IO-based library  with minimal dependencies
    which does only one thing: It provides you a 'Supervisor' entity  you can use
    to monitor your forked computations. If one of the managed threads dies,
    you can decide if and how to restart it. This gives you:

    * Protection against silent exceptions which might terminate your workers.
    * A simple but powerful way of structure your program into a supervision tree,
    where the leaves are the worker threads, and the nodes can be other
    supervisors being monitored.
    * A disaster recovery mechanism.

  You can install the @threads-supervisor@ library by running:
  > $ cabal install threads-supervisor
-}

module Control.Concurrent.Supervisor.Tutorial
 (  -- * Introduction
    -- $introduction

    -- * Different type of jobs
    -- $jobs

    -- * Creating a SupervisorSpec
    -- $createSpec

    -- * Creating a Supervisor
    -- $createSupervisor

    -- * Supervising and choosing a 'RestartStrategy'
    -- $supervising

    -- * Wrapping up
    -- $conclusions

 ) where

-- $introduction
-- Who worked with Haskell's concurrency primitives would be surely familiar
-- with the `forkIO` function, which allow us to fork an IO computation in a separate
-- green thread. `forkIO` is great, but is also very low level, and has a
-- couple of subtleties, as you can read from this passage of the documentation:
--
--    The newly created thread has an exception handler that discards the exceptions 
--    `BlockedIndefinitelyOnMVar`,`BlockedIndefinitelyOnSTM`, and `ThreadKilled`, 
--    and passes all other exceptions to the uncaught exception handler.
--
-- To mitigate this, we have a couple of libraries available,  for example
-- <http://hackage.haskell.org/package/async> and <http://hackage.haskell.org/package/slave-thread>.
-- 
-- But what about if I do not want to take explicit action, but instead specifying upfront
-- how to react to disaster, and leave the library work out the details?
-- This is what this library aims to do.

-- $jobs
-- In this example, let's create four different threads:
--
-- > job1 :: IO ()
-- > job1 = do
-- >   threadDelay 5000000
-- >   fail "Dead"
-- This job will die after five seconds.
--
-- > job2 :: ThreadId -> IO ()
-- > job2 tid = do
-- >   threadDelay 3000000
-- >   killThread tid
--
-- This other job instead, we have waited three seconds, and then kill a target thread,
-- generating an asynchronous exception.
--
-- > job3 :: IO ()
-- > job3 = do
-- >   threadDelay 5000000
-- >   error "Oh boy, I'm good as dead"
--
-- This guy is very similar to the first one, except for the fact `error` is used instead of `fail`.
--
-- > job4 :: IO ()
-- > job4 = threadDelay 7000000
-- @job4@ is what we wish for all our passing cross computation: smooth sailing.
--
-- These jobs represent a significant pool of our everyday computations in the IO monad


-- $createSpec
-- Here I discuss the creation of a 'SupervisorSpec'

-- $createSupervisor
-- Here I discuss the creation of a 'Supervisor' from a 'SupervisionSpec'

-- $supervising
-- Here I discuss how you can supervise other threads.

-- $conclusions
-- I hope that you are now convinced that this library can be of some use to you!
--
-- > main :: IO ()
-- > main = bracketOnError (do
-- >   supSpec <- newSupervisor
-- >   sup <- supervise supSpec
-- >   j1 <- forkSupervised sup OneForOne job1
-- >   _ <- forkSupervised sup OneForOne (job2 j1)
-- >   _ <- forkSupervised sup OneForOne job3
-- >   _ <- forkSupervised sup OneForOne job4
-- >   _ <- forkIO (go (eventStream sup))
-- >   return sup) shutdownSupervisor (\_ -> threadDelay 10000000000)
-- >   where
-- >    go eS = do
-- >      newE <- atomically $ readTBQueue eS
-- >      print newE
-- >      go eS
