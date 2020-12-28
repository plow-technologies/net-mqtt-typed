{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Network.MQTT.Typed.Publisher.Request
-- Copyright   : (c) Plow Technologies, 2020
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module defines the 'Request' datatype which can be used to 'publish' a
-- message to a MQTT topic using a 'MTTQClient'
module Network.MQTT.Typed.Publisher.Request
  ( Request,
    emptyRequest,
    setPath,
    setBody,
    setRetain,
    setQoS,
    setProps,
    appendToProps,
    appendToPath,
    appendCapture,
    publish,
    rCaptureMap,
  )
where

import qualified Data.ByteString.Lazy as LBS
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Network.MQTT.Connection (Connection)
import qualified Network.MQTT.Connection (publish)
import Network.MQTT.Typed.Subscriber.Topic (CaptureMap, CaptureVar (..))
import Network.MQTT.Types (Property, QoS (..))

-- | A 'Request' that can be published
data Request = Request
  { rTopicPathReversed :: [Text],
    rBody :: LBS.ByteString,
    rRetain :: Bool,
    rQoS :: QoS,
    rPropsReversed :: [Property],
    rCaptureMap :: CaptureMap
  }

-- | An empty request
emptyRequest :: Request
emptyRequest = Request mempty mempty False QoS0 mempty mempty

-- | appends a segment to the topic path
appendToPath :: Text -> Request -> Request
appendToPath p req = req {rTopicPathReversed = p : rTopicPathReversed req}

-- | appends a capture
appendCapture :: CaptureVar -> Request -> Request
appendCapture p req = req {rCaptureMap = p : rCaptureMap req}

-- | Sets the body of the 'Request'
setBody :: LBS.ByteString -> Request -> Request
setBody p req = req {rBody = p}

-- | Sets the full topic path
setPath :: Text -> Request -> Request
setPath p req = req {rTopicPathReversed = reverse (T.split (== '/') p)}

-- | Sets or clears the "retain" bit of the 'Request'
setRetain :: Bool -> Request -> Request
setRetain x req = req {rRetain = x}

-- | Sets the 'QoS' field of the 'Request'
setQoS :: QoS -> Request -> Request
setQoS x req = req {rQoS = x}

-- | Appends a 'Property' to the 'Request'
appendToProps :: Property -> Request -> Request
appendToProps p req = req {rPropsReversed = p : rPropsReversed req}

-- | Sets the list 'Property' s of the 'Request'
setProps :: [Property] -> Request -> Request
setProps p req = req {rPropsReversed = reverse p}

-- | Publishes a 'Request' using a 'MQTTClient'
publish :: Connection -> Request -> IO ()
publish mc Request {rTopicPathReversed, rBody, rRetain, rQoS, rPropsReversed} = do
  let topic = fromString $ T.unpack $ T.intercalate "/" (reverse rTopicPathReversed)
  Network.MQTT.Connection.publish mc topic rBody rRetain rQoS (reverse rPropsReversed)
