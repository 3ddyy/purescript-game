module Test.InputEvent.Main where

import Prelude

import Control.Game (canvasGame, noUpdate, noEnd, noSignal)
import Control.Game.EventHelpers (clickEvent, inputEventValueOne)
import Data.List (List(..), (:))
import Data.Symbol (SProxy(..))
import Data.Vector.Polymorphic ((><))
import Effect (Effect)
import Effect.Aff (launchAff_)
import Graphics.CanvasAction (clearRectFull, fillText, setFont)
import Record (modify)
import Web.DOM.ParentNode (QuerySelector(..))

main :: Effect Unit
main = do
  event1 <- clickEvent
    (QuerySelector "button")
    \_ -> modify (SProxy :: _ "n") (add 1) >>> pure
  event2 <- inputEventValueOne
    event1
    (QuerySelector "input")
    \str -> _ { str = str } >>> pure
  launchAff_ $ canvasGame
    { canvas: QuerySelector "canvas"
    , init: { n: 0, str: "" }
        <$ setFont "15px monospace"
    , update: noUpdate
    , display: \{ n, str } -> do
        clearRectFull
        fillText
          ("Text updated " <> show n <> " time" <> if n == 1 then "" else "s")
          (10.0 >< 20.0)
        fillText str (10.0 >< 40.0)
    , end: noEnd
    , events: event1 : event2 : Nil
    , signal: noSignal
    }
