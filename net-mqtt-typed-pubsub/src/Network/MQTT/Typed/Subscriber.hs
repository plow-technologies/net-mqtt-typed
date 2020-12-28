{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Network.MQTT.Typed.Subscriber
-- Copyright   : (c) Plow Technologies, 2020-2021
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module defines the typeclass 'HasSubscriber' which is used to interpret
-- the API type and a subscriber implementing its specification
-- into message callback.
--
-- The typeclass is exported along with some helpers so new API types can be
-- defined by users of the library.
module Network.MQTT.Typed.Subscriber
  ( -- * What you will normally need
    subscribeApi,
    subscribeApiWith,
    subscribeApiWith2,
    withAsyncSubscribeApi,
    withAsyncSubscribeApiWith,
    withAsyncSubscribeApiWith2,
    CaptureMapCmd (..),

    -- * Lower-level use
    toRoutingApplication,

    -- * Stuff to implement custom API types
    HasSubscriber (..),
    EmptySubscriber (EmptySubscriber),
    DelayedIO,
    Router' (..),
    runDelayedIO,
    addCapture,
    addBodyCheck,
    addUserPropertyCheck,

    -- * Re-exports
    module ReExport,
  )
where

#if __GLASGOW_HASKELL__ < 900
import Data.Singletons.Prelude ()
#else
import Prelude.Singletons ()
#endif

import Control.Concurrent.Async (link, withAsync)
import Control.Concurrent.STM
  ( atomically,
    newEmptyTMVarIO,
    putTMVar,
    takeTMVar,
  )
import qualified Control.Concurrent.STM.TChan as TChan
import Control.Exception.Safe
  ( Exception,
    catchAny,
    catchAnyDeep,
    throwIO,
    try,
  )
import Control.Monad (forever, when)
import Control.Monad.Catch
  ( MonadThrow (..),
  )
import Control.Monad.Except
  ( ExceptT (ExceptT),
    MonadError,
    liftEither,
    runExceptT,
    throwError,
  )
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.IO.Unlift
  ( MonadUnliftIO,
    withRunInIO,
  )
import Control.Monad.Reader
  ( MonadReader (..),
    ReaderT (..),
    asks,
    runReaderT,
  )
import Control.Monad.Trans (lift)
import qualified Data.ByteString.Lazy as LBS
import Data.Kind (Type)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (Proxy))
import Data.Singletons (SingI, demote)
import Data.String (fromString)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Encoding.Error as T
import GHC.TypeLits (KnownSymbol, symbolVal)
import Network.MQTT.Client
import qualified Network.MQTT.Connection as Connection
import Network.MQTT.Topic (mkTopic)
import Network.MQTT.Typed.API as ReExport
import Network.MQTT.Typed.Subscriber.Error as ReExport
import Network.MQTT.Typed.Subscriber.PublishResponse as ReExport
import Network.MQTT.Typed.Subscriber.Router
import Network.MQTT.Typed.Subscriber.Topic (toMqttQos)
import Network.MQTT.Typed.Subscriber.Topic as ReExport
  ( CaptureMap,
    CaptureVar (..),
    ToResponseTopic (..),
    ToTopics (..),
    mkFilter',
    mkTopic',
    topicsForApi,
    topicsForApiWith,
  )
import Network.MQTT.Types (PublishRequest (..))
import System.IO (hPutStrLn, stderr)

-- | Subscribe a 'Subscriber' to a MQTT api
-- This function blocks until the 'Connection' is closed.
-- For a non-blocking version use 'withAsyncSubscribeApi' for a version that spawns
-- an 'Async' thread.
subscribeApi ::
  forall api.
  (ToTopics api, HasSubscriber api) =>
  Connection.Connection ->
  Subscriber api IO ->
  IO ()
subscribeApi =
  subscribeApiWith @api (pure ()) [mempty] Nothing mempty

-- | Same as 'subscribeApi' but can override defaults
subscribeApiWith ::
  forall api.
  (ToTopics api, HasSubscriber api) =>
  IO () ->
  [CaptureMap] ->
  Maybe (TChan.TChan [CaptureMap]) ->
  [Property] ->
  Connection.Connection ->
  Subscriber api IO ->
  IO ()
subscribeApiWith onSubscribed captures mCapturesChan props conn server =
  case mCapturesChan of
    Just capturesChan -> do
      topicsChan <- TChan.newTChanIO
      withAsync (translateChan capturesChan topicsChan) $ \thr -> do
        link thr
        Connection.subscribeWith onSubscribed conn (capturesToTopicsMap captures) (Just topicsChan) (mkHandler @api conn server)
    Nothing ->
      Connection.subscribeWith onSubscribed conn (capturesToTopicsMap captures) Nothing (mkHandler @api conn server)
  where
    translateChan capturesChan topicsChan =
      forever $
        atomically $
          TChan.readTChan capturesChan
            >>= TChan.writeTChan topicsChan . capturesToTopicsMap

    capturesToTopicsMap =
      fmap (,props) . Map.fromList . concatMap (topicsForApiWith @api)

data CaptureMapCmd = AddCaptureMap CaptureMap | RemoveCaptureMap CaptureMap

-- | Same as 'subscribeApi' but can override defaults
subscribeApiWith2 ::
  forall api.
  (ToTopics api, HasSubscriber api) =>
  IO () ->
  [CaptureMap] ->
  Maybe (TChan.TChan CaptureMapCmd) ->
  [Property] ->
  Connection.Connection ->
  Subscriber api IO ->
  IO ()
subscribeApiWith2 onSubscribed captures mCapturesChan props conn server =
  case mCapturesChan of
    Just capturesChan -> do
      topicsChan <- TChan.newTChanIO
      withAsync (translateChan capturesChan topicsChan) $ \thr -> do
        link thr
        Connection.subscribeWith2 onSubscribed conn (capturesToTopicsMap captures) (Just topicsChan) (mkHandler @api conn server)
    Nothing ->
      Connection.subscribeWith onSubscribed conn (capturesToTopicsMap captures) Nothing (mkHandler @api conn server)
  where
    translateChan :: TChan.TChan CaptureMapCmd -> TChan.TChan Connection.SubscribeCmd -> IO ()
    translateChan capturesChan topicsChan =
      forever $
        atomically $
          TChan.readTChan capturesChan
            >>= mapM_ (TChan.writeTChan topicsChan) . translateCommand

    translateCommand :: CaptureMapCmd -> [Connection.SubscribeCmd]
    translateCommand (AddCaptureMap cpMap) =
      map (\(t, (o, ps)) -> Connection.Subscribe t o ps) $ Map.toList (capturesToTopicsMap [cpMap])
    translateCommand (RemoveCaptureMap cpMap) =
      map (\(t, (_, ps)) -> Connection.Unsubscribe t ps) $ Map.toList (capturesToTopicsMap [cpMap])

    capturesToTopicsMap =
      fmap (,props) . Map.fromList . concatMap (topicsForApiWith @api)

mkHandler ::
  forall api.
  HasSubscriber api =>
  Connection.Connection ->
  Subscriber api IO ->
  PublishRequest ->
  IO ()
mkHandler conn server req =
  toRoutingApplication @api server req
    `catchAnyDeep` (pure . Left . UnhandledException . show)
    >>= \case
      Right (Just PublishResponse {prTopic, prBody, prRetain, prQoS, prProps}) ->
        Connection.publish conn prTopic prBody prRetain prQoS prProps
          `catchAny` displayAndIgnore "Exception when publishing response" req
      Right Nothing -> pure ()
      Left x -> displayAndIgnore "Exception in subscriber" req x

-- | 'subscribeApi' to a topic in an async thread so that the calling thread
-- is not blocked
--
-- If 'failFast' is True, the continuation will not be called until the broker has acknowledged the suscription, blocking until this happens
withAsyncSubscribeApi ::
  forall api a.
  (ToTopics api, HasSubscriber api) =>
  Connection.Connection ->
  Subscriber api IO ->
  IO a ->
  IO a
withAsyncSubscribeApi =
  withAsyncSubscribeApiWith @api [mempty] Nothing mempty

-- | Same as 'withAsyncSubscribeApi' but can override defaults
withAsyncSubscribeApiWith ::
  forall api a.
  (ToTopics api, HasSubscriber api) =>
  [CaptureMap] ->
  Maybe (TChan.TChan [CaptureMap]) ->
  [Property] ->
  Connection.Connection ->
  Subscriber api IO ->
  IO a ->
  IO a
withAsyncSubscribeApiWith captures mCapturesChan props conn server f = do
  v <- newEmptyTMVarIO
  withAsync (subscribeApiWith @api (atomically (putTMVar v ())) captures mCapturesChan props conn server) $ \t -> do
    link t
    when (Connection.failFast (Connection.connectionSettings conn)) $
      atomically (takeTMVar v)
    f

-- | Same as 'withAsyncSubscribeApi' but can override defaults
withAsyncSubscribeApiWith2 ::
  forall api a.
  (ToTopics api, HasSubscriber api) =>
  [CaptureMap] ->
  Maybe (TChan.TChan CaptureMapCmd) ->
  [Property] ->
  Connection.Connection ->
  Subscriber api IO ->
  IO a ->
  IO a
withAsyncSubscribeApiWith2 captures mCapturesChan props conn server f = do
  v <- newEmptyTMVarIO
  withAsync (subscribeApiWith2 @api (atomically (putTMVar v ())) captures mCapturesChan props conn server) $ \t -> do
    link t
    when (Connection.failFast (Connection.connectionSettings conn)) $
      atomically (takeTMVar v)
    f

-- | Produce a 'RoutingApplication' from an API type and the subscriber
-- implementing it
toRoutingApplication :: forall api. HasSubscriber api => Subscriber api IO -> RoutingApplication
toRoutingApplication server = runRouter (route (Proxy @api) (emptyDelayed (Right server)))

-- | The 'DelayedIO' monad is where arguments to call a subscriber are fetched
-- from the PublishRequest and its result evaluated
newtype DelayedIO a = DelayedIO {runDelayedIO' :: ReaderT PublishRequest (ExceptT SubscriberError IO) a}
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadIO,
      MonadReader PublishRequest,
      MonadError SubscriberError,
      MonadThrow
    )

liftRouteResult :: RouteResult a -> DelayedIO a
liftRouteResult = DelayedIO . lift . ExceptT . return

-- | Run a 'DelayedIO' computation to produce a 'RouteResult'
runDelayedIO :: DelayedIO a -> PublishRequest -> IO (RouteResult a)
runDelayedIO m = runExceptT . runReaderT (runDelayedIO' m)

instance MonadUnliftIO DelayedIO where
  withRunInIO inner = DelayedIO $
    ReaderT $ \req ->
      ExceptT $ try $ inner (\x -> either throwIO pure =<< runDelayedIO x req)
  {-# INLINE withRunInIO #-}

-- | This type is used to collect arguments to call a subscriber registered to
-- listen to a topic
data Delayed env a where
  Delayed ::
    { capturesD :: env -> DelayedIO captures,
      placeholdersD :: env -> DelayedIO CaptureMap,
      paramsD :: DelayedIO params,
      userPropsD :: DelayedIO userProps,
      bodyD :: DelayedIO body,
      subscriberD ::
        captures ->
        params ->
        userProps ->
        body ->
        PublishRequest ->
        RouteResult a
    } ->
    Delayed env a

instance Functor (Delayed env) where
  fmap f Delayed {..} =
    Delayed
      { subscriberD = \c p h b req -> f <$> subscriberD c p h b req,
        ..
      }

-- | A 'Delayed' without any stored checks.
emptyDelayed :: RouteResult a -> Delayed env a
emptyDelayed result =
  Delayed (const r) (const (pure [])) r r r (\_ _ _ _ _ -> result)
  where
    r = return ()

-- | Add a capture to the end of the capture block.
addCapture ::
  Delayed env (a -> b) ->
  (captured -> DelayedIO (a, CaptureMap)) ->
  Delayed (captured, env) b
addCapture Delayed {..} new =
  Delayed
    { capturesD = \(txt, env) -> (,) <$> capturesD env <*> (fst <$> new txt),
      subscriberD = \(x, v) p h b req -> ($ v) <$> subscriberD x p h b req,
      placeholdersD = \(txt, env) -> (<>) <$> placeholdersD env <*> (snd <$> new txt),
      ..
    }

-- | Adds a 'DelayedIO' action to collect the argument of type 'a'
addBodyCheck ::
  Delayed env (a -> b) ->
  -- | body check
  DelayedIO a ->
  Delayed env b
addBodyCheck Delayed {..} newBodyD =
  Delayed
    { bodyD = (,) <$> bodyD <*> newBodyD,
      subscriberD = \c p h (z, v) req -> ($ v) <$> subscriberD c p h z req,
      ..
    }

-- | Adds a 'DelayedIO' action to collect the argument of type 'a'
addUserPropertyCheck ::
  Delayed env (a -> b) ->
  DelayedIO a ->
  Delayed env b
addUserPropertyCheck Delayed {..} new =
  Delayed
    { userPropsD = (,) <$> userPropsD <*> new,
      subscriberD = \c p (h, hNew) b req -> ($ hNew) <$> subscriberD c p h b req,
      ..
    }

-- | Run a delayed server. Performs all scheduled operations
-- in order, and passes the results from the capture and body
-- blocks on to the actual handler.
runDelayed ::
  Delayed env a ->
  env ->
  PublishRequest ->
  IO (RouteResult a)
runDelayed Delayed {..} env = runDelayedIO $ do
  r <- ask
  c <- capturesD env
  p <- paramsD
  h <- userPropsD
  b <- bodyD
  liftRouteResult (subscriberD c p h b r)

-- | This typeclass defines how API types are interpreted to produce a
-- subscriber to a set of MQTT topics
class HasSubscriber api where
  type Subscriber api (m :: Type -> Type) :: Type

  route :: Proxy api -> Delayed env (Subscriber api IO) -> Router env

  hoistSubscriber :: Proxy api -> (forall x. m x -> n x) -> Subscriber api m -> Subscriber api n

instance
  ( SingI (FoldWithQoS mods),
    SingI (FoldWithRetain mods),
    ToResponseTopic responseTopic,
    Serializable encoding a
  ) =>
  HasSubscriber (RespondsTo' mods (responseTopic :: k) encoding a)
  where
  type Subscriber (RespondsTo' mods responseTopic encoding a) m = m a
  route _ act = leafRouter router
    where
      router env req@PublishRequest {_pubProps} = runExceptT $ do
        handler <- ExceptT (runDelayed act env req)
        cMap <- runReaderT (runDelayedIO' (placeholdersD act env)) req
        prTopic <- case [x | PropResponseTopic x <- _pubProps] of
          responseTopic : _ ->
            let responseTopic' = T.decodeUtf8With T.lenientDecode (LBS.toStrict responseTopic)
             in case mkTopic responseTopic' of
                  Just t -> pure t
                  Nothing -> throwError (InvalidResponseTopic responseTopic')
          _ ->
            liftEither $
              maybe (Left CaptureNotFound) pure $
                toResponseTopic (Proxy @responseTopic) cMap
        a <- lift handler
        pure $
          Just $
            PublishResponse
              { prTopic,
                prBody = serialize @encoding a,
                prRetain = demote @(FoldWithRetain mods),
                prQoS = toMqttQos (demote @(FoldWithQoS mods)),
                prProps = [PropCorrelationData x | PropCorrelationData x <- _pubProps]
              }
  hoistSubscriber _ x = x

instance HasSubscriber NoResponds where
  type Subscriber NoResponds m = m ()
  route _ act = leafRouter $ \env req -> do
    eRet <- runDelayed act env req
    case eRet of
      Left x -> pure (Left x)
      Right handler -> Right . const Nothing <$> handler
  hoistSubscriber _ x = x

data EmptySubscriber = EmptySubscriber
  deriving (Eq, Show, Bounded, Enum)

instance HasSubscriber EmptyAPI where
  type Subscriber EmptyAPI m = EmptySubscriber
  route _ _ = StaticRouter mempty mempty
  hoistSubscriber _ _ = id

instance (KnownSymbol sym, MqttApiData a, HasSubscriber api) => HasSubscriber (Capture sym a :> api) where
  type Subscriber (Capture sym a :> api) m = a -> Subscriber api m
  route _ d = CaptureRouter $
    route (Proxy @api) $
      addCapture d $ \txt ->
        case parseTopicPiece txt of
          Right v -> pure (v, [mkTopic' @sym := v])
          Left err -> throwError (InvalidCapture (symbolVal (Proxy @sym)) err)
  hoistSubscriber _ f s = hoistSubscriber (Proxy @api) f . s

instance (KnownSymbol sym, MqttApiData a, HasSubscriber api) => HasSubscriber (CaptureAll sym a :> api) where
  type Subscriber (CaptureAll sym a :> api) m = [a] -> Subscriber api m
  route _ d = CaptureAllRouter $
    route (Proxy @api) $
      addCapture d $ \txt ->
        case parseTopicPieces txt of
          Right v -> pure (v, [mkTopic' @sym :=.. v])
          Left err -> throwError (InvalidCapture (symbolVal (Proxy @sym)) err)
  hoistSubscriber _ f s = hoistSubscriber (Proxy @api) f . s

instance (KnownSymbol sym, MqttApiData a, HasSubscriber api) => HasSubscriber (UserProperty sym a :> api) where
  type Subscriber (UserProperty sym a :> api) m = Maybe a -> Subscriber api m
  route _ d =
    route (Proxy @api) $
      addUserPropertyCheck d $ do
        props <- asks _pubProps
        case [ v | PropUserProperty name v <- props, name == fromString (symbolVal (Proxy @sym))
             ] of
          txt : _ -> case parseTopicPiece (T.decodeUtf8 (LBS.toStrict txt)) of
            Right v -> pure (Just v)
            Left err -> throwError (InvalidUserProperty (symbolVal (Proxy @sym)) err)
          [] -> pure Nothing
  hoistSubscriber _ f s = hoistSubscriber (Proxy @api) f . s

instance (Deserializable encoding a, HasSubscriber api) => HasSubscriber (MsgBody encoding a :> api) where
  type Subscriber (MsgBody encoding a :> api) m = a -> Subscriber api m
  route _ d = route (Proxy @api) $
    addBodyCheck d $ do
      PublishRequest {_pubBody} <- ask
      case deserialize @encoding _pubBody of
        Right x -> pure x
        Left e -> throwError (InvalidMessage e)
  hoistSubscriber _ f s = hoistSubscriber (Proxy @api) f . s

instance (KnownSymbol path, HasSubscriber api) => HasSubscriber (path :> api) where
  type Subscriber (path :> api) m = Subscriber api m
  route Proxy subserver =
    pathRouter
      (T.pack (symbolVal (Proxy @path)))
      (route (Proxy :: Proxy api) subserver)
  hoistSubscriber _ = hoistSubscriber (Proxy @api)

instance (HasSubscriber a, HasSubscriber b) => HasSubscriber (a :<|> b) where
  type Subscriber (a :<|> b) m = Subscriber a m :<|> Subscriber b m
  route _ server =
    choice
      (route (Proxy @a) ((\(a :<|> _) -> a) <$> server))
      (route (Proxy @b) ((\(_ :<|> b) -> b) <$> server))
  hoistSubscriber _ f (a :<|> b) = hoistSubscriber (Proxy @a) f a :<|> hoistSubscriber (Proxy @b) f b

instance HasSubscriber api => HasSubscriber (WithRetain :> api) where
  type Subscriber (WithRetain :> api) m = Subscriber api m
  route _ = route (Proxy @api)
  hoistSubscriber _ = hoistSubscriber (Proxy @api)

instance HasSubscriber api => HasSubscriber (WithNoLocal :> api) where
  type Subscriber (WithNoLocal :> api) m = Subscriber api m
  route _ = route (Proxy @api)
  hoistSubscriber _ = hoistSubscriber (Proxy @api)

instance HasSubscriber api => HasSubscriber (WithQoS x :> api) where
  type Subscriber (WithQoS x :> api) m = Subscriber api m
  route _ = route (Proxy @api)
  hoistSubscriber _ = hoistSubscriber (Proxy @api)

displayAndIgnore :: Exception e => String -> PublishRequest -> e -> IO ()
displayAndIgnore banner req err = do
  hPutStrLn stderr $
    unlines
      [ banner,
        "PublishRequest: ",
        show req,
        "Exception:",
        show err
      ]
