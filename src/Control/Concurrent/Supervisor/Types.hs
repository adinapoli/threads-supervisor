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
  -- * Restart Strategies
  , oneForOne
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

import qualified Data.HashMap.Strict as Map
import           Control.Concurrent
import           Control.Concurrent.STM
import           Data.IORef
import           Control.Exception
import           Data.Typeable
import           Control.Monad
import           Control.Retry
import           Data.Time

--------------------------------------------------------------------------------
data Uninitialised
data Initialised

--------------------------------------------------------------------------------
data Supervisor_ q a = Supervisor_ {
        _sp_myTid    :: !(Maybe ThreadId)
      , _sp_children :: !(IORef (Map.HashMap ThreadId (Child_ q)))
      , _sp_mailbox :: TChan DeadLetter
      , _sp_eventStream :: q SupervisionEvent
      }

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
data Child_ q = Worker !RestartStrategy RestartAction
              | Supvsr !RestartStrategy !(Supervisor_ q Initialised)

--------------------------------------------------------------------------------
type RestartAction = ThreadId -> IO ThreadId

--------------------------------------------------------------------------------
data SupervisionEvent =
     ChildBorn !ThreadId !UTCTime
   | ChildDied !ThreadId !SomeException !UTCTime
   | ChildRestarted !ThreadId !ThreadId !RestartStrategy !UTCTime
   | ChildRestartLimitReached !ThreadId !RestartStrategy !UTCTime
   | ChildFinished !ThreadId !UTCTime
   deriving Show

--------------------------------------------------------------------------------
-- | Erlang inspired strategies. At the moment only the 'OneForOne' is
-- implemented.
data RestartStrategy =
     OneForOne !Int RetryPolicy

instance Show RestartStrategy where
  show (OneForOne r _) = "OneForOne (Restarted " <> show r <> " times)"

--------------------------------------------------------------------------------
-- | Smart constructor which offers a default throttling based on
-- fibonacci numbers.
oneForOne :: RestartStrategy
oneForOne = OneForOne 0 $ fibonacciBackoff 100

-- $new
-- In order to create a new supervisor, you need a `SupervisorSpec`,
-- which can be acquired by a call to `newSupervisor`:


--------------------------------------------------------------------------------
-- | Creates a new 'SupervisorSpec'. The reason it doesn't return a
-- 'Supervisor' is to force you to call 'supervise' explicitly, in order to start the
-- supervisor thread.
newSupervisorSpec :: QueueLike q => Int -> IO (SupervisorSpec0 q)
newSupervisorSpec size = do
  tkn <- newTChanIO
  evt <- newQueueIO size
  ref <- newIORef Map.empty
  return $ Supervisor_ Nothing ref tkn evt

-- $supervise

--------------------------------------------------------------------------------
newSupervisor :: QueueLike q => SupervisorSpec0 q -> IO (Supervisor0 q)
newSupervisor spec = forkIO (handleEvents spec) >>= \tid -> do
  mbx <- atomically $ dupTChan (_sp_mailbox spec)
  return Supervisor_ {
    _sp_myTid = Just tid
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
eventStream (Supervisor_ _ _ _ e) = e

--------------------------------------------------------------------------------
-- | Returns the number of active threads at a given moment in time.
activeChildren :: QueueLike q => Supervisor0 q -> IO Int
activeChildren (Supervisor_ _ chRef _ _) = do
  readIORef chRef >>= return . length . Map.keys

-- $shutdown

--------------------------------------------------------------------------------
-- | Shutdown the given supervisor. This will cause the supervised children to
-- be killed as well. To do so, we explore the children tree, killing workers as we go,
-- and recursively calling `shutdownSupervisor` in case we hit a monitored `Supervisor`.
shutdownSupervisor :: QueueLike q => Supervisor0 q -> IO ()
shutdownSupervisor (Supervisor_ sId chRef _ _) = do
  case sId of
    Nothing -> return ()
    Just tid -> do
      chMap <- readIORef chRef
      processChildren (Map.toList chMap)
      killThread tid
  where
    processChildren [] = return ()
    processChildren (x:xs) = do
      case x of
        (tid, Worker _ _) -> killThread tid
        (_, Supvsr _ s) -> shutdownSupervisor s
      processChildren xs

-- $fork

--------------------------------------------------------------------------------
-- | Fork a thread in a supervised mode.
forkSupervised :: QueueLike q
               => Supervisor0 q
               -- ^ The 'Supervisor'
               -> RestartStrategy
               -- ^ The 'RestartStrategy' to use
               -> IO ()
               -- ^ The computation to run
               -> IO ThreadId
forkSupervised sup@Supervisor_{..} str act =
  bracket (supervised sup act) return $ \newChild -> do
    let ch = Worker str (const (supervised sup act))
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

--------------------------------------------------------------------------------
handleEvents :: QueueLike q => SupervisorSpec0 q -> IO ()
handleEvents sp@(Supervisor_ myId myChildren myMailbox myStream) = do
  (DeadLetter newDeath ex) <- atomically $ readTChan myMailbox
  now <- getCurrentTime
  atomically $ writeQueue myStream (ChildDied newDeath ex now)
  -- If we catch an `AsyncException`, we have nothing but good
  -- reasons not to restart the thread.
  -- Note to the skeptical: It's perfectly fine do put `undefined` here,
  -- as `typeOf` does not inspect the content (try in GHCi!)
  case typeOf ex == (typeOf (undefined :: AsyncException)) of
    True -> handleEvents sp
    False -> do
     chMap <- readIORef myChildren
     case Map.lookup newDeath chMap of
       Nothing -> return ()
       Just (Worker str act) ->
         applyStrategy str (\newStr -> do
                                atomically $
                                  writeQueue myStream (ChildRestartLimitReached newDeath newStr now)) $ \newStr -> do
           let ch = Worker newStr act
           newThreadId <- act newDeath
           writeIORef myChildren (Map.insert newThreadId ch $! Map.delete newDeath chMap)
           atomically $ writeQueue myStream (ChildRestarted newDeath newThreadId newStr now)
       Just (Supvsr str s@(Supervisor_ _ mbx cld es)) ->
         applyStrategy str (\newStr -> do
                                atomically $
                                  writeQueue myStream (ChildRestartLimitReached newDeath newStr now)) $ \newStr -> do
           let node = Supervisor_ myId myChildren myMailbox myStream
           let ch = (Supvsr newStr s)
           newThreadId <- supervised node (handleEvents $ Supervisor_ Nothing mbx cld es)
           writeIORef myChildren (Map.insert newThreadId ch $! Map.delete newDeath chMap)
           atomically $ writeQueue myStream (ChildRestarted newDeath newThreadId newStr now)
     handleEvents sp
  where
    applyStrategy :: RestartStrategy
                  -> (RestartStrategy -> IO ())
                  -> (RestartStrategy -> IO ())
                  -> IO ()
    applyStrategy (OneForOne currentRestarts retryPol) ifAbort ifThrottle = do
      let newStr = OneForOne (currentRestarts + 1) retryPol
      case getRetryPolicy retryPol (currentRestarts + 1) of
        Nothing -> ifAbort newStr
        Just delay -> threadDelay delay >> ifThrottle newStr

-- $monitor

newtype MonitorRequest = MonitoredSupervision ThreadId deriving (Show, Typeable)

instance Exception MonitorRequest

--------------------------------------------------------------------------------
-- | Monitor another supervisor. To achieve these, we simulate a new 'DeadLetter',
-- so that the first supervisor will effectively restart the monitored one.
-- Thanks to the fact that for the supervisor the restart means we just copy over
-- its internal state, it should be perfectly fine to do so.
monitor :: QueueLike q => Supervisor0 q -> Supervisor0 q -> IO ()
monitor (Supervisor_ _ _ mbox _) (Supervisor_ mbId _ _ _) = do
  case mbId of
    Nothing -> return ()
    Just tid -> atomically $
      writeTChan mbox (DeadLetter tid (toException $ MonitoredSupervision tid))
