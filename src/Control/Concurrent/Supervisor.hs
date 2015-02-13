
{-
  Humble module inspired to Erlang supervisors,
  with minimal dependencies.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Control.Concurrent.Supervisor 
  ( SupervisorSpec
  , Supervisor
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
import           Data.Typeable
import           Control.Exception
import           Control.Monad
import           Data.Time

--------------------------------------------------------------------------------
data Uninitialised
data Initialised

--------------------------------------------------------------------------------
data Supervisor_ a where
     NewSupervisor :: {
        _ns_myTid    :: !(Maybe ThreadId)
      , _ns_children :: !(IORef (Map.HashMap ThreadId Child))
      , _ns_mailbox :: TChan DeadLetter
      , _ns_eventStream :: TBQueue SupervisionEvent
      } -> Supervisor_ Uninitialised
     Supervisor :: {
        _sp_myTid    :: !(Maybe ThreadId)
      , _sp_children :: !(IORef (Map.HashMap ThreadId Child))
      , _sp_mailbox :: TChan DeadLetter
      , _sp_eventStream :: TBQueue SupervisionEvent
      } -> Supervisor_ Initialised

type SupervisorSpec = Supervisor_ Uninitialised
type Supervisor = Supervisor_ Initialised

--------------------------------------------------------------------------------
data DeadLetter = DeadLetter ThreadId SomeException

--------------------------------------------------------------------------------
data Child = Worker !RestartStrategy RestartAction
           | Supvsr !RestartStrategy !(Supervisor_ Initialised)

--------------------------------------------------------------------------------
type RestartAction = ThreadId -> IO ThreadId

--------------------------------------------------------------------------------
data SupervisionEvent =
     ChildBorn !ThreadId !UTCTime
   | ChildDied !ThreadId !SomeException !UTCTime
   | ChildRestarted !ThreadId !ThreadId !RestartStrategy !UTCTime
   | ChildFinished !ThreadId !UTCTime
   deriving Show

--------------------------------------------------------------------------------
-- | Erlang inspired strategies. At the moment only the 'OneForOne' is
-- implemented.
data RestartStrategy =
     OneForOne
     deriving Show

-- $new
-- In order to create a new supervisor, you need a `SupervisorSpec`,
-- which can be acquired by a call to `newSupervisor`:

--------------------------------------------------------------------------------
-- | Creates a new 'SupervisorSpec'. The reason it doesn't return a
-- 'Supervisor' is to force you to call 'supervise' explicitly, in order to start the
-- supervisor thread.
newSupervisorSpec :: IO SupervisorSpec
newSupervisorSpec = do
  tkn <- newTChanIO
  evt <- newTBQueueIO 1000
  ref <- newIORef Map.empty
  return $ NewSupervisor Nothing ref tkn evt

-- $supervise

--------------------------------------------------------------------------------
newSupervisor :: SupervisorSpec -> IO Supervisor
newSupervisor spec = forkIO (handleEvents spec) >>= \tid -> do
  mbx <- atomically $ dupTChan (_ns_mailbox spec)
  return $ Supervisor {
    _sp_myTid = Just tid
  , _sp_mailbox = mbx
  , _sp_children = _ns_children spec
  , _sp_eventStream = _ns_eventStream spec
  }

-- $log

--------------------------------------------------------------------------------
-- | Gives you access to the event this supervisor is generating, allowing you
-- to react. It's using a bounded queue to explicitly avoid memory leaks in case
-- you do not want to drain the queue to listen to incoming events.
eventStream :: Supervisor -> TBQueue SupervisionEvent
eventStream (Supervisor _ _ _ e) = e

--------------------------------------------------------------------------------
-- | Returns the number of active threads at a given moment in time.
activeChildren :: Supervisor -> IO Int
activeChildren (Supervisor _ chRef _ _) = do
  readIORef chRef >>= return . length . Map.keys

-- $shutdown

--------------------------------------------------------------------------------
-- | Shutdown the given supervisor. This will cause the supervised children to
-- be killed as well. To do so, we explore the children tree, killing workers as we go,
-- and recursively calling `shutdownSupervisor` in case we hit a monitored `Supervisor`.
shutdownSupervisor :: Supervisor -> IO ()
shutdownSupervisor (Supervisor sId chRef _ _) = do
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
forkSupervised :: Supervisor
               -- ^ The 'Supervisor'
               -> RestartStrategy
               -- ^ The 'RestartStrategy' to use
               -> IO ()
               -- ^ The computation to run
               -> IO ThreadId
forkSupervised sup@Supervisor{..} str act =
  bracket (supervised sup act) return $ \newChild -> do
    let ch = Worker str (const (supervised sup act))
    atomicModifyIORef' _sp_children $ \chMap -> (Map.insert newChild ch chMap, ())
    now <- getCurrentTime
    writeIfNotFull _sp_eventStream (ChildBorn newChild now)
    return newChild

--------------------------------------------------------------------------------
writeIfNotFull :: TBQueue SupervisionEvent -> SupervisionEvent -> IO ()
writeIfNotFull q evt = atomically $ do
  isFull <- isFullTBQueue q
  unless isFull $ writeTBQueue q evt

--------------------------------------------------------------------------------
supervised :: Supervisor -> IO () -> IO ThreadId
supervised Supervisor{..} act = forkFinally act $ \res -> case res of
  Left ex -> bracket myThreadId return $ \myId -> atomically $ 
    writeTChan _sp_mailbox (DeadLetter myId ex)
  Right _ -> bracket myThreadId return $ \myId -> do
    now <- getCurrentTime
    atomicModifyIORef' _sp_children $ \chMap -> (Map.delete myId chMap, ())
    writeIfNotFull _sp_eventStream (ChildFinished myId now)

--------------------------------------------------------------------------------
handleEvents :: SupervisorSpec -> IO ()
handleEvents sp@(NewSupervisor myId myChildren myMailbox myStream) = do
  (DeadLetter newDeath ex) <- atomically $ readTChan myMailbox
  now <- getCurrentTime
  writeIfNotFull myStream (ChildDied newDeath ex now)
  case asyncExceptionFromException ex of
    Just ThreadKilled -> handleEvents sp
    _ -> do
     chMap <- readIORef myChildren
     case Map.lookup newDeath chMap of
       Nothing -> handleEvents sp
       Just ch@(Worker str act) -> case str of
         OneForOne -> do
           newThreadId <- act newDeath
           writeIORef myChildren (Map.insert newThreadId ch $! Map.delete newDeath chMap)
           writeIfNotFull myStream (ChildRestarted newDeath newThreadId str now)
           handleEvents sp
       Just ch@(Supvsr str (Supervisor _ mbx cld es)) -> case str of
         OneForOne -> do
           let node = Supervisor myId myChildren myMailbox myStream
           newThreadId <- supervised node (handleEvents $ NewSupervisor Nothing mbx cld es)
           writeIORef myChildren (Map.insert newThreadId ch $! Map.delete newDeath chMap)
           writeIfNotFull myStream (ChildRestarted newDeath newThreadId str now)
           handleEvents sp

-- $monitor

newtype MonitorRequest = MonitoredSupervision ThreadId deriving (Show, Typeable)

instance Exception MonitorRequest

--------------------------------------------------------------------------------
-- | Monitor another supervisor. To achieve these, we simulate a new 'DeadLetter',
-- so that the first supervisor will effectively restart the monitored one.
-- Thanks to the fact that for the supervisor the restart means we just copy over
-- its internal state, it should be perfectly fine to do so.
monitor :: Supervisor -> Supervisor -> IO ()
monitor (Supervisor _ _ mbox _) (Supervisor mbId _ _ _) = do
  case mbId of
    Nothing -> return ()
    Just tid -> atomically $
      writeTChan mbox (DeadLetter tid (toException $ MonitoredSupervision tid))
