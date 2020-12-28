{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Network.MQTT.Typed.Subscriber.Router
-- Copyright   : (c) Plow Technologies, 2020
-- Maintainer  : alberto.valverde@plowtech.net
--
-- This module implements the topic to subscriber router. It is a tweaked clone
-- of servant-server's Servant.Server.Internal.Router
module Network.MQTT.Typed.Subscriber.Router where

import qualified Data.ByteString.Lazy as LBS
import Data.Map
  ( Map,
  )
import qualified Data.Map as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Network.MQTT.Typed.Subscriber.Error (SubscriberError (..))
import Network.MQTT.Typed.Subscriber.PublishResponse (PublishResponse (..))
import Network.MQTT.Types (PublishRequest (..))

type RouteResult = Either SubscriberError

-- Router
--

type Router env = Router' env RoutingApplication

data Router' env a
  = -- | the map contains routers for subpaths (first path component used
    --   for lookup and removed afterwards), the list contains handlers
    --   for the empty path, to be tried in order
    StaticRouter (M.Map Text (Router' env a)) [env -> a]
  | -- | first path component is passed to the child router in its
    --   environment and removed afterwards
    CaptureRouter (Router' (Text, env) a)
  | -- | all path components are passed to the child router in its
    --   environment and are removed afterwards
    CaptureAllRouter (Router' ([Text], env) a)
  | -- | left-biased choice between two routers
    Choice (Router' env a) (Router' env a)
  deriving (Functor)

-- | Smart constructor for a single static path component.
pathRouter :: Text -> Router' env a -> Router' env a
pathRouter t r = StaticRouter (M.singleton t r) []

-- | Smart constructor for a leaf, i.e., a router that expects
-- the empty path.
leafRouter :: (env -> a) -> Router' env a
leafRouter l = StaticRouter M.empty [l]

-- | Smart constructor for the choice between routers.
-- We currently optimize the following cases:
--
--   * Two static routers can be joined by joining their maps
--     and concatenating their leaf-lists.
--   * Two dynamic routers can be joined by joining their codomains.
--   * Choice nodes can be reordered.
choice :: Router' env a -> Router' env a -> Router' env a
choice (StaticRouter table1 ls1) (StaticRouter table2 ls2) =
  StaticRouter (M.unionWith choice table1 table2) (ls1 ++ ls2)
choice (CaptureRouter router1) (CaptureRouter router2) =
  CaptureRouter (choice router1 router2)
choice router1 (Choice router2 router3) = Choice (choice router1 router2) router3
choice router1 router2 = Choice router1 router2

-- | Datatype used for representing and debugging the
-- structure of a router. Abstracts from the handlers
-- at the leaves.
--
-- Two 'Router's can be structurally compared by computing
-- their 'RouterStructure' using 'routerStructure' and
-- then testing for equality, see 'sameStructure'.
data RouterStructure
  = StaticRouterStructure (Map Text RouterStructure) Int
  | CaptureRouterStructure RouterStructure
  | ChoiceStructure RouterStructure RouterStructure
  deriving (Eq, Show)

-- | Compute the structure of a router.
--
-- Assumes that the request or text being passed
-- in 'WithRequest' or 'CaptureRouter' does not
-- affect the structure of the underlying tree.
routerStructure :: Router' env a -> RouterStructure
routerStructure (StaticRouter m ls) =
  StaticRouterStructure (fmap routerStructure m) (length ls)
routerStructure (CaptureRouter router) =
  CaptureRouterStructure $
    routerStructure router
routerStructure (CaptureAllRouter router) =
  CaptureRouterStructure $
    routerStructure router
routerStructure (Choice r1 r2) =
  ChoiceStructure
    (routerStructure r1)
    (routerStructure r2)

-- | Compare the structure of two routers.
sameStructure :: Router' env a -> Router' env b -> Bool
sameStructure r1 r2 =
  routerStructure r1 == routerStructure r2

-- | Provide a textual representation of the
-- structure of a router.
routerLayout :: Router' env a -> Text
routerLayout router =
  T.unlines ("/" : mkRouterLayout False (routerStructure router))
  where
    mkRouterLayout :: Bool -> RouterStructure -> [Text]
    mkRouterLayout c (StaticRouterStructure m n) = mkSubTrees c (M.toList m) n
    mkRouterLayout c (CaptureRouterStructure r) = mkSubTree c "<capture>" (mkRouterLayout False r)
    mkRouterLayout c (ChoiceStructure r1 r2) =
      mkRouterLayout True r1 ++ ["┆"] ++ mkRouterLayout c r2

    mkSubTrees :: Bool -> [(Text, RouterStructure)] -> Int -> [Text]
    mkSubTrees _ [] 0 = []
    mkSubTrees c [] n =
      concat (replicate (n - 1) (mkLeaf True) ++ [mkLeaf c])
    mkSubTrees c [(t, r)] 0 =
      mkSubTree c t (mkRouterLayout False r)
    mkSubTrees c ((t, r) : trs) n =
      mkSubTree True t (mkRouterLayout False r) ++ mkSubTrees c trs n

    mkLeaf :: Bool -> [Text]
    mkLeaf True = ["├─•", "┆"]
    mkLeaf False = ["└─•"]

    mkSubTree :: Bool -> Text -> [Text] -> [Text]
    mkSubTree True path children = ("├─ " <> path <> "/") : map ("│  " <>) children
    mkSubTree False path children = ("└─ " <> path <> "/") : map ("   " <>) children

-- | Apply a transformation to the response of a `Router`.
tweakResponse :: (RouteResult (Maybe PublishResponse) -> RouteResult (Maybe PublishResponse)) -> Router env -> Router env
tweakResponse f = fmap (\app req -> fmap f (app req))

type PathInfo = [Text]

type RoutingApplication = PublishRequest -> IO (RouteResult (Maybe PublishResponse))

-- | Interpret a router as an application.
runRouter :: Router () -> RoutingApplication
runRouter r req = runRouterEnv r () (pathInfo req) req

runRouterEnv :: Router env -> env -> PathInfo -> RoutingApplication
runRouterEnv router env path request =
  case router of
    StaticRouter table ls ->
      case path of
        [] -> runChoice ls env request
        -- This case is to handle trailing slashes.
        [""] -> runChoice ls env request
        first : rest
          | Just router' <- M.lookup first table ->
              runRouterEnv router' env rest request
        _ -> pure $ Left NotFound
    CaptureRouter router' ->
      case path of
        [] -> pure $ Left NotFound
        -- This case is to handle trailing slashes.
        [""] -> pure $ Left NotFound
        first : rest ->
          runRouterEnv router' (first, env) rest request
    CaptureAllRouter router' ->
      runRouterEnv router' (path, env) [] request
    Choice r1 r2 ->
      runChoice
        [ \env' -> runRouterEnv r1 env' path,
          \env' -> runRouterEnv r2 env' path
        ]
        env
        request

-- | Try a list of routing applications in order.
-- We stop as soon as one fails fatally or succeeds.
-- If all fail normally, we pick the "best" error.
runChoice :: [env -> RoutingApplication] -> env -> RoutingApplication
runChoice ls =
  case ls of
    [] -> \_ _ -> pure $ Left NotFound
    [r] -> r
    (r : rs) ->
      \env request -> do
        response1 <- r env request
        case response1 of
          Left NotFound -> do
            response2 <- runChoice rs env request
            pure $ highestPri response1 response2
          _ -> pure response1
  where
    highestPri (Left e1) (Left e2) =
      if e1 < e2
        then Left e2
        else Left e1
    highestPri (Left _) y = y
    highestPri x _ = x

pathInfo :: PublishRequest -> PathInfo
pathInfo = T.split (== '/') . T.decodeUtf8 . LBS.toStrict . _pubTopic
