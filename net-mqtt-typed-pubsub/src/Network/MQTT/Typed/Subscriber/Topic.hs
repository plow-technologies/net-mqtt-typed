{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

-- |
-- Module      : Network.MQTT.Typed.Subscriber.Topic
-- Copyright   : (c) Plow Technologies, 2020-2021
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module defines the 'ToTopics' typeclass and 'topicsForApi' function
module Network.MQTT.Typed.Subscriber.Topic
  ( ToTopics (..),
    State (..),
    CaptureVar (..),
    CaptureMap,
    ToResponseTopic (..),
    topicsForApi,
    topicsForApiWith,
    mkTopic',
    mkFilter',
    toMqttQos,
  )
where

import Data.List as L
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (Proxy))
import Data.Singletons (SingI, demote)
import Data.String (fromString)
import qualified Data.Text as T
import GHC.TypeLits (KnownSymbol, symbolVal)
import Network.MQTT.Client (SubOptions (..), subOptions)
import Network.MQTT.Topic (Filter, Topic, mkFilter, mkTopic, toFilter, unFilter)
import Network.MQTT.Typed.API
import qualified Network.MQTT.Types as MQTT

-- | This typeclass is used to compute all the topics (with wildcards) that
-- an API subscribes to. It is exported so new API types can be defined by
-- users of this library.
class ToTopics api where
  topicsForApi' :: CaptureMap -> State -> [State]

data State = State
  { path :: [Filter],
    subscriptionOptions :: SubOptions
  }

data CaptureVar where
  (:=) :: MqttApiData a => Topic -> a -> CaptureVar
  (:=..) :: MqttApiData a => Topic -> [a] -> CaptureVar

type CaptureMap = [CaptureVar]

lookupVar :: Topic -> CaptureMap -> Maybe Topic
lookupVar k = L.lookup k . map go
  where
    go (k' := v) = (k', toTopicPiece' v)
    go (k' :=.. v) = (k', toTopicPieces' v)

    toTopicPiece' :: MqttApiData a => a -> Topic
    toTopicPiece' = fromString . T.unpack . toTopicPiece
    toTopicPieces' :: MqttApiData a => [a] -> Topic
    toTopicPieces' = fromString . T.unpack . T.intercalate "/" . toTopicPieces

initialState :: State
initialState = State [] subOptions

topicsForApi :: forall api. ToTopics api => [(Filter, SubOptions)]
topicsForApi = topicsForApiWith @api mempty

topicsForApiWith :: forall api. ToTopics api => CaptureMap -> [(Filter, SubOptions)]
topicsForApiWith captures =
  map (\s -> (stateToFilter s, subscriptionOptions s)) $
    topicsForApi' @api captures initialState
  where
    stateToFilter = fromString . T.unpack . T.intercalate "/" . map unFilter . reverse . path

instance ToTopics (RespondsTo' a (b :: k) c d) where
  topicsForApi' _ (State [] so) = [State ["#"] so]
  topicsForApi' _ x = [x]

instance ToTopics NoResponds where
  topicsForApi' _ x = [x]

instance ToTopics EmptyAPI where
  topicsForApi' _ _ = []

instance (SingI qos, ToTopics api) => ToTopics (WithQoS qos :> api) where
  topicsForApi' cm x = topicsForApi' @api cm x {subscriptionOptions = (subscriptionOptions x) {_subQoS = toMqttQos (demote @qos)}}

instance ToTopics api => ToTopics (WithRetain :> api) where
  topicsForApi' = topicsForApi' @api

instance ToTopics api => ToTopics (WithNoLocal :> api) where
  topicsForApi' cm x = topicsForApi' @api cm x {subscriptionOptions = (subscriptionOptions x) {_noLocal = True}}

instance ToTopics api => ToTopics (MsgBody encoding a :> api) where
  topicsForApi' = topicsForApi' @api

instance ToTopics api => ToTopics (UserProperty a b :> api) where
  topicsForApi' = topicsForApi' @api

instance (KnownSymbol sym, ToTopics api) => ToTopics (Capture sym a :> api) where
  topicsForApi' cm x = topicsForApi' @api cm x {path = maybe (mkFilter' @"+") toFilter (mkTopic' @sym `lookupVar` cm) : path x}

instance (KnownSymbol sym, ToTopics api) => ToTopics (CaptureAll sym a :> api) where
  topicsForApi' cm x = topicsForApi' @api cm x {path = maybe (mkFilter' @"#") toFilter (mkTopic' @sym `lookupVar` cm) : path x}

instance (ToTopics api, KnownSymbol path) => ToTopics (path :> api) where
  topicsForApi' cm x = topicsForApi' @api cm x {path = mkFilter' @path : path x}

instance (ToTopics a, ToTopics b) => ToTopics (a :<|> b) where
  topicsForApi' cm x = topicsForApi' @a cm x <> topicsForApi' @b cm x

class ToResponseTopic (a :: k) where
  toResponseTopic :: Proxy a -> CaptureMap -> Maybe Topic

instance KnownSymbol a => ToResponseTopic a where
  toResponseTopic _ _ = pure $ mkTopic' @a

instance KnownSymbol a => ToResponseTopic (Captured a) where
  toResponseTopic _ = lookupVar (mkTopic' @a)

instance (ToResponseTopic a, ToResponseTopic b) => ToResponseTopic (a :> b) where
  toResponseTopic _ cMap = do
    a <- toResponseTopic (Proxy @a) cMap
    b <- toResponseTopic (Proxy @b) cMap
    pure (a <> b)

-- TODO: Validate topic and filters at type level if reasonable
mkTopic' :: forall a. KnownSymbol a => Topic
mkTopic' = fromMaybe (error "FIXME: invalid mkTopic'") $ mkTopic $ T.pack $ symbolVal (Proxy @a)

mkFilter' :: forall a. KnownSymbol a => Filter
mkFilter' = fromMaybe (error "FIXME: invalid mkFilter'") $ mkFilter $ T.pack $ symbolVal (Proxy @a)

toMqttQos :: QoS -> MQTT.QoS
toMqttQos QoS0 = MQTT.QoS0
toMqttQos QoS1 = MQTT.QoS1
toMqttQos QoS2 = MQTT.QoS2
