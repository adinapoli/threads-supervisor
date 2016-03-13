{-|
  This module offers a `Bounded` supervisor variant,
  where `SupervisionEvent`(s) are written on a `TBQueue`,
  and simply discarded if the queue is full.
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Control.Concurrent.Supervisor.Bounded
  ( Supervisor
  , Child
  , newSupervisor
  , defaultEventQueueSize
  , module T
  ) where

import           Control.Concurrent.STM
import           Control.Concurrent.Supervisor.Types as T hiding (Supervisor, newSupervisor)
import qualified Control.Concurrent.Supervisor.Types as Types

type Supervisor = Types.Supervisor TBQueue

--------------------------------------------------------------------------------
type Child = Types.Child_ TBQueue

--------------------------------------------------------------------------------
-- | The default size of the queue where `SupervisionEvent`(s) are written.
defaultEventQueueSize :: Int
defaultEventQueueSize = 10000

--------------------------------------------------------------------------------
newSupervisor :: RestartStrategy -> Int -> IO Supervisor
newSupervisor = Types.newSupervisor
