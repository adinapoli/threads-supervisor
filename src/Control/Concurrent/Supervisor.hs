{-
  Humble module inspired to Erlang supervisors,
  with minimal dependencies.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Control.Concurrent.Supervisor
  ( Supervisor
  , Child
  , newSupervisor
  , module T
  ) where

import           Control.Concurrent.STM
import           Control.Concurrent.Supervisor.Types as T hiding (Supervisor, newSupervisor)
import qualified Control.Concurrent.Supervisor.Types as Types

type Supervisor = Types.Supervisor TQueue

--------------------------------------------------------------------------------
type Child = Types.Child_ TQueue

--------------------------------------------------------------------------------
-- NOTE: The `maxBound` value will be ignore by the underlying implementation.
newSupervisor :: RestartStrategy -> IO Supervisor
newSupervisor str = Types.newSupervisor str maxBound 
