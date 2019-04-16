{-
  Humble module inspired to Erlang supervisors,
  with minimal dependencies.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Control.Concurrent.Supervisor.Types
  ( SupervisionCtx
  , Supervisor
  , QueueLike(..)
  , Child_
  , DeadLetter
  , RestartAction
  , Epoch
  , LetterEpoch(..)
  , ChildEpoch(..)
  , SupervisionEvent(..)
  , RestartStrategy(..)
  , RestartResult(..)
  -- * Useful functions
  , getEpoch
  -- * Creating a new supervisor
  -- $new
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
import           Control.Monad.IO.Class
import           Control.Retry
import qualified Data.HashMap.Strict as Map
import           Data.IORef
import           Data.Time
import           Numeric.Natural
import           System.Clock (Clock(Monotonic), TimeSpec, getTime)

--------------------------------------------------------------------------------
type Mailbox = TChan DeadLetter

--------------------------------------------------------------------------------
data SupervisionCtx q = SupervisionCtx {
    _sc_mailbox          :: Mailbox
  , _sc_parent_mailbox   :: !(IORef (Maybe Mailbox))
  -- ^ The mailbox of the parent process (which is monitoring this one), if any.
  , _sc_children         :: !(IORef (Map.HashMap ThreadId (Child_ q)))
  , _sc_eventStream      :: q SupervisionEvent
  , _sc_eventStreamSize  :: !Natural
  , _sc_strategy         :: !RestartStrategy
  }

--------------------------------------------------------------------------------
data Supervisor q = Supervisor {
        _sp_myTid          :: !ThreadId
      , _sp_ctx            :: !(SupervisionCtx q)
      }

class QueueLike q where
  newQueueIO :: Natural -> IO (q a)
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
data DeadLetter = DeadLetter !LetterEpoch !ThreadId !SomeException

--------------------------------------------------------------------------------
type Epoch = TimeSpec
newtype LetterEpoch = LetterEpoch Epoch deriving Show
newtype ChildEpoch  = ChildEpoch  Epoch deriving Show

--------------------------------------------------------------------------------
data RestartResult =
    Restarted !ThreadId !ThreadId !RetryStatus !UTCTime
    -- ^ The supervised `Child_` was restarted successfully.
  | StaleDeadLetter !ThreadId !LetterEpoch !ChildEpoch !UTCTime
    -- ^ A stale `DeadLetter` was received.
  | RestartFailed SupervisionEvent
    -- ^ The restart failed for a reason decribed by a `SupervisionEvent`
  deriving Show

--------------------------------------------------------------------------------
data Child_ q = Worker !ChildEpoch !RetryStatus (RetryPolicyM IO) RestartAction
              | Supvsr !ChildEpoch !RetryStatus (RetryPolicyM IO) !(Supervisor q)

--------------------------------------------------------------------------------
type RestartAction = ThreadId -> IO ThreadId

--------------------------------------------------------------------------------
data SupervisionEvent =
     ChildBorn !ThreadId !UTCTime
   | ChildDied !ThreadId !SomeException !UTCTime
   | ChildRestarted !ThreadId !ThreadId !RetryStatus !UTCTime
   | ChildNotFound  !ThreadId !UTCTime
   | StaleDeadLetterReceived  !ThreadId !LetterEpoch !ChildEpoch !UTCTime
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

--------------------------------------------------------------------------------
getEpoch :: MonadIO m => m Epoch
getEpoch = liftIO $ getTime Monotonic

--------------------------------------------------------------------------------
tryNotifyParent :: IORef (Maybe Mailbox) -> ThreadId -> SomeException -> IO ()
tryNotifyParent mbPMbox myId ex = do
  readIORef mbPMbox >>= \m -> case m of
    Nothing -> return ()
    Just m' -> do
      e <- getEpoch
      atomically $ writeTChan m' (DeadLetter (LetterEpoch e) myId ex)

-- $new
-- In order to create a new supervisor, you need a `SupervisorSpec`,
-- which can be acquired by a call to `newSupervisor`:

-- $supervise

--------------------------------------------------------------------------------
newSupervisor :: QueueLike q
              => RestartStrategy
              -> Natural
              -> IO (Supervisor q)
newSupervisor strategy size = do
  parentMbx <- newIORef Nothing
  mbx <- newTChanIO
  es  <- newQueueIO size
  cld <- newIORef Map.empty
  let ctx = SupervisionCtx {
          _sc_mailbox         = mbx
        , _sc_parent_mailbox  = parentMbx
        , _sc_eventStream     = es
        , _sc_children        = cld
        , _sc_strategy        = strategy
        , _sc_eventStreamSize = size
        }
  tid <- forkFinally (handleEvents ctx) $ \res -> case res of
    Left ex -> do
      bracket myThreadId return $ \myId -> do
        -- If we have a parent supervisor watching us, notify it we died.
        tryNotifyParent parentMbx myId ex
    Right v -> return v
  go ctx tid
  where
    go ctx tid = do
      return Supervisor {
        _sp_myTid = tid
      , _sp_ctx   = ctx
      }

-- $log

--------------------------------------------------------------------------------
-- | Gives you access to the event this supervisor is generating, allowing you
-- to react. It's using a bounded queue to explicitly avoid memory leaks in case
-- you do not want to drain the queue to listen to incoming events.
eventStream :: QueueLike q => Supervisor q -> q SupervisionEvent
eventStream Supervisor{_sp_ctx} = _sc_eventStream _sp_ctx

--------------------------------------------------------------------------------
-- | Returns the number of active threads at a given moment in time.
activeChildren :: QueueLike q => Supervisor q -> IO Int
activeChildren Supervisor{_sp_ctx} = do
  readIORef (_sc_children _sp_ctx) >>= return . length . Map.keys

-- $shutdown

--------------------------------------------------------------------------------
-- | Shutdown the given supervisor. This will cause the supervised children to
-- be killed as well. To do so, we explore the children tree, killing workers as we go,
-- and recursively calling `shutdownSupervisor` in case we hit a monitored `Supervisor`.
shutdownSupervisor :: QueueLike q => Supervisor q -> IO ()
shutdownSupervisor (Supervisor tid ctx) = do
  chMap <- readIORef (_sc_children ctx)
  processChildren (Map.toList chMap)
  killThread tid
  where
    processChildren [] = return ()
    processChildren (x:xs) = do
      case x of
        (workerTid, Worker{}) -> killThread workerTid
        (_, Supvsr _ _ _ s) -> shutdownSupervisor s
      processChildren xs

-- $fork

--------------------------------------------------------------------------------
-- | Fork a thread in a supervised mode.
forkSupervised :: QueueLike q
               => Supervisor q
               -- ^ The 'Supervisor'
               -> RetryPolicyM IO
               -- ^ The retry policy to use
               -> IO ()
               -- ^ The computation to run
               -> IO ThreadId
forkSupervised sup@Supervisor{..} policy act =
  bracket (supervised sup act) return $ \newChild -> do
    e <- getEpoch
    let ch = Worker (ChildEpoch e) defaultRetryStatus policy (const (supervised sup act))
    atomicModifyIORef' (_sc_children _sp_ctx) $ \chMap -> (Map.insert newChild ch chMap, ())
    now <- getCurrentTime
    atomically $ writeQueue (_sc_eventStream _sp_ctx) (ChildBorn newChild now)
    return newChild

--------------------------------------------------------------------------------
supervised :: QueueLike q => Supervisor q -> IO () -> IO ThreadId
supervised Supervisor{..} act = forkFinally act $ \res -> case res of
  Left ex -> bracket myThreadId return $ \myId -> do
    e <- getEpoch
    atomically $ writeTChan (_sc_mailbox _sp_ctx) (DeadLetter (LetterEpoch e) myId ex)
  Right _ -> bracket myThreadId return $ \myId -> do
    now <- getCurrentTime
    atomicModifyIORef' (_sc_children _sp_ctx) $ \chMap -> (Map.delete myId chMap, ())
    atomically $ writeQueue (_sc_eventStream _sp_ctx) (ChildFinished myId now)

--------------------------------------------------------------------------------
-- | Ignore any stale `DeadLetter`, which is a `DeadLetter` with an `Epoch`
-- smaller than the one stored in the `Child_` to restart. Such stale `DeadLetter`
-- are simply ignored.
ignoringStaleLetters :: ThreadId
                     -> LetterEpoch
                     -> ChildEpoch
                     -> IO RestartResult
                     -> IO RestartResult
ignoringStaleLetters tid deadLetterEpoch@(LetterEpoch l) childEpoch@(ChildEpoch c) act = do
  now <- getCurrentTime
  if l < c then return (StaleDeadLetter tid deadLetterEpoch childEpoch now) else act

--------------------------------------------------------------------------------
restartChild :: QueueLike q
             => SupervisionCtx q
             -> LetterEpoch
             -> UTCTime
             -> ThreadId
             -> IO RestartResult
restartChild ctx deadLetterEpoch now newDeath = do
  chMap <- readIORef (_sc_children ctx)
  case Map.lookup newDeath chMap of
    Nothing -> return $ RestartFailed (ChildNotFound newDeath now)
    Just (Worker workerEpoch rState rPolicy act) -> ignoringStaleLetters newDeath deadLetterEpoch workerEpoch $ do
      runRetryPolicy rState rPolicy emitEventChildRestartLimitReached $ \newRState -> do
        e <- getEpoch
        let ch = Worker (ChildEpoch e) newRState rPolicy act
        newThreadId <- act newDeath
        writeIORef (_sc_children ctx) (Map.insert newThreadId ch $! Map.delete newDeath chMap)
        emitEventChildRestarted newThreadId newRState
    Just (Supvsr supervisorEpoch rState rPolicy (Supervisor deathSup ctx')) -> do
      ignoringStaleLetters newDeath deadLetterEpoch supervisorEpoch $ do
        runRetryPolicy rState rPolicy emitEventChildRestartLimitReached $ \newRState -> do
          e <- getEpoch
          restartedSup <- newSupervisor (_sc_strategy ctx) (_sc_eventStreamSize ctx')
          let ch = Supvsr (ChildEpoch e) newRState rPolicy restartedSup
          -- TODO: shutdown children?
          let newThreadId = _sp_myTid restartedSup
          writeIORef (_sc_children ctx) (Map.insert newThreadId ch $! Map.delete deathSup chMap)
          emitEventChildRestarted newThreadId newRState
  where
    emitEventChildRestarted newThreadId newRState = do
      return $ Restarted newDeath newThreadId newRState now
    emitEventChildRestartLimitReached newRState = do
      return $ RestartFailed (ChildRestartLimitReached newDeath newRState now)
    runRetryPolicy :: RetryStatus
                   -> RetryPolicyM IO
                   -> (RetryStatus -> IO RestartResult)
                   -> (RetryStatus -> IO RestartResult)
                   -> IO RestartResult
    runRetryPolicy rState rPolicy ifAbort ifThrottle = do
     maybeDelay <- getRetryPolicyM rPolicy rState
     case maybeDelay of
       Nothing -> ifAbort rState
       Just delay ->
         let newRState = rState { rsIterNumber = rsIterNumber rState + 1
                                , rsCumulativeDelay = rsCumulativeDelay rState + delay
                                , rsPreviousDelay = Just (maybe 0 (const delay) (rsPreviousDelay rState))
                                }
         in threadDelay delay >> ifThrottle newRState

--------------------------------------------------------------------------------
restartOneForOne :: QueueLike q
                 => SupervisionCtx q
                 -> LetterEpoch
                 -> UTCTime
                 -> ThreadId
                 -> IO RestartResult
restartOneForOne = restartChild

--------------------------------------------------------------------------------
handleEvents :: QueueLike q => SupervisionCtx q -> IO ()
handleEvents ctx@SupervisionCtx{..} = do
  (DeadLetter epoch newDeath ex) <- atomically $ readTChan _sc_mailbox
  now <- getCurrentTime
  atomically $ writeQueue _sc_eventStream (ChildDied newDeath ex now)
  -- If we catch an `AsyncException`, we have nothing but good
  -- reasons NOT to restart the thread.
  case asyncExceptionFromException ex of
    Just (_ :: AsyncException) -> do
      -- Remove the `Child_` from the map, log what happenend.
      atomicModifyIORef' _sc_children $ \chMap -> (Map.delete newDeath chMap, ())
      atomically $ writeQueue _sc_eventStream (ChildDied newDeath ex now)
      handleEvents ctx
    Nothing -> do
      restartResult <- case _sc_strategy of
        OneForOne -> restartOneForOne ctx epoch now newDeath
      -- TODO: shutdown supervisor?
      atomically $ case restartResult of
        StaleDeadLetter tid le we tm -> do
          writeQueue _sc_eventStream (StaleDeadLetterReceived tid le we tm)
        RestartFailed reason -> do
          writeQueue _sc_eventStream reason
        Restarted oldId newId rStatus tm ->
          writeQueue _sc_eventStream (ChildRestarted oldId newId rStatus tm)
      handleEvents ctx

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
            -> Supervisor q
            -- ^ The supervisor
            -> Supervisor q
            -- ^ The 'supervised' supervisor
            -> IO ThreadId
monitorWith policy sup1 sup2 = do
  let sup1Children = _sc_children (_sp_ctx sup1)
  let sup1Mailbox  = _sc_mailbox (_sp_ctx sup1)
  let sup2Id = _sp_myTid sup2
  let sup2ParentMailbox = _sc_parent_mailbox (_sp_ctx sup2)

  readIORef sup2ParentMailbox >>= \mbox -> case mbox of
    Just _ -> return sup2Id -- Do nothing, this supervisor is already being monitored.
    Nothing -> do
      e <- getEpoch
      let sup2RetryStatus = defaultRetryStatus
      let ch' = Supvsr (ChildEpoch e) sup2RetryStatus policy sup2
      atomicModifyIORef' sup1Children $ \chMap -> (Map.insert sup2Id ch' chMap, ())
      duped <- atomically $ dupTChan sup1Mailbox
      atomicModifyIORef' sup2ParentMailbox $ const (Just duped, ())
      return sup2Id
