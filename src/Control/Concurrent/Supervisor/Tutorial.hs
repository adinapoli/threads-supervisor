{-# OPTIONS_GHC -fno-warn-unused-imports #-}

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

    -- * Bounded vs Unbounded
    -- $boundedVsUnbounded

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
-- A 'SupervisorSpec' simply holds the state of our supervision, and can be safely shared
-- between supervisors. Under the hood, both the `SupervisorSpec` and the `Supervisor`
-- share the same structure; in fact, they are  just type synonyms:
--
-- > type SupervisorSpec = Supervisor_ Uninitialised
-- > type Supervisor = Supervisor_ Initialised
-- The important difference though, is that the `SupervisorSpec` does not imply the creation
-- of an asynchronous thread, which the latter does. To keep separated the initialisation
-- of the data structure from the logic of supervising, we use  phantom types to
-- force you create a spec first.
-- Creating a spec it just a matter of calling `newSupervisorSpec`.

-- $createSupervisor
-- Creating a 'Supervisor' from a 'SupervisionSpec', is as simple as calling `newSupervisor`.
-- immediately after doing so, a new thread will be started, monitoring any subsequent IO actions
-- submitted to it.

-- $boundedVsUnbounded
-- By default, it's programmer responsibility to read the `SupervisionEvent` the library writes
-- into its internal queue. If you do not do so, your program might leak. To mitigate this, and
-- to offer a more granular control, two different modules are provided: a `Bounded` and an
-- `Unbounded` one, which use, respectively, a `TBQueue` or a `TQueue` underneath. You can decide
-- to go with the bounded version, with a queue size enforced by the library author, or pass in
-- your own size.

-- $supervising
-- Let's wrap everything together into a full blown example:
--
-- > main :: IO ()
-- > main = bracketOnError (do
-- >   supSpec <- newSupervisorSpec OneForOne
-- >
-- >   sup1 <- newSupervisor supSpec
-- >   sup2 <- newSupervisor supSpec
-- >
-- >   sup1 `monitor` sup2
-- >
-- >   _ <- forkSupervised sup2 fibonacciRetryPolicy job3
-- >
-- >   j1 <- forkSupervised sup1 fibonacciRetryPolicy job1
-- >   _ <- forkSupervised sup1 fibonacciRetryPolicy (job2 j1)
-- >   _ <- forkSupervised sup1 fibonacciRetryPolicy job4
-- >   _ <- forkIO (go (eventStream sup1))
-- >   return sup1) shutdownSupervisor (\_ -> threadDelay 10000000000)
-- >   where
-- >    go eS = do
-- >      newE <- atomically $ readTBQueue eS
-- >      print newE
-- >      go eS
--
-- What we have done here, was to spawn our supervisor out from a spec,
-- any using our swiss knife `forkSupervised` to spawn for supervised
-- IO computations. As you can see, if we partially apply `forkSupervised`,
-- its type resemble `forkIO` one; this is by design, as we want to keep
-- this API as IO-friendly as possible
-- in the very same example, we also create another supervisor
-- (from the same spec, but you can create a separate one as well)
-- and we ask the first supervisor to monitor the second one.
--
-- `fibonacciRetryPolicy` is a constructor for the `RetryPolicy`, which creates
-- under the hood a `RetryPolicy` from the "retry" package which is using
-- the `fibonacciBackoff`. The clear advantage is that you are not obliged to use
-- it if you don't like this sensible default;
-- `RetryPolicy` is an monoid, so you can compose retry policies as you wish.
--
-- The `RetryPolicy` will also be responsible for determining whether a thread can be
-- restarted or not; in the latter case you will find a `ChildRestartedLimitReached`
-- in your event log.
--
-- If you run this program, hopefully you should see on stdout
-- something like this:
--
-- > ChildBorn ThreadId 62 2015-02-13 11:51:15.293882 UTC
-- > ChildBorn ThreadId 63 2015-02-13 11:51:15.293897 UTC
-- > ChildBorn ThreadId 64 2015-02-13 11:51:15.293904 UTC
-- > ChildDied ThreadId 61 (MonitoredSupervision ThreadId 61) 2015-02-13 11:51:15.293941 UTC
-- > ChildBorn ThreadId 65 2015-02-13 11:51:15.294014 UTC
-- > ChildFinished ThreadId 64 2015-02-13 11:51:18.294797 UTC
-- > ChildDied ThreadId 63 thread killed 2015-02-13 11:51:18.294909 UTC
-- > ChildDied ThreadId 62 Oh boy, I'm good as dead 2015-02-13 11:51:20.294861 UTC
-- > ChildRestarted ThreadId 62 ThreadId 68 OneForOne 2015-02-13 11:51:20.294861 UTC
-- > ChildFinished ThreadId 65 2015-02-13 11:51:22.296089 UTC
-- > ChildDied ThreadId 68 Oh boy, I'm good as dead 2015-02-13 11:51:25.296189 UTC
-- > ChildRestarted ThreadId 68 ThreadId 69 OneForOne 2015-02-13 11:51:25.296189 UTC
-- > ChildDied ThreadId 69 Oh boy, I'm good as dead 2015-02-13 11:51:30.297464 UTC
-- > ChildRestarted ThreadId 69 ThreadId 70 OneForOne 2015-02-13 11:51:30.297464 UTC
-- > ChildDied ThreadId 70 Oh boy, I'm good as dead 2015-02-13 11:51:35.298123 UTC
-- > ChildRestarted ThreadId 70 ThreadId 71 OneForOne 2015-02-13 11:51:35.298123 UTC

-- $conclusions
-- I hope that you are now convinced that this library can be of some use to you!
