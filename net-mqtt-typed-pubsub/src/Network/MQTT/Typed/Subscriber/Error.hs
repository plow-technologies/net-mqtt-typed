{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : Network.MQTT.Typed.Subscriber.Error
-- Copyright   : (c) Plow Technologies, 2020
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module defines the 'SubscriberError' type
module Network.MQTT.Typed.Subscriber.Error (SubscriberError (..)) where

import Control.DeepSeq (NFData)
import Control.Exception (Exception)
import Data.Text (Text)
import GHC.Generics (Generic)

data SubscriberError
  = NotFound
  | MissingResponseTopic
  | InvalidResponseTopic Text
  | InvalidCapture String Text
  | InvalidUserProperty String Text
  | InvalidMessage Text
  | CaptureNotFound
  | UnhandledException String
  deriving (Eq, Show, Ord, Exception, Generic, NFData)
