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

module Control.Concurrent.Supervisor
  ( SupervisorSpec
  , Supervisor
  , Child
  , newSupervisorSpec
  , newSupervisor
  , module T
  ) where

import Control.Concurrent.Supervisor.Types as T hiding (newSupervisor, newSupervisorSpec)
import qualified Control.Concurrent.Supervisor.Types as Types
import           Control.Concurrent.STM

type SupervisorSpec = Types.SupervisorSpec0 TQueue
type Supervisor = Types.Supervisor0 TQueue

--------------------------------------------------------------------------------
type Child = Types.Child_ TQueue

--------------------------------------------------------------------------------
-- | Creates a new 'SupervisorSpec'. The reason it doesn't return a
-- 'Supervisor' is to force you to call 'supervise' explicitly, in order to start the
-- supervisor thread.
newSupervisorSpec :: Types.RestartStrategy -> IO SupervisorSpec
newSupervisorSpec strategy = Types.newSupervisorSpec strategy 0

-- $supervise

--------------------------------------------------------------------------------
newSupervisor :: SupervisorSpec -> IO Supervisor
newSupervisor spec = Types.newSupervisor spec
