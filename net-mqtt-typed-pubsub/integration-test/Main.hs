{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Main (main, spec) where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception (IOException, throwIO)
import Control.Monad
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Catch
import Control.Retry
import Data.Aeson
import Data.Functor.Contravariant (contramap)
import Data.Maybe
import qualified Data.Text as T
import GHC.Generics
import qualified Network.MQTT.Connection as MQTT
import Network.MQTT.Typed.API
import qualified Network.MQTT.Typed.Publisher as Publisher
import qualified Network.MQTT.Typed.Subscriber as Subscriber
import Network.Socket.Free (getFreePort)
import Network.Socket.Wait as Wait (wait)
import Plow.Logging (IOTracer (..), traceWith)
import Plow.Logging.Async (withAsyncHandleTracer)
import System.FilePath ((</>))
import System.IO
import System.IO.Temp
import System.IO.Unsafe (unsafePerformIO)
import System.Process.Typed
import System.Timeout (timeout)
import Test.Hspec

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

data SensorReading = SensorReading
  { temperature :: Double,
    humidity :: Double,
    pressure :: Double
  }
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

mosquittoPort :: Int
mosquittoPort = unsafePerformIO getFreePort
{-# NOINLINE mosquittoPort #-}

mosquittoExe :: FilePath
mosquittoExe = "mosquitto"

mqttBrokerUri :: MQTT.URI
mqttBrokerUri = fromJust $ MQTT.parseURI ("mqtt://localhost:" <> show mosquittoPort)

main :: IO ()
main =
  withAsyncHandleTracer stdout 100 $ \tracer -> do
    let mosquittoTracer = contramap T.pack tracer
    hspec (around (withMosquitto mosquittoTracer mosquittoPort . (\f m -> f (m, tracer))) spec)

spec :: SpecWith (MosquittoHandle, IOTracer T.Text)
spec = do
  it "can publish and subscribe" $ \(_, tracer) ->
    withTestConnection tracer $ \subConn ->
      withTestConnection tracer $ \pubConn -> do
        var <- newEmptyMVar
        let subscriber a b c = putMVar var (a, b, c)
        let sensorId = 1
            timestamp = 21
            reading = SensorReading 4 5 6
        Subscriber.withAsyncSubscribeApi @SensorReadingApi subConn subscriber $ do
          env <- Publisher.mkPublisherEnv pubConn
          void $
            flip Publisher.runPublisherM env $
              Publisher.publisher @SensorReadingApi sensorId (Just timestamp) reading
          mVal <- timeout 1000000 $ takeMVar var
          case mVal of
            Just val -> val `shouldBe` (sensorId, Just timestamp, reading)
            Nothing -> expectationFailure "subscriber didn't get message"

  it "can do request/response" $ \(_, tracer) ->
    withTestConnection tracer $ \subConn ->
      withTestConnection tracer $ \pubConn -> do
        let subscriber = pure . uncurry divMod
        Subscriber.withAsyncSubscribeApi @DivModApi subConn subscriber $ do
          env <- Publisher.mkPublisherEnv pubConn
          eVal <-
            flip Publisher.runPublisherM env $
              Publisher.publisher @DivModApi (7, 3)
          case eVal of
            Right val -> val `shouldBe` (2, 1)
            Left err -> expectationFailure (show err)

withTestConnection ::
  (MonadIO m, MonadMask m) => IOTracer T.Text -> (MQTT.Connection -> m a) -> m a
withTestConnection rawTracer =
  MQTT.withConnection
    (MQTT.defaultSettings mqttBrokerUri)
      { MQTT.tracer = traceWith (contramap MQTT.showConnectionTrace rawTracer),
        MQTT.connectRetryPolicy = constantDelay 100000,
        MQTT.failFast = True
      }

type MosquittoHandle = Process () Handle Handle

withMosquitto ::
  IOTracer String ->
  Int ->
  (MosquittoHandle -> IO a) ->
  IO a
withMosquitto tracer p f = withSystemTempDirectory "mosquitto" $ \workDir -> do
  let configFile = workDir </> "mosquitto.conf"
  writeFile configFile mosquittoConf
  let procConfig = setWorkingDir workDir $ proc mosquittoExe ["-v", "-c", configFile]
  withNamedProcessTerm tracer "mosquitto" procConfig $ \h -> do
    traceWith tracer "waiting for mosquitto"
    Wait.wait "localhost" mosquittoPort
    traceWith tracer "mosquitto is up"
    f h
  where
    mosquittoConf =
      unlines
        [ "allow_anonymous true",
          "port " <> show p,
          "log_type debug"
        ]

withNamedProcessTerm ::
  IOTracer String ->
  String ->
  ProcessConfig stdin stdout stderr ->
  (Process () Handle Handle -> IO a) ->
  IO a
withNamedProcessTerm tracer name cfg f = do
  withProcessTermKillable (setStdout createPipe $ setStderr createPipe $ setStdin nullStream cfg) $ \p ->
    withAsync (forever (hGetLine (getStdout p) >>= \l -> traceWith tracer (name <> " (stdout): " <> l))) $ \_ ->
      withAsync (forever (hGetLine (getStderr p) >>= \l -> traceWith tracer (name <> " (stderr): " <> l))) $ \_ -> do
        mECode <- getExitCode p
        case mECode of
          Just eCode -> throwIO (userError ("Process " <> name <> " exited with " <> show eCode))
          Nothing -> f p

withProcessTermKillable ::
  ProcessConfig stdin stdout stderr ->
  (Process stdin stdout stderr -> IO a) ->
  IO a
withProcessTermKillable config =
  bracket (startProcess config) (flip catch (\(_ :: IOException) -> pure ()) . stopProcess)
