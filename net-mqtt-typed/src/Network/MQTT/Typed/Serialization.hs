{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- |
-- Module      : Network.MQTT.Typed.Serialization
-- Copyright   : (c) Plow Technologies, 2020
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module defines the types used to define MQTT de/serialization encodings
module Network.MQTT.Typed.Serialization (Serializable (..), Deserializable (..), JSON, CEREAL, RAW) where

import qualified Data.Aeson as Aeson
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Serialize as Cereal
import Data.Text (Text)
import qualified Data.Text as T

-- | This encoding denotes raw ByteString format
data RAW

-- | This encoding denotes JSON format
data JSON

-- | This encoding denotes de/serialization as performed by cereal's
-- 'Data.Serialize.Serialize' instance
data CEREAL

-- | This typeclass denotes how 'encoding' serializes a type 'a'. It is meant
-- to be used with TypeApplications, example:
--
-- @
-- serialize @JSON (Foo 1 2 4)
-- @
class Serializable encoding a where
  serialize :: a -> LBS.ByteString

-- | This typeclass denotes how 'encoding' deserializes a type 'a'. It is meant
-- to be used with TypeApplications, example:
--
-- @
-- deserialize @JSON "[1, 2, 4]"
-- @
class Deserializable encoding a where
  deserialize :: LBS.ByteString -> Either Text a

instance Serializable RAW LBS.ByteString where
  serialize = id

instance Deserializable RAW LBS.ByteString where
  deserialize = Right

instance Aeson.ToJSON a => Serializable JSON a where
  serialize = Aeson.encode . Aeson.toJSON

instance Aeson.FromJSON a => Deserializable JSON a where
  deserialize = first T.pack . Aeson.eitherDecode

instance Cereal.Serialize a => Serializable CEREAL a where
  serialize = Cereal.encodeLazy

instance Cereal.Serialize a => Deserializable CEREAL a where
  deserialize = first T.pack . Cereal.decodeLazy
