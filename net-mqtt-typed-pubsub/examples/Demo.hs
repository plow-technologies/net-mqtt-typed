{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Maybe (fromJust)
import GHC.Generics (Generic)
import Network.MQTT.Connection
  ( ProtocolLevel (Protocol50),
    Settings (..),
    defaultSettings,
    parseURI,
    withConnection,
  )
import Network.MQTT.Typed.API
  ( Capture,
    JSON,
    MsgBody,
    NoResponds,
    QoS (..),
    RespondsTo,
    UserProperty,
    WithQoS,
    (:<|>) (..),
    (:>),
  )
import Network.MQTT.Typed.Publisher
  ( PublisherM,
    mkPublisherEnv,
    publisher,
    runPublisherM,
  )
import Network.MQTT.Typed.Subscriber
  ( Subscriber,
    subscribeApi,
  )
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["server"] -> server
    ["client"] -> client
    _ -> die "Usage: net-mqtt-typed-demo (server | client)"

-- | The API type
type Api = DivModApi :<|> SensorReadingApi :<|> EchoApi

-- Declares an api where sensor readings are published to
-- "sensor/$sensorId" as -- a SensorReading JSON data structure.
-- Subscribers do not respond
type SensorReadingApi =
  "sensor"
    :> Capture "sensorId" Int
    :> UserProperty "timestamp" Int
    :> MsgBody JSON SensorReading
    :> NoResponds

-- Declares a request/response api where requests are published to
-- topic "calculator/divMod" as a JSON string with format (Int, Int)
-- and responses are published to the topic contained in the request's
-- response-topic MQTTv5 header as a JSON string with format (Int, Int)
-- A publisher for this API will publish messages as QoS2 and a subscriber
-- subscribe with a min priority of QoS2 to this topic.
type DivModApi =
  WithQoS 'QoS2
    :> "calculator"
    :> "divMod"
    :> MsgBody JSON (Int, Int)
    :> RespondsTo "calculator/responses" JSON (Int, Int)

-- This Api responds to a hard-coded topic, not the one requested in the
-- response-topic property
type EchoApi = "echo" :> MsgBody JSON String :> RespondsTo "topic/echos" JSON String

server :: IO ()
server = do
  let uri = fromJust $ parseURI "mqtt://localhost:56789#server"
  withConnection ((defaultSettings uri) {protocol = Protocol50, tracer = print}) $ \conn -> do
    subscribeApi @Api conn subscriber
  where
    subscriber :: Subscriber Api IO
    subscriber = divModSubscriber :<|> sensorReadingSubscriber :<|> pure

    sensorReadingSubscriber :: Int -> Maybe Int -> SensorReading -> IO ()
    sensorReadingSubscriber sensorId mTimestamp sensorReading =
      print (sensorId, mTimestamp, sensorReading)

    divModSubscriber :: (Int, Int) -> IO (Int, Int)
    divModSubscriber (a, b) = pure (a `divMod` b)

client :: IO ()
client = do
  let uri = fromJust $ parseURI "mqtt://localhost:56789#client"
  withConnection ((defaultSettings uri) {protocol = Protocol50, tracer = print}) $ \conn -> do
    env <- mkPublisherEnv conn
    let divMod' :: (Int, Int) -> PublisherM (Int, Int)
        sensorReading :: Int -> Maybe Int -> SensorReading -> PublisherM ()
        echo :: String -> PublisherM String
        divMod' :<|> sensorReading :<|> echo = publisher @Api
    print =<< runPublisherM (divMod' (5, 3)) env
    print =<< runPublisherM (sensorReading 1234 (Just 3) (SensorReading {temperature = 86.2, humidity = 0.67, pressure = 987.2})) env
    print =<< runPublisherM (echo "hello") env

data SensorReading = SensorReading
  { temperature :: Double,
    humidity :: Double,
    pressure :: Double
  }
  deriving (Show, Generic, ToJSON, FromJSON)
