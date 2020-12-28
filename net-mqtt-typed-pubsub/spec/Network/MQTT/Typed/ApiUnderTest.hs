{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Network.MQTT.Typed.ApiUnderTest (Api1) where

import Network.MQTT.Typed.API
import Network.MQTT.Typed.Publisher (publisher)

type Api1 =
  "demo"
    :> WithQoS 'QoS1
    :> ( "add" :> Capture "a" Int :> Capture "b" Int :> RespondsTo' '[WithQoS 'QoS2] "responses" JSON Int
           :<|> WithNoLocal :> "mul" :> Capture "a" Int :> Capture "b" Int :> RespondsTo "responses" JSON Int
           :<|> "sub" :> Capture "a" Int :> Capture "b" Int :> RespondsTo "responses" JSON Int
           :<|> WithQoS 'QoS2 :> WithRetain :> "noop" :> NoResponds
           :<|> "mul2" :> MsgBody JSON (Int, Int) :> RespondsTo "responses" JSON Int
           :<|> "sum" :> CaptureAll "nums" Int :> RespondsTo "responses" JSON Int
           :<|> "respondsTo" :> Capture "a" Int :> RespondsTo ("foo" :> Captured "a" :> "bar") JSON Int
           -- EmptyAPI behaves like the unit of :<|>.
           -- It is useful for defining the base case when defining APIs programatically via type-level lists
           :<|> EmptyAPI
       )

-- Just check that it typechecks
_ = publisher @Api1
