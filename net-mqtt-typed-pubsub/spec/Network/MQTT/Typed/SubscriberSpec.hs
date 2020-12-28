{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Network.MQTT.Typed.SubscriberSpec (main, spec) where

import qualified Data.ByteString.Lazy as LBS
import Network.MQTT.Client (SubOptions (..))
import qualified Network.MQTT.Client (QoS (..))
import Network.MQTT.Typed.API
import Network.MQTT.Typed.ApiUnderTest (Api1)
import Network.MQTT.Typed.Subscriber
import Network.MQTT.Typed.Subscriber.Topic (toMqttQos)
import Network.MQTT.Types (PublishRequest (..))
import Test.Hspec

main :: IO ()
main = hspec spec

apiApp :: PublishRequest -> IO (Either SubscriberError (Maybe PublishResponse))
apiApp = toRoutingApplication @Api1 server
  where
    server = add' :<|> mul' :<|> sub' :<|> pure () :<|> mul2 :<|> sum' :<|> pure :<|> EmptySubscriber
    add' a b = pure (a + b)
    mul' a b = pure (a * b)
    sub' a b = pure (a - b)
    mul2 = uncurry mul'
    sum' = pure . sum

spec :: Spec
spec =
  describe "apiApp" $
    do
      it "generates topics" $ do
        map fst (topicsForApi @Api1)
          `shouldBe` [ "demo/add/+/+",
                       "demo/mul/+/+",
                       "demo/sub/+/+",
                       "demo/noop",
                       "demo/mul2",
                       "demo/sum/#",
                       "demo/respondsTo/+"
                     ]
        map fst (topicsForApiWith @Api1 ["a" := (4 :: Int)])
          `shouldBe` [ "demo/add/4/+",
                       "demo/mul/4/+",
                       "demo/sub/4/+",
                       "demo/noop",
                       "demo/mul2",
                       "demo/sum/#",
                       "demo/respondsTo/4"
                     ]
        map (_subQoS . snd) (topicsForApi @Api1)
          `shouldBe` map
            toMqttQos
            [ QoS1,
              QoS1,
              QoS1,
              QoS2,
              QoS1,
              QoS1,
              QoS1
            ]
        map (_noLocal . snd) (topicsForApi @Api1)
          `shouldBe` [ False,
                       True,
                       False,
                       False,
                       False,
                       False,
                       False
                     ]
      it "dispatches to add" $ do
        eRes <- apiApp $ publish "demo/add/1/3" ""
        case eRes of
          Right (Just PublishResponse {prBody = "4", prQoS = Network.MQTT.Client.QoS2}) -> pure ()
          other -> expectationFailure (show other)
      it "dispatches to mul" $ do
        eRes <- apiApp $ publish "demo/mul/1/3" ""
        case eRes of
          Right (Just PublishResponse {prBody}) -> prBody `shouldBe` "3"
          other -> expectationFailure (show other)
      it "dispatches to sub" $ do
        eRes <- apiApp $ publish "demo/sub/1/3" ""
        case eRes of
          Right (Just PublishResponse {prBody}) -> prBody `shouldBe` "-2"
          other -> expectationFailure (show other)
      it "dispatches to noop" $ do
        eRes <- apiApp $ publish "demo/noop" ""
        case eRes of
          Right Nothing -> pure ()
          other -> expectationFailure (show other)
      it "dispatches to mul2" $ do
        eRes <- apiApp $ publish "demo/mul2" "[6,7]"
        case eRes of
          Right (Just PublishResponse {prBody}) -> prBody `shouldBe` "42"
          other -> expectationFailure (show other)
      it "dispatches to sum" $ do
        eRes <- apiApp $ publish "demo/sum/1/2/3/4/5/6" ""
        case eRes of
          Right (Just PublishResponse {prBody}) -> prBody `shouldBe` "21"
          other -> expectationFailure (show other)
      it "respondsTo sets response topic" $ do
        eRes <- apiApp $ publish "demo/respondsTo/6" ""
        case eRes of
          Right (Just PublishResponse {prTopic}) -> prTopic `shouldBe` "foo/6/bar"
          other -> expectationFailure (show other)

publish :: LBS.ByteString -> LBS.ByteString -> PublishRequest
publish _pubTopic _pubBody =
  PublishRequest
    { _pubDup = False,
      _pubQoS = toMqttQos QoS0,
      _pubRetain = False,
      _pubTopic,
      _pubPktID = 0,
      _pubBody,
      _pubProps = []
    }
