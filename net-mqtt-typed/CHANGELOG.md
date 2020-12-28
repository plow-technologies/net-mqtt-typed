# Revision history for net-mqtt-typed

## 0.6.0.0
* Extracted Publisher and Subscriber code (code that depends on net-mqtt)
  into net-mqtt-typed-pubsub package so implementation changes don't cascade
  to packages that only need to define APIs and MqttApiData instances

## 0.5.1.1
* Added MqttApiData instance for UUID

## 0.5.1.0
* Added versions of subscribeWith which receive subscription commands
  thru the updates channel instead of resulting filter sets

## 0.5.0.0
* Adapted to changes in net-mqtt-extra

## 0.4.1.1
* Fix: Missing export for `*WithMany` variants

## 0.4.1.0
* Implemented `*WithMany` variants to set many Captures in one call

## 0.4.0.0
* Use net-mqtt-extra for more composability

## 0.3.1.1
* Upgraded to work with net-mqtt 0.8

## 0.3.1.0
* Upgraded to work with GHC 9

## 0.3.0.0 -- 2021-5-18
* Remove 'Responds' in favor of more explicit RespondsTo
* Added 'Capture' so we can include captured vars in response topic

## 0.2.4.0 -- 2021-5-3
* Type-safer topicsForApiWith

## 0.2.3.0 -- 2021-04-30
* Log unhandled sync exceptions in subscriber

## 0.2.2.0 -- 2021-04-22
* New MqttApiData typeclass to allow overriding how parameters are de/serialized into
  topics and user properties if we need them to differ on how they are for url
  parameters

## 0.2.1.0 -- 2021-03-24
* Made `ReconnectingClient`'s fail-fast behavior configurable
* Fixed bug in ` normalDisconnectReconnectingClient` which caused it to block if
  it wasn't already connected

## 0.2.0.0 -- 2021-01-06
* Added hoistSubscriber to allow subscribers running in a monad other than IO
* Added WithLocal to denote that a subscriber shall not receive notifications
  posted by the same connection
* Added topicForApiWith to allow substituting Capture variables with fixed
  values when subscribing

## 0.1.0.0 -- YYYY-mm-dd
* First version. Released on an unsuspecting world.
