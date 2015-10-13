{-|
  This module offers a `Bounded` supervisor variant,
  where `SupervisionEvent`(s) are written on a `TBQueue`,
  and simply discarded if the queue is full.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Control.Concurrent.Supervisor.Bounded
  ( SupervisorSpec
  , Supervisor
  , Child
  , newSupervisorSpec
  , newSupervisorSpecBounded
  , newSupervisor
  , module T
  ) where

import Control.Concurrent.Supervisor.Types as T hiding (newSupervisor, newSupervisorSpec)
import qualified Control.Concurrent.Supervisor.Types as Types
import           Control.Concurrent.STM

type SupervisorSpec = Types.SupervisorSpec0 TBQueue
type Supervisor = Types.Supervisor0 TBQueue

--------------------------------------------------------------------------------
type Child = Types.Child_ TBQueue

--------------------------------------------------------------------------------
-- | Creates a new 'SupervisorSpec'. The reason it doesn't return a
-- 'Supervisor' is to force you to call 'supervise' explicitly, in order to start the
-- supervisor thread.
newSupervisorSpec :: IO SupervisorSpec
newSupervisorSpec = Types.newSupervisorSpec defaultEventQueueSize

--------------------------------------------------------------------------------
-- | Like 'newSupervisorSpec', but give the user control over the size of the
-- event queue.
newSupervisorSpecBounded :: Int -> IO SupervisorSpec
newSupervisorSpecBounded = Types.newSupervisorSpec

--------------------------------------------------------------------------------
-- | The default size of the queue where `SupervisionEvent`(s) are written.
defaultEventQueueSize :: Int
defaultEventQueueSize = 10000

-- $supervise

--------------------------------------------------------------------------------
newSupervisor :: SupervisorSpec -> IO Supervisor
newSupervisor spec = Types.newSupervisor spec
