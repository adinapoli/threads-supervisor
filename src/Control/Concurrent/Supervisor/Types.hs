{-
  Humble module inspired to Erlang supervisors,
  with minimal dependencies.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
  , monitorWith
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
        _sp_myTid          :: !(SupervisorId a ThreadId)
      , _sp_strategy       :: !RestartStrategy
      , _sp_children       :: !(IORef (Map.HashMap ThreadId (Child_ q)))
      , _sp_mailbox        :: TChan DeadLetter
      , _sp_parent_mailbox :: !(IORef (Maybe (TChan DeadLetter)))
      -- ^ The mailbox of the parent process (which is monitoring this one), if any.
      , _sp_eventStream    :: q SupervisionEvent
      }

type family SupervisorId (k :: *) :: (* -> *) where
  SupervisorId Uninitialised = Proxy
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
  mbox <- newTChanIO
  evt  <- newQueueIO size
  ref  <- newIORef Map.empty
  pMb  <- newIORef Nothing
  return $ Supervisor_ Proxy strategy ref mbox pMb evt

-- $supervise

--------------------------------------------------------------------------------
newSupervisor :: QueueLike q => SupervisorSpec0 q -> IO (Supervisor0 q)
newSupervisor spec = mdo
  tid <- forkIO (handleEvents spec tid)
  go tid
  where
    go tid = do
      mbx       <- atomically $ dupTChan (_sp_mailbox spec)
      parentMbx <- newIORef Nothing
      return Supervisor_ {
        _sp_myTid = Identity tid
      , _sp_strategy = _sp_strategy spec
      , _sp_mailbox = mbx
      , _sp_parent_mailbox = parentMbx
      , _sp_children = _sp_children spec
      , _sp_eventStream = _sp_eventStream spec
      }

-- $log

--------------------------------------------------------------------------------
-- | Gives you access to the event this supervisor is generating, allowing you
-- to react. It's using a bounded queue to explicitly avoid memory leaks in case
-- you do not want to drain the queue to listen to incoming events.
eventStream :: QueueLike q => Supervisor0 q -> q SupervisionEvent
eventStream (Supervisor_{_sp_eventStream}) = _sp_eventStream

--------------------------------------------------------------------------------
-- | Returns the number of active threads at a given moment in time.
activeChildren :: QueueLike q => Supervisor0 q -> IO Int
activeChildren (Supervisor_{_sp_children}) = do
  readIORef _sp_children >>= return . length . Map.keys

-- $shutdown

--------------------------------------------------------------------------------
-- | Shutdown the given supervisor. This will cause the supervised children to
-- be killed as well. To do so, we explore the children tree, killing workers as we go,
-- and recursively calling `shutdownSupervisor` in case we hit a monitored `Supervisor`.
shutdownSupervisor :: QueueLike q => Supervisor0 q -> IO ()
shutdownSupervisor (Supervisor_ (Identity tid) _ chRef _ _ _) = do
  chMap <- readIORef chRef
  processChildren (Map.toList chMap)
  killThread tid
  where
    processChildren [] = return ()
    processChildren (x:xs) = do
      case x of
        (workerTid, Worker{}) -> killThread workerTid
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
  Left ex -> bracket myThreadId return $ \myId -> do
    pMboxMb <- readIORef _sp_parent_mailbox
    atomically $ do
      writeTChan _sp_mailbox (DeadLetter myId ex)
      -- In case we have a parent mailbox available, notify our death.
      case pMboxMb of
        Nothing -> return ()
        Just m  -> writeTChan m (DeadLetter myId ex)
  Right _ -> bracket myThreadId return $ \myId -> do
    now <- getCurrentTime
    atomicModifyIORef' _sp_children $ \chMap -> (Map.delete myId chMap, ())
    atomically $ writeQueue _sp_eventStream (ChildFinished myId now)

--------------------------------------------------------------------------------
restartChild :: QueueLike q => SupervisorSpec0 q -> ThreadId -> UTCTime -> ThreadId -> IO Bool
restartChild Supervisor_{..} myId now newDeath = do
  chMap <- readIORef _sp_children
  case Map.lookup newDeath chMap of
    Nothing -> return False
    Just (Worker rState rPolicy act) ->
      runRetryPolicy rState rPolicy emitEventChildRestartLimitReached $ \newRState -> do
        let ch = Worker newRState rPolicy act
        newThreadId <- act newDeath
        writeIORef _sp_children (Map.insert newThreadId ch $! Map.delete newDeath chMap)
        emitEventChildRestarted newThreadId newRState
    Just (Supvsr rState rPolicy s@(Supervisor_ _ str mbx parentMb cld es)) -> do
      runRetryPolicy rState rPolicy emitEventChildRestartLimitReached $ \newRState -> do
        let node = Supervisor_ (Identity myId) _sp_strategy _sp_children _sp_mailbox _sp_parent_mailbox _sp_eventStream
        let ch = (Supvsr newRState rPolicy s)
        -- TODO: shutdown children?
        newThreadId <- supervised node (handleEvents (Supervisor_ Proxy str mbx parentMb cld es) myId)
        writeIORef _sp_children (Map.insert newThreadId ch $! Map.delete newDeath chMap)
        emitEventChildRestarted newThreadId newRState
  where
    emitEventChildRestarted newThreadId newRState = atomically $
      writeQueue _sp_eventStream (ChildRestarted newDeath newThreadId newRState now)
    emitEventChildRestartLimitReached newRState = atomically $
      writeQueue _sp_eventStream (ChildRestartLimitReached newDeath newRState now)
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

--------------------------------------------------------------------------------
restartOneForOne :: QueueLike q
                 => SupervisorSpec0 q
                 -> ThreadId
                 -> UTCTime
                 -> ThreadId
                 -> IO Bool
restartOneForOne = restartChild

--------------------------------------------------------------------------------
handleEvents :: QueueLike q => SupervisorSpec0 q -> ThreadId -> IO ()
handleEvents sup@(Supervisor_ _ myStrategy _ myMailbox _ myStream) tid = do
  (DeadLetter newDeath ex) <- atomically $ readTChan myMailbox
  now <- getCurrentTime
  atomically $ writeQueue myStream (ChildDied newDeath ex now)
  -- If we catch an `AsyncException`, we have nothing but good
  -- reasons not to restart the thread.
  -- Note to the skeptical: It's perfectly fine do put `undefined` here,
  -- as `typeOf` does not inspect the content (try in GHCi!)
  case typeOf ex == (typeOf (undefined :: AsyncException)) of
    True -> handleEvents sup tid
    False -> do
      successful <- case myStrategy of
        OneForOne -> restartOneForOne sup tid now newDeath
      unless successful $ do
        -- TODO: shutdown supervisor?
        return ()
      handleEvents sup tid

-- $monitor

--------------------------------------------------------------------------------
-- | Monitor another supervisor. To achieve these, we simulate a new 'DeadLetter',
-- so that the first supervisor will effectively restart the monitored one.
-- Thanks to the fact that for the supervisor the restart means we just copy over
-- its internal state, it should be perfectly fine to do so.
-- Returns the `ThreadId` of the monitored supervisor.
monitorWith :: QueueLike q
            => RetryPolicyM IO
            -- ^ The retry policy to use
            -> Supervisor0 q
            -- ^ The supervisor
            -> Supervisor0 q
            -- ^ The 'supervised' supervisor
            -> IO ThreadId
monitorWith policy (Supervisor_ _ _ ch mbox _ _) sup2@(Supervisor_ (Identity newChild) _ _ _ pMbox _) = do
  theMb <- readIORef pMbox
  case theMb of
    Just _ -> return newChild -- Do nothing, this supervisor is already monitored.
    Nothing -> do
      let sup2RetryStatus = defaultRetryStatus
      let ch' = Supvsr sup2RetryStatus policy sup2
      atomicModifyIORef' ch $ \chMap -> (Map.insert newChild ch' chMap, ())
      atomicModifyIORef' pMbox $ const (Just mbox, ())
      return newChild
