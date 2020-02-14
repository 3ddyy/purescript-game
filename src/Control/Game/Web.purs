module Control.Game.Web
  ( requestAnimationFrame
  , requestAnimationFrames
  , requestAnimationFramesUntil
  , AnimationFrameUpdate

  , requestAnimationFrame'
  , requestAnimationFrames'
  , requestAnimationFramesUntil'
  , AnimationFrameUpdate'

  , GameEvent
  ) where

import Prelude

import Control.Game (class ToUpdate, EffectUpdate, toEffect, toUpdate)
import Control.Game.Util (iterateM, iterateUntilM', newRef, nowSeconds, readRef, writeRef)
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..), fromJust, isJust)
import Data.Newtype (class Newtype, over2)
import Data.Time.Duration (Seconds(..))
import Data.Tuple (Tuple(..), snd)
import Effect (Effect)
import Effect.Aff (Aff, effectCanceler, makeAff)
import Effect.Class (liftEffect)
import Partial.Unsafe (unsafePartial)
import Web.Event.Event (Event, EventType)
import Web.Event.EventTarget (EventTarget, addEventListener, eventListener, removeEventListener)
import Web.HTML (window) as W
import Web.HTML.Window (requestAnimationFrame, cancelAnimationFrame) as W
import Web.HTML.Window (Window)

-- TODO: `WebGame` and `CanvasGame`, which have `ToGame` instances
-- TODO: `CanvasUpdate`, similar to `EffectUpdate` (maybe, maybe not)


requestAnimationFrame' :: forall a. Effect a -> Window -> Aff a
requestAnimationFrame' effect w = makeAff \cb -> ado
  id <- w # W.requestAnimationFrame do
    a <- effect
    cb (Right a)
  in effectCanceler (W.cancelAnimationFrame id w)

requestAnimationFrames' :: (Seconds -> Effect Unit) -> Window -> Aff Void
requestAnimationFrames' effect w = iterateM
  do \t0 -> requestAnimationFrame' (step t0) w
  do liftEffect nowSeconds
  where
    step t0 = do
      t <- nowSeconds
      effect (over2 Seconds (-) t t0) $> t

requestAnimationFramesUntil' :: forall a. (Seconds -> Effect (Maybe a)) -> Window -> Aff a
requestAnimationFramesUntil' effect w = fixReturn $ iterateUntilM'
  do \(Tuple _ m) -> isJust m
  do \(Tuple t0 _) -> requestAnimationFrame' (step t0) w
  do liftEffect nowSeconds <#> (_ `Tuple` Nothing)
  where
    step t0 = do
      t <- nowSeconds
      effect (over2 Seconds (-) t t0) <#> Tuple t
    fixReturn = map (snd >>> unsafePartial fromJust)


newtype AnimationFrameUpdate' s a = AnimationFrameUpdate'
  { window :: Window
  , update :: Seconds -> EffectUpdate s a
  }

derive instance newtypeAnimationFrameUpdate' :: Newtype (AnimationFrameUpdate' s a) _

instance toUpdateAnimationFrameUpdate' :: ToUpdate s a (AnimationFrameUpdate' s a) where
  toUpdate (AnimationFrameUpdate' { window, update }) =
    \ref -> requestAnimationFramesUntil' (update >>> (_ `toEffect` ref)) window

requestAnimationFrame :: forall a. Effect a -> Aff a
requestAnimationFrame effect =
  liftEffect W.window >>= requestAnimationFrame' effect

requestAnimationFrames :: (Seconds -> Effect Unit) -> Aff Void
requestAnimationFrames effect =
  liftEffect W.window >>= requestAnimationFrames' effect

requestAnimationFramesUntil :: forall a. (Seconds -> Effect (Maybe a)) -> Aff a
requestAnimationFramesUntil effect =
  liftEffect W.window >>= requestAnimationFramesUntil' effect

newtype AnimationFrameUpdate s a =
  AnimationFrameUpdate (Seconds -> EffectUpdate s a)

derive instance newtypeAnimationFrameUpdate :: Newtype (AnimationFrameUpdate s a) _

instance toUpdateAnimationFrameUpdate :: ToUpdate s a (AnimationFrameUpdate s a) where
  toUpdate (AnimationFrameUpdate update) = \ref -> do
    window <- liftEffect W.window
    toUpdate (AnimationFrameUpdate' { window, update }) ref


newtype GameEvent s a = GameEvent
  { eventType  :: EventType
  , target     :: EventTarget
  , update     :: Event -> EffectUpdate s a
  , useCapture :: Boolean
  }

instance toUpdateGameEvent :: ToUpdate s a (GameEvent s a) where
  toUpdate (GameEvent { eventType, target, update, useCapture }) =
    \ref -> makeAff \cb -> do
      listenerRef <- newRef Nothing
      let canceler = readRef listenerRef >>= traverse_ \l ->
            removeEventListener eventType l useCapture target
      listener <- eventListener \event ->
        toEffect (update event) ref >>= case _ of
          Just a -> canceler *> cb (Right a)
          Nothing -> pure unit
      writeRef (Just listener) listenerRef
      addEventListener eventType listener useCapture target
      pure $ effectCanceler canceler