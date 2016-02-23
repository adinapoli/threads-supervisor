{-
  Humble module inspired to Erlang supervisors,
  with minimal dependencies.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Control.Concurrent.Supervisor.Types
  ( SupervisorSpec0
  , Supervisor0
  , QueueLike(..)
  , Child_
  , DeadLetter
  , RestartAction
  , SupervisionEvent(..)
  , RestartStrategy(..)
  -- * Creating a new supervisor spec
  -- $new
  , newSupervisorSpec
  -- * Creating a new supervisor
  -- $sup
  , newSupervisor
  -- * Restart Policies
  , fibonacciRetryPolicy
  -- * Stopping a supervisor
  -- $shutdown
  , shutdownSupervisor
  -- * Accessing Supervisor event log
  -- $log
  , eventStream
  , activeChildren
  -- * Supervise a forked thread
  -- $fork
  , forkSupervised
  -- * Monitor another supervisor
  -- $monitor
  , monitor
  ) where

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Control.Retry
import           Data.Functor.Identity
import qualified Data.HashMap.Strict as Map
import           Data.IORef
import           Data.Time
import           Data.Typeable

--------------------------------------------------------------------------------
data Uninitialised
data Initialised

--------------------------------------------------------------------------------
data Supervisor_ q a = Supervisor_ {
        _sp_myTid    :: !(SupervisorId a ThreadId)
      , _sp_strategy :: !RestartStrategy
      , _sp_children :: !(IORef (Map.HashMap ThreadId (Child_ q)))
      , _sp_mailbox :: TChan DeadLetter
      , _sp_eventStream :: q SupervisionEvent
      }

type family SupervisorId (k :: *) :: (* -> *) where
  SupervisorId Uninitialised = Maybe
  SupervisorId Initialised   = Identity

type SupervisorSpec0 q = Supervisor_ q Uninitialised
type Supervisor0 q = Supervisor_ q Initialised

class QueueLike q where
  newQueueIO :: Int -> IO (q a)
  readQueue  :: q a -> STM a
  writeQueue :: q a -> a -> STM ()

instance QueueLike TQueue where
  newQueueIO = const newTQueueIO
  readQueue  = readTQueue
  writeQueue = writeTQueue

instance QueueLike TBQueue where
  newQueueIO = newTBQueueIO
  readQueue  = readTBQueue
  writeQueue q e = do
    isFull <- isFullTBQueue q
    unless isFull $ writeTBQueue q e

--------------------------------------------------------------------------------
data DeadLetter = DeadLetter ThreadId SomeException

--------------------------------------------------------------------------------
data Child_ q = Worker !RetryStatus (RetryPolicyM IO) RestartAction
              | Supvsr !RetryStatus (RetryPolicyM IO) !(Supervisor_ q Initialised)

--------------------------------------------------------------------------------
type RestartAction = ThreadId -> IO ThreadId

--------------------------------------------------------------------------------
data SupervisionEvent =
     ChildBorn !ThreadId !UTCTime
   | ChildDied !ThreadId !SomeException !UTCTime
   | ChildRestarted !ThreadId !ThreadId !RetryStatus !UTCTime
   | ChildRestartLimitReached !ThreadId !RetryStatus !UTCTime
   | ChildFinished !ThreadId !UTCTime
   deriving Show

--------------------------------------------------------------------------------
-- | Erlang inspired strategies. At the moment only the 'OneForOne' is
-- implemented.
data RestartStrategy = OneForOne
  deriving Show

--------------------------------------------------------------------------------
-- | Smart constructor which offers a default throttling based on
-- fibonacci numbers.
fibonacciRetryPolicy :: RetryPolicyM IO
fibonacciRetryPolicy = fibonacciBackoff 100

-- $new
-- In order to create a new supervisor, you need a `SupervisorSpec`,
-- which can be acquired by a call to `newSupervisor`:


--------------------------------------------------------------------------------
-- | Creates a new 'SupervisorSpec'. The reason it doesn't return a
-- 'Supervisor' is to force you to call 'supervise' explicitly, in order to start the
-- supervisor thread.
newSupervisorSpec :: QueueLike q => RestartStrategy -> Int -> IO (SupervisorSpec0 q)
newSupervisorSpec strategy size = do
  tkn <- newTChanIO
  evt <- newQueueIO size
  ref <- newIORef Map.empty
  return $ Supervisor_ Nothing strategy ref tkn evt

-- $supervise

--------------------------------------------------------------------------------
newSupervisor :: QueueLike q => SupervisorSpec0 q -> IO (Supervisor0 q)
newSupervisor spec = forkIO (handleEvents spec) >>= \tid -> do
  mbx <- atomically $ dupTChan (_sp_mailbox spec)
  return Supervisor_ {
    _sp_myTid = Identity tid
  , _sp_strategy = _sp_strategy spec
  , _sp_mailbox = mbx
  , _sp_children = _sp_children spec
  , _sp_eventStream = _sp_eventStream spec
  }

-- $log

--------------------------------------------------------------------------------
-- | Gives you access to the event this supervisor is generating, allowing you
-- to react. It's using a bounded queue to explicitly avoid memory leaks in case
-- you do not want to drain the queue to listen to incoming events.
eventStream :: QueueLike q => Supervisor0 q -> q SupervisionEvent
eventStream (Supervisor_ _ _ _ _ e) = e

--------------------------------------------------------------------------------
-- | Returns the number of active threads at a given moment in time.
activeChildren :: QueueLike q => Supervisor0 q -> IO Int
activeChildren (Supervisor_ _ _ chRef _ _) = do
  readIORef chRef >>= return . length . Map.keys

-- $shutdown

--------------------------------------------------------------------------------
-- | Shutdown the given supervisor. This will cause the supervised children to
-- be killed as well. To do so, we explore the children tree, killing workers as we go,
-- and recursively calling `shutdownSupervisor` in case we hit a monitored `Supervisor`.
shutdownSupervisor :: QueueLike q => Supervisor0 q -> IO ()
shutdownSupervisor (Supervisor_ (Identity tid) _ chRef _ _) = do
  chMap <- readIORef chRef
  processChildren (Map.toList chMap)
  killThread tid
  where
    processChildren [] = return ()
    processChildren (x:xs) = do
      case x of
        (tid, Worker _ _ _) -> killThread tid
        (_, Supvsr _ _ s) -> shutdownSupervisor s
      processChildren xs

-- $fork

--------------------------------------------------------------------------------
-- | Fork a thread in a supervised mode.
forkSupervised :: QueueLike q
               => Supervisor0 q
               -- ^ The 'Supervisor'
               -> RetryPolicyM IO
               -- ^ The retry policy to use
               -> IO ()
               -- ^ The computation to run
               -> IO ThreadId
forkSupervised sup@Supervisor_{..} policy act =
  bracket (supervised sup act) return $ \newChild -> do
    let ch = Worker defaultRetryStatus policy (const (supervised sup act))
    atomicModifyIORef' _sp_children $ \chMap -> (Map.insert newChild ch chMap, ())
    now <- getCurrentTime
    atomically $ writeQueue _sp_eventStream (ChildBorn newChild now)
    return newChild

--------------------------------------------------------------------------------
supervised :: QueueLike q => Supervisor0 q -> IO () -> IO ThreadId
supervised Supervisor_{..} act = forkFinally act $ \res -> case res of
  Left ex -> bracket myThreadId return $ \myId -> atomically $
    writeTChan _sp_mailbox (DeadLetter myId ex)
  Right _ -> bracket myThreadId return $ \myId -> do
    now <- getCurrentTime
    atomicModifyIORef' _sp_children $ \chMap -> (Map.delete myId chMap, ())
    atomically $ writeQueue _sp_eventStream (ChildFinished myId now)

restartChild :: QueueLike q => SupervisorSpec0 q -> UTCTime -> ThreadId -> IO Bool
restartChild (Supervisor_ myId myStrategy myChildren myMailbox myStream) now newDeath = do
  chMap <- readIORef myChildren
  case Map.lookup newDeath chMap of
    Nothing -> return False
    Just (Worker rState rPolicy act) ->
      runRetryPolicy rState rPolicy emitEventChildRestartLimitReached $ \newRState -> do
        let ch = Worker newRState rPolicy act
        newThreadId <- act newDeath
        writeIORef myChildren (Map.insert newThreadId ch $! Map.delete newDeath chMap)
        emitEventChildRestarted newThreadId newRState
    Just (Supvsr rState rPolicy s@(Supervisor_ _ str mbx cld es)) ->
      runRetryPolicy rState rPolicy emitEventChildRestartLimitReached $ \newRState -> do
        let node = Supervisor_ myId myStrategy myChildren myMailbox myStream
        let ch = (Supvsr newRState rPolicy s)
        -- TODO: shutdown children?
        newThreadId <- supervised node (handleEvents $ Supervisor_ Nothing str mbx cld es)
        writeIORef myChildren (Map.insert newThreadId ch $! Map.delete newDeath chMap)
        emitEventChildRestarted newThreadId newRState
  where
    emitEventChildRestarted newThreadId newRState = atomically $
      writeQueue myStream (ChildRestarted newDeath newThreadId newRState now)
    emitEventChildRestartLimitReached newRState = atomically $
      writeQueue myStream (ChildRestartLimitReached newDeath newRState now)
    runRetryPolicy :: RetryStatus
                 -> RetryPolicyM IO
                 -> (RetryStatus -> IO ())
                 -> (RetryStatus -> IO ())
                 -> IO Bool
    runRetryPolicy rState rPolicy ifAbort ifThrottle = do
     maybeDelay <- getRetryPolicyM rPolicy rState
     case maybeDelay of
       Nothing -> ifAbort rState >> return False
       Just delay ->
         let newRState = rState { rsIterNumber = rsIterNumber rState + 1
                                , rsCumulativeDelay = rsCumulativeDelay rState + delay
                                , rsPreviousDelay = Just (maybe 0 (const delay) (rsPreviousDelay rState))
                                }
         in threadDelay delay >> ifThrottle newRState >> return True

restartOneForOne :: QueueLike q => SupervisorSpec0 q -> UTCTime -> ThreadId -> IO Bool
restartOneForOne sup now newDeath = restartChild sup now newDeath

--------------------------------------------------------------------------------
handleEvents :: QueueLike q => SupervisorSpec0 q -> IO ()
handleEvents sup@(Supervisor_ _ myStrategy _ myMailbox myStream) = do
  (DeadLetter newDeath ex) <- atomically $ readTChan myMailbox
  now <- getCurrentTime
  atomically $ writeQueue myStream (ChildDied newDeath ex now)
  -- If we catch an `AsyncException`, we have nothing but good
  -- reasons not to restart the thread.
  -- Note to the skeptical: It's perfectly fine do put `undefined` here,
  -- as `typeOf` does not inspect the content (try in GHCi!)
  case typeOf ex == (typeOf (undefined :: AsyncException)) of
    True -> handleEvents sup
    False -> do
      successful <- case myStrategy of
        OneForOne -> restartOneForOne sup now newDeath
      unless successful $ do
        -- TODO: shutdown supervisor?
        return ()
      handleEvents sup

-- $monitor

newtype MonitorRequest = MonitoredSupervision ThreadId deriving (Show, Typeable)

instance Exception MonitorRequest

--------------------------------------------------------------------------------
-- | Monitor another supervisor. To achieve these, we simulate a new 'DeadLetter',
-- so that the first supervisor will effectively restart the monitored one.
-- Thanks to the fact that for the supervisor the restart means we just copy over
-- its internal state, it should be perfectly fine to do so.
-- Returns the `ThreadId` of the monitored supervisor.
monitor :: QueueLike q => Supervisor0 q -> Supervisor0 q -> IO ThreadId
monitor (Supervisor_ _ _ _ mbox _) (Supervisor_ (Identity tid) _ _ _ _) = do
  atomically $
    writeTChan mbox (DeadLetter tid (toException $ MonitoredSupervision tid))
  return tid
