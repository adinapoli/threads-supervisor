
{-
  Humble module inspired to Erlang supervisors,
  with minimal dependencies.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Control.Concurrent.Supervisor 
  ( Supervisor
  , DeadLetter
  , Child(..)
  , RestartAction
  , SupervisionEvent(..)
  , RestartStrategy(..)
  , newSupervisor
  , shutdownSupervisor
  , eventStream
  , activeChildren
  , supervise
  , forkSupervised
  ) where

import qualified Data.HashMap.Strict as Map
import           Control.Concurrent
import           Control.Concurrent.STM
import           Data.IORef
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
      , _ns_mailbox :: TQueue DeadLetter
      , _ns_eventStream :: TBQueue SupervisionEvent
      } -> Supervisor_ Uninitialised
     Supervisor :: {
        _sp_myTid    :: !(Maybe ThreadId)
      , _sp_children :: !(IORef (Map.HashMap ThreadId Child))
      , _sp_mailbox :: TQueue DeadLetter
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

--------------------------------------------------------------------------------
-- | Creates a new supervisor
newSupervisor :: IO SupervisorSpec
newSupervisor = do
  tkn <- newTQueueIO
  evt <- newTBQueueIO 1000
  ref <- newIORef Map.empty
  return $ NewSupervisor Nothing ref tkn evt

--------------------------------------------------------------------------------
eventStream :: Supervisor -> TBQueue SupervisionEvent
eventStream (Supervisor _ _ _ e) = e

--------------------------------------------------------------------------------
activeChildren :: Supervisor -> IO Int
activeChildren (Supervisor _ chRef _ _) = do
  readIORef chRef >>= return . length . Map.keys

--------------------------------------------------------------------------------
-- | Shutdown the given supervisor. This will cause the supervised children to
-- be killed as well.
shutdownSupervisor :: Supervisor -> IO ()
shutdownSupervisor (Supervisor sId chRef _ _) = do
  case sId of 
    Nothing -> return ()
    Just tid -> do
      readIORef chRef >>= \chMap -> forM_ (Map.keys chMap) killThread
      killThread tid

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
    writeTQueue _sp_mailbox (DeadLetter myId ex)
  Right _ -> bracket myThreadId return $ \myId -> do
    now <- getCurrentTime
    atomicModifyIORef' _sp_children $ \chMap -> (Map.delete myId chMap, ())
    writeIfNotFull _sp_eventStream (ChildFinished myId now)

--------------------------------------------------------------------------------
supervise :: SupervisorSpec -> IO Supervisor
supervise spec = forkIO (go spec) >>= \tid -> return $ Supervisor {
    _sp_myTid = Just tid
  , _sp_mailbox = _ns_mailbox spec
  , _sp_children = _ns_children spec
  , _sp_eventStream = _ns_eventStream spec
  }
  where
   go :: SupervisorSpec -> IO ()
   go sp@NewSupervisor{..} = do
     (DeadLetter newDeath ex) <- atomically $ readTQueue _ns_mailbox
     now <- getCurrentTime
     writeIfNotFull _ns_eventStream (ChildDied newDeath ex now)
     case asyncExceptionFromException ex of
       Just ThreadKilled -> go sp
       _ -> do
        chMap <- readIORef _ns_children
        case Map.lookup newDeath chMap of
          Nothing -> go sp
          Just ch@(Worker str act) -> case str of
            OneForOne -> do
              newThreadId <- act newDeath
              writeIORef _ns_children (Map.insert newThreadId ch $! Map.delete newDeath chMap)
              writeIfNotFull _ns_eventStream (ChildRestarted newDeath newThreadId str now)
              go sp
          Just ch@(Supvsr str (Supervisor _ mbx cld es)) -> case str of
            OneForOne -> do
              newThreadId <- forkIO (go $ NewSupervisor Nothing mbx cld es)
              writeIORef _ns_children (Map.insert newThreadId ch $! Map.delete newDeath chMap)
              writeIfNotFull _ns_eventStream (ChildRestarted newDeath newThreadId str now)
              go sp
