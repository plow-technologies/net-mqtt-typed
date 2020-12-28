{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Network.MQTT.Typed.Publisher
-- Copyright   : (c) Plow Technologies, 2020
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module defines the 'HasPublisher' typeclass which is used to create
-- functions that can be used to publish messages to the topics of an API.
--
-- It is exported so users of the library can defined their own API types.
module Network.MQTT.Typed.Publisher
  ( -- * For typical use
    publisher,
    PublisherM,
    runPublisherM,
    mkPublisherEnv,
    PublisherError (..),

    -- * To customize environment
    PublisherEnv,
    setGenCorrelationData,
    setResponseTimeout,

    -- * Used to implement custom API types
    HasPublisher (..),
  )
where

import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    writeTVar,
  )
import Control.Concurrent.STM.TMVar
  ( newEmptyTMVarIO,
    putTMVar,
    takeTMVar,
  )
import Control.Monad (join, void, when)
import Control.Monad.Catch
  ( Exception,
    MonadCatch,
    MonadThrow,
    bracket_,
    throwM,
    try,
  )
import Control.Monad.Error.Class
  ( MonadError (..),
  )
import Control.Monad.Except
  ( ExceptT (..),
    runExceptT,
  )
import Control.Monad.IO.Class
  ( MonadIO (..),
  )
import Control.Monad.IO.Unlift
  ( MonadUnliftIO,
    withRunInIO,
  )
import Control.Monad.Reader
  ( MonadReader,
    ReaderT (..),
    asks,
    runReaderT,
  )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.ByteString.Random (random)
import Data.Kind (Type)
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Proxy (Proxy (..))
import Data.Singletons (SingI, demote)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import GHC.Generics (Generic)
import GHC.TypeLits (KnownSymbol, symbolVal)
import Network.MQTT.Client
  ( MessageCallback (LowLevelCallback),
    Property (PropCorrelationData, PropResponseTopic, PropUserProperty),
    SubOptions (_subQoS),
    Topic,
    registerCorrelated,
    subOptions,
    subscribe,
    unregisterCorrelated,
    unsubscribe,
  )
import Network.MQTT.Connection (Connection, withClient)
import Network.MQTT.Topic (Filter, toFilter, unFilter)
import Network.MQTT.Typed.API
import Network.MQTT.Typed.Publisher.Request
  ( Request,
    appendCapture,
    appendToPath,
    appendToProps,
    emptyRequest,
    publish,
    rCaptureMap,
    setBody,
    setQoS,
    setRetain,
  )
import Network.MQTT.Typed.Subscriber.Topic (CaptureVar (..), ToResponseTopic (..), mkTopic', toMqttQos)
import Network.MQTT.Types
  ( PublishRequest (PublishRequest, _pubBody),
  )
import System.Timeout (timeout)

-- | This is the environment used to run 'PublisherM' actions.
-- The constructor is exported so you can modify how it generates
-- correlation-data identifiers or how to computes the response-topic used
-- to receive replies
data PublisherEnv = PublisherEnv
  { -- | Returns the 'MQTTClient' used to publish requests and subscribe to responses.
    mqttClient :: Connection,
    -- | Generates a random string to associate responses to originating
    -- requests
    genCorrelationData :: PublisherM BS.ByteString,
    -- | In microseconds (like threadDelay)
    responseTimeout :: Int,
    numSuscriptions :: TVar (Map Filter Int)
  }

-- | Construct a 'PublisherEnv' ro run 'PublisherM' actions given a
-- 'MQTTClient'.
-- This 'PublisherEnv' may be further customized using the functions to do so in
-- this module.
mkPublisherEnv :: Connection -> IO PublisherEnv
mkPublisherEnv mqttClient = do
  numSuscriptions <- newTVarIO mempty
  pure
    PublisherEnv
      { mqttClient,
        genCorrelationData = liftIO $ Data.ByteString.Random.random 32,
        responseTimeout = 5000000,
        numSuscriptions
      }

-- | Set a PublisherM action that will generate a unqiue bytestring to use as
-- the correlation-data property to instruct listener to publish the response
-- with the same header so we can correlate requests and responses
setGenCorrelationData :: PublisherM BS.ByteString -> PublisherEnv -> PublisherEnv
setGenCorrelationData genCorrelationData x = x {genCorrelationData}

-- | Set the timeout in microseconds that we will listen for a response on the
-- response topic
setResponseTimeout :: Int -> PublisherEnv -> PublisherEnv
setResponseTimeout responseTimeout x = x {responseTimeout}

--  | The possible errors that a 'PublisherM' can return. Note that 'PublisherM'
--  can also raise exceptions from the low-level layers. This error is the only
--  one that this module will produce though and will return it on the 'Left'
--  side by 'runPublisherM'
data PublisherError = InvalidResponseBody Text | CaptureNotFound | ResponseTimeout
  deriving (Show)

instance Exception PublisherError

-- | The 'Monad' where publisher actions execute. Use 'runPublisherM' to execute
-- them with a 'PublisherEnv' created with 'mkPublisherEnv'
newtype PublisherM a = PublisherM
  {unPublisherM :: ReaderT PublisherEnv (ExceptT PublisherError IO) a}
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadIO,
      Generic,
      MonadReader PublisherEnv,
      MonadError PublisherError,
      MonadThrow,
      MonadCatch
    )

-- | Creates a function or set of functions to publish to a topic or set of
-- topics.
--
-- Example:
--
-- @
-- type Api = "topic" :> "echo" :> MsgBody JSON Text :> Reponds JSON Text
--       :<|> "topic" :> "sum" :> Capture "a" Int :> Capture "b" Int
--         :> Responds JSON Int
-- echo :: Text -> PublisherM Text
-- sum' :: Int -> Int -> PublisherM Int
-- (echo :<|> sum') = publisher @Api
-- @
publisher :: forall api. HasPublisher api => Publisher api PublisherM
publisher = publisherWithRoute (Proxy @api) emptyRequest

-- | Executes a 'PublisherM' action with a give 'PublisherEnv'
runPublisherM :: PublisherM a -> PublisherEnv -> IO (Either PublisherError a)
runPublisherM a env = runExceptT (runReaderT (unPublisherM a) env)

instance MonadUnliftIO PublisherM where
  withRunInIO inner = PublisherM $
    ReaderT $ \req ->
      ExceptT $ try $ inner (\x -> either throwM pure =<< runPublisherM x req)
  {-# INLINE withRunInIO #-}

class HasPublisher api where
  type Publisher api (m :: Type -> Type) :: Type
  publisherWithRoute :: Proxy api -> Request -> Publisher api PublisherM

instance (HasPublisher a, HasPublisher b) => HasPublisher (a :<|> b) where
  type Publisher (a :<|> b) m = Publisher a m :<|> Publisher b m
  publisherWithRoute _ req =
    publisherWithRoute (Proxy @a) req
      :<|> publisherWithRoute (Proxy @b) req

instance (KnownSymbol path, HasPublisher api) => HasPublisher (path :> api) where
  type Publisher (path :> api) m = Publisher api m
  publisherWithRoute _ =
    publisherWithRoute (Proxy @api) . appendToPath (T.pack (symbolVal (Proxy @path)))

instance HasPublisher api => HasPublisher (WithRetain :> api) where
  type Publisher (WithRetain :> api) m = Publisher api m
  publisherWithRoute _ =
    publisherWithRoute (Proxy @api) . setRetain True

instance HasPublisher api => HasPublisher (WithNoLocal :> api) where
  type Publisher (WithNoLocal :> api) m = Publisher api m
  publisherWithRoute _ = publisherWithRoute (Proxy @api)

instance (SingI qos, HasPublisher api) => HasPublisher (WithQoS qos :> api) where
  type Publisher (WithQoS qos :> api) m = Publisher api m
  publisherWithRoute _ =
    publisherWithRoute (Proxy @api) . setQoS (toMqttQos (demote @qos))

instance (KnownSymbol sym, MqttApiData a, HasPublisher api) => HasPublisher (Capture sym a :> api) where
  type Publisher (Capture sym a :> api) m = a -> Publisher api m
  publisherWithRoute _ req val =
    publisherWithRoute (Proxy @api) $
      appendToPath (toTopicPiece val) $
        appendCapture (mkTopic' @sym := val) req

instance (KnownSymbol sym, MqttApiData a, HasPublisher api) => HasPublisher (CaptureAll sym a :> api) where
  type Publisher (CaptureAll sym a :> api) m = [a] -> Publisher api m
  publisherWithRoute _ req val =
    publisherWithRoute (Proxy @api) $
      appendCapture (mkTopic' @sym :=.. val) $
        foldl' (flip ($!)) req (map appendToPath (toTopicPieces val))

instance (KnownSymbol sym, MqttApiData a, HasPublisher api) => HasPublisher (UserProperty sym a :> api) where
  type Publisher (UserProperty sym a :> api) m = Maybe a -> Publisher api m
  publisherWithRoute _ req (Just val) =
    publisherWithRoute (Proxy @api) $ appendToProps (PropUserProperty name val') req
    where
      name = fromString (symbolVal (Proxy @sym))
      val' = LBS.fromChunks [T.encodeUtf8 (toTopicPiece val)]
  publisherWithRoute _ req Nothing =
    publisherWithRoute (Proxy @api) req

instance (Serializable encoding a, HasPublisher api) => HasPublisher (MsgBody encoding a :> api) where
  type Publisher (MsgBody encoding a :> api) m = a -> Publisher api m
  publisherWithRoute _ req val =
    publisherWithRoute (Proxy @api) $ setBody (serialize @encoding val) req

instance HasPublisher NoResponds where
  type Publisher NoResponds m = m ()
  publisherWithRoute _ req = do
    mc <- asks mqttClient
    liftIO $ publish mc req

data EmptyPublisher = EmptyPublisher
  deriving (Eq, Show, Bounded, Enum)

instance HasPublisher EmptyAPI where
  type Publisher EmptyAPI m = EmptyPublisher
  publisherWithRoute _ _ = EmptyPublisher

instance
  ( SingI (FoldWithQoS mods),
    ToResponseTopic responseTopic,
    Deserializable encoding a
  ) =>
  HasPublisher (RespondsTo' mods (responseTopic :: k) encoding a)
  where
  type Publisher (RespondsTo' mods responseTopic encoding a) m = m a
  publisherWithRoute _ req = publisherWithRouteResponds @mods @encoding getResponseTopic req
    where
      getResponseTopic = case toResponseTopic (Proxy @responseTopic) (rCaptureMap req) of
        Just x -> pure x
        Nothing -> throwError CaptureNotFound

publisherWithRouteResponds ::
  forall mods encoding a.
  (SingI (FoldWithQoS mods), Deserializable encoding a) =>
  PublisherM Topic ->
  Request ->
  PublisherM a
publisherWithRouteResponds getResponseTopic req = do
  conn <- asks mqttClient
  rTimeout <- asks responseTimeout
  responseTopicFilter <- toFilter <$> getResponseTopic
  corrData' <- join $ asks genCorrelationData
  numSuscriptionsRef <- asks numSuscriptions
  let corrData = LBS.fromChunks [corrData']
  mRespBody <- liftIO $ do
    respVar <- newEmptyTMVarIO
    withCorrelatedCallback conn responseTopicFilter numSuscriptionsRef respVar corrData $ do
      publish conn $
        appendToProps (PropResponseTopic (LBS.fromChunks [T.encodeUtf8 (unFilter responseTopicFilter)])) $
          appendToProps
            (PropCorrelationData corrData)
            req
      timeout rTimeout $ atomically $ takeTMVar respVar
  case deserialize @encoding <$> mRespBody of
    Just (Right x) -> pure x
    Just (Left err) -> throwError (InvalidResponseBody err)
    Nothing -> throwError ResponseTimeout
  where
    withCorrelatedCallback conn responseTopic numSuscriptionsRef respVar corrData =
      bracket_
        ( withClient conn $ \mc -> do
            void $ subscribe mc [(responseTopic, subOptions {_subQoS = toMqttQos (demote @(FoldWithQoS mods))})] []
            atomically $ do
              modifyTVar' numSuscriptionsRef (M.insertWith (+) responseTopic 1)
              registerCorrelated mc corrData $
                LowLevelCallback $
                  \_ PublishRequest {_pubBody} ->
                    atomically $ putTMVar respVar _pubBody
        )
        ( withClient conn $ \mc -> do
            doUnsubscribe <- atomically $ do
              unregisterCorrelated mc corrData
              numSubs <- readTVar numSuscriptionsRef
              if responseTopic `M.lookup` numSubs == Just 1
                then (writeTVar numSuscriptionsRef $! M.delete responseTopic numSubs) >> pure True
                else (writeTVar numSuscriptionsRef $! M.adjust (subtract 1) responseTopic numSubs) >> pure False
            when
              doUnsubscribe
              (void $ unsubscribe mc [responseTopic] [])
        )
