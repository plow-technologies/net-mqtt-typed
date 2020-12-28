{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}

#if __GLASGOW_HASKELL__ > 900
{-# LANGUAGE StandaloneKindSignatures #-}
#endif

-- |
-- Module      : Network.MQTT.Typed.API
-- Copyright   : (c) Plow Technologies, 2020
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module defines the types used to define MQTT subscriber and
-- publisher APIs
module Network.MQTT.Typed.API
  ( (:>),
    (:<|>) (..),
    EmptyAPI (..),
    RespondsTo,
    RespondsTo',
    NoResponds,
    Capture,
    CaptureAll,
    Captured,
    MsgBody,
    UserProperty,
    QoS (..),
    WithQoS,
    FoldWithQoS,
    WithRetain,
    WithNoLocal,
    FoldWithRetain,
    toTopicPieces,
    parseTopicPieces,
    MqttApiData (..),
    module ReExport,
  )
where

import Data.Int
import Data.Kind (Type)
import Data.Singletons.TH (genSingletons)
import Data.Text (Text)
import qualified Data.Text.Lazy
import Data.Time
import Data.UUID (UUID)
import Data.Version (Version)
import Data.Void (Void)
import Data.Word
import GHC.Generics (Generic)
import GHC.TypeLits
  ( Symbol,
  )
import Network.MQTT.Typed.Serialization as ReExport
import Web.HttpApiData (FromHttpApiData (parseUrlPiece), ToHttpApiData (toUrlPiece))

class MqttApiData a where
  toTopicPiece :: a -> Text
  parseTopicPiece :: Text -> Either Text a

  default toTopicPiece :: ToHttpApiData a => a -> Text
  toTopicPiece = toUrlPiece

  default parseTopicPiece :: FromHttpApiData a => Text -> Either Text a
  parseTopicPiece = parseUrlPiece

toTopicPieces :: (Functor t, MqttApiData a) => t a -> t Text
toTopicPieces = fmap toTopicPiece

parseTopicPieces :: (Traversable t, MqttApiData a) => t Text -> Either Text (t a)
parseTopicPieces = traverse parseTopicPiece

data (path :: k) :> (a :: k2)

infixr 4 :>

-- | This type is used to combine two topic subscribers/publishers
data a :<|> b = a :<|> b
  deriving (Eq, Show, Functor, Traversable, Foldable, Bounded)

infixr 3 :<|>

-- | A Convenience alias to RespondsTo' with no options
type RespondsTo = RespondsTo' '[]

-- | The subscriber to this topic publishes a response to a hard-coded
-- topic 'opts' is a type-level list of modfifiers to how the response message will
-- be published. See 'WithRetain' and 'WithQoS'.
--
-- Examples:
--
-- A subscriber that will listen to "#" (all topics) capturing all the
-- topic path parts.
-- It will publish a response to the "topic/responses" topic as a json-encoded
-- list of strings.
-- It will also forward any correlation-data property in the request as a
-- property of the response.
--
-- This request/response pattern is supported by MQTT v3
--
-- @
--  type MyApi = CaptureAll "topic" Text
--            :> RespondsTo' "topics/responses" '[WithRetain] JSON [Text]
-- @
data RespondsTo' (opts :: [Type]) (responseTopic :: k) (encoding :: Type) (a :: Type)

-- | The subscriber to this topic does not publish any response
data NoResponds

-- | This modifier can be used as a route fragment to denote that the publisher
-- to this topic will set the "retain" flag on when publishing messages.
-- It can be also used as the 'opts' in Responds' and RespondsTo' to denote that
-- the response messages will be published with the "retain" flag on
--
-- Examples:
--
-- Messages to "topic/sensor" will be published with the retain flag on
-- @
--   type Api = WithRetain :> "topic" :> "sensor" :> Responds JSON Int
-- @
--
-- Responses to requests published to "topic/sensor" will be published
-- with the retain flag on
-- @
--   type Api = "topic" :> "sensor" :> Responds' '[WithRetain] JSON Int
-- @
data WithRetain

-- | This modifier can be used as a route fragment to denote that the subscriber
-- to this topic shall not receive messages posted by the same client
--
-- Examples:
--
-- Messages to "topic/sensor" will not be listened to if initiated by the same
-- client
-- @
--   type Api = WithNoLocal :> "topic" :> "sensor" :> Responds JSON Int
-- @
data WithNoLocal

-- | This modifier can be used as a route fragment to denote that the publisher
-- to this topic will set the QoS flag to the given value on when publishing
-- messages. The subscriber will request this QoS level when subscribing to this
-- topic.
-- It can be also used as the 'opts' in Responds' and RespondsTo' to denote that
-- the response messages will be published with the given QoS.
--
-- Examples:
--
-- Messages to "topic/sensor" will be published and subscribed to with QoS1
-- @
--   type Api = WithQoS 'QoS1 :> "topic" :> "sensor" :> Responds JSON Int
-- @
--
-- Responses to requests published to "topic/sensor" will be published and
-- subscribed to with QoS2
-- @
--   type Api = "topic" :> "sensor" :> Responds' '[WithQoS 'QoS2] JSON Int
-- @
data WithQoS (qos :: QoS)

-- | The subscriber to this topic is a function that will receive a parameter
-- of type 'a' (which must have a FromMqttApiData instance) which is decoded
-- from the topic path segment at this position. When subscribing to this topic
-- a MQTT '+' wildcard will be used at this position.
-- The publisher to this topic will have a parameter which will be encoded
-- (with ToMqttApiData) and rendered into this path segment
--
-- Examples:
--
-- The subscriber to "topic/sensor/+/+" will receive '"hall"' as the
-- first argument and '"temperature"' as the second one when a message is
-- published to "topic/sensor/hall/temperature"
-- @
--  type Api = "topic" :> "sensor"
--           :> Capture "location" Text :> Capture "variable" Text
--           :> NoResponds
-- @
data Capture (sym :: Symbol) (a :: Type)

-- | For use with 'RespondsTo'. Will interpolate in the response topic a
-- variable captured with 'Capture' or 'CaptureAll'
-- Examples:
--
-- The subscriber to "topic/sensor/+/+" will receive '"hall"' as the
-- first argument and '"temperature"' as the second one when a message is
-- published to "topic/sensor/hall/temperature" and will respond to the
-- "responses/hall" topic
-- @
--  type Api = "topic" :> "sensor"
--           :> Capture "location" Text :> Capture "variable" Text
--           :> RespondsTo ("responses" :> Captured "location")
-- @
data Captured (sym :: Symbol)

-- | The subscriber to this topic is a function that will receive a parameter
-- of type '[a]' (which must have a FromMqttApiData instance) which is decoded
-- from the topic path segments from this position to the end.
-- When subscribing to this topic a MQTT '#' wildcard will be used at this
-- position.
-- The publisher to this topic will have a list parameter which will be encoded
-- (with ToMqttApiData) and rendered into this path segment
--
-- Examples:
--
-- The subscriber to "topic/sensor/#" will receive '["hall", "temperature"]'
-- as the first argument when a message is
-- published to "topic/sensor/hall/temperature"
-- @
--  type Api = "topic" :> "sensor"
--           :> CaptureAll "path" Text
--           :> NoResponds
-- @
data CaptureAll (sym :: Symbol) (a :: Type)

-- | The subscriber to this topic is a function that will receive a parameter
-- of type 'a' which is decoded from the message body using the encoding
-- denoted by 'encoding'
-- The publisher to this topic will have a parameter which will be encoded
-- as the message body with the encoding denoted by 'encoding'
--
-- Examples:
--
-- The subscriber to "topic/sensor" will receive 'SensorReading' as
-- first argument which will be decoded from the message body using
-- 'FromJSON'
-- @
--  type Api = "topic" :> "sensor"
--           :> MsgBody JSON SensorReading
--           :> NoResponds
-- @
data MsgBody (encoding :: Type) (a :: Type)

-- | The subscriber to this topic is a function that will receive a parameter
-- of type 'Maybe a' (which must have a FromHttpApiData instance) which is
-- decoded from 'user-property' message propery with name 'sym'.
-- The publisher to this topic will have a parameter which will be encoded
-- (with ToMqttApiData) and rendered into this 'user-property'
--
-- Examples:
--
-- The subscriber to "topic/sensor" will receive 'Just "hall"' as the
-- first argument when the message contains the user-property with name
-- "location" and value "hall"
-- @
--  type Api = "topic" :> "sensor"
--           :> UserProperty "location" Text
--           :> NoResponds
-- @
data UserProperty (sym :: Symbol) (a :: Type)

-- | QoS values for publishing and subscribing.
data QoS = QoS0 | QoS1 | QoS2 deriving (Bounded, Enum, Eq, Show, Ord, Generic)

$(genSingletons [''QoS])

type FoldWithQoS mods = FoldWithQoS' 'QoS0 mods

type family FoldWithQoS' (acc :: QoS) (mods :: [Type]) :: QoS where
  FoldWithQoS' acc '[] = acc
  FoldWithQoS' acc (WithQoS qos ': mods) = FoldWithQoS' qos mods
  FoldWithQoS' acc (mod ': mods) = FoldWithQoS' acc mods

type FoldWithRetain mods = FoldWithRetain' 'False mods

type family FoldWithRetain' (acc :: Bool) (mods :: [Type]) :: Bool where
  FoldWithRetain' acc '[] = acc
  FoldWithRetain' acc (WithRetain ': mods) = FoldWithRetain' 'True mods
  FoldWithRetain' acc (mod ': mods) = FoldWithRetain' acc mods

-- | An empty API: one which serves nothing. Morally speaking, this should be
-- the unit of ':<|>'. Implementors of interpretations of API types should
-- treat 'EmptyAPI' as close to the unit as possible.
data EmptyAPI = EmptyAPI deriving (Eq, Show, Bounded, Enum)

--
-- Common MqttApiData instances
instance MqttApiData Bool

instance MqttApiData Char

instance MqttApiData Double

instance MqttApiData Float

instance MqttApiData Int

instance MqttApiData Int8

instance MqttApiData Int16

instance MqttApiData Int32

instance MqttApiData Int64

instance MqttApiData Word

instance MqttApiData Word8

instance MqttApiData Word16

instance MqttApiData Word32

instance MqttApiData Word64

instance MqttApiData ()

instance MqttApiData Data.Text.Text

instance MqttApiData Data.Text.Lazy.Text

instance MqttApiData String

instance MqttApiData Void

instance MqttApiData Version

instance MqttApiData UTCTime

instance MqttApiData ZonedTime

instance MqttApiData LocalTime

instance MqttApiData TimeOfDay

instance MqttApiData NominalDiffTime

instance MqttApiData DayOfWeek

instance MqttApiData Day

instance MqttApiData UUID
