{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}

-- |
-- Module      : Network.MQTT.Typed.Subscriber.PublishResponse
-- Copyright   : (c) Plow Technologies, 2020
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module defines the 'PublishResponse' type
module Network.MQTT.Typed.Subscriber.PublishResponse (PublishResponse (..)) where

import Control.DeepSeq (NFData (..))
import qualified Data.ByteString.Lazy as LBS
import Network.MQTT.Client
import Network.MQTT.Topic (unTopic)

-- | The subscriber may return a value of this type to signal that it wants
-- to respond to a message
data PublishResponse = PublishResponse
  { prTopic :: !Topic,
    prBody :: !LBS.ByteString,
    prRetain :: !Bool,
    prQoS :: !QoS,
    prProps :: ![Property]
  }
  deriving (Show, Eq)

instance NFData PublishResponse where
  rnf PublishResponse {prTopic, prBody, prRetain, prQoS, prProps} =
    rnf (unTopic prTopic) `seq`
      rnf prBody `seq`
        rnf prRetain `seq`
          case prQoS of { _ -> () } `seq`
            rnf (map rnfProperty prProps) `seq`
              ()

rnfProperty :: Property -> ()
rnfProperty p = case p of
  PropPayloadFormatIndicator x -> rnf x `seq` ()
  PropMessageExpiryInterval x -> rnf x `seq` ()
  PropContentType x -> rnf x `seq` ()
  PropResponseTopic x -> rnf x `seq` ()
  PropCorrelationData x -> rnf x `seq` ()
  PropSubscriptionIdentifier x -> rnf x `seq` ()
  PropSessionExpiryInterval x -> rnf x `seq` ()
  PropAssignedClientIdentifier x -> rnf x `seq` ()
  PropServerKeepAlive x -> rnf x `seq` ()
  PropAuthenticationMethod x -> rnf x `seq` ()
  PropAuthenticationData x -> rnf x `seq` ()
  PropRequestProblemInformation x -> rnf x `seq` ()
  PropWillDelayInterval x -> rnf x `seq` ()
  PropRequestResponseInformation x -> rnf x `seq` ()
  PropResponseInformation x -> rnf x `seq` ()
  PropServerReference x -> rnf x `seq` ()
  PropReasonString x -> rnf x `seq` ()
  PropReceiveMaximum x -> rnf x `seq` ()
  PropTopicAliasMaximum x -> rnf x `seq` ()
  PropTopicAlias x -> rnf x `seq` ()
  PropMaximumQoS x -> rnf x `seq` ()
  PropRetainAvailable x -> rnf x `seq` ()
  PropUserProperty x y -> rnf x `seq` rnf y `seq` ()
  PropMaximumPacketSize x -> rnf x `seq` ()
  PropWildcardSubscriptionAvailable x -> rnf x `seq` ()
  PropSharedSubscriptionAvailable x -> rnf x `seq` ()
  PropSubscriptionIdentifierAvailable x -> rnf x `seq` ()
