module Game.Aff
  ( _dt
  , _end
  , _stateRef
  , _env
  , OnStartExecIn
  , LoopExecIn
  , ExecOut
  , Interpreted
  , Req

  , AffGame(..)
  , ParAffGame

  , AFFGAME
  , _affGame
  , liftAffGame
  , liftAffGameAt
  , runAffGame
  , runAffGameAt
  , runBaseAffGame
  , runBaseAffGameAt
  , runBaseAffGame'
  , runBaseAffGameAt'

  , simpleAffGame
  , AffGameUpdate
  , TemplateAffGame
  , interpretAffGame
  , parallelizeAffGame
  , mkAffGame
  , runGame
  , runGameAff
  , launchGame
  , launchGame_

  , onStart
  , loopUpdate
  , loopUpdate'
  , matchInterval

  , FPS(..)

  , module Exports
  ) where

import Prelude hiding (join)

import Data.Symbol (class IsSymbol)
import Control.Apply (lift2)
import Control.Lazy (class Lazy)
import Control.Monad.Error.Class (class MonadError, class MonadThrow, catchError)
import Control.Monad.Fork.Class (class MonadBracket, class MonadFork, class MonadKill, bracket, fork, join, kill, never, suspend, uninterruptible)
import Control.Monad.Rec.Class (class MonadRec, tailRecM)
import Control.Parallel (parOneOfMap, class Parallel, parallel, sequential)
import Control.Plus (class Alt, class Plus, empty, (<|>))
import Data.Either (either, Either(..))
import Data.Newtype (class Newtype, over, over2)
import Data.Time.Duration (Seconds(..), class Duration, Milliseconds(..), convertDuration)
import Effect (Effect)
import Effect.Aff (Aff, Fiber, ParAff, launchAff, throwError, try)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Exception (Error)
import Effect.Ref (Ref)
import Game (GameUpdate(..), Reducer, mkReducer, runReducer) as Exports
import Game (GameUpdate(..), Reducer, mkRunGame, runReducer)
import Game.Util (forever, fromLeft, iterateM, newRef, nowSeconds, runStateWithRef)
import Prim.Row as Row
import Run (AFF, EFFECT, FProxy, Run, SProxy(..), case_, expand, interpret, lift, on, run, runBaseAff', send)
import Run (liftAff) as Run
import Run.Except (EXCEPT, runExceptAt)
import Run.Reader (READER, runReaderAt, askAt)
import Run.State (STATE)


_dt ∷ SProxy "dt"
_dt = SProxy

_end ∷ SProxy "end"
_end = SProxy

_stateRef ∷ SProxy "stateRef"
_stateRef = SProxy

_env ∷ SProxy "env"
_env = SProxy

-- | The execIn effects that are used for the `onStart` update
type OnStartExecIn e s a r =
  ( state   ∷ STATE s
  , env     ∷ READER e
  , end     ∷ EXCEPT a
  , effect  ∷ EFFECT
  , aff     ∷ AFF
  | r )

-- | The execIn effects that are used for most loop updates
type LoopExecIn e s a r =
  ( state   ∷ STATE s
  , env     ∷ READER e
  , end     ∷ EXCEPT a
  , dt      ∷ READER Seconds
  , effect  ∷ EFFECT
  , aff     ∷ AFF
  | r )

-- | The execOut effects for `TemplateAffGame`
type ExecOut e s a =
  ( stateRef ∷ READER (Ref s)
  , env      ∷ READER e
  , end      ∷ EXCEPT a
  , effect   ∷ EFFECT
  , aff      ∷ AFF
  )

-- | The effects in an interpreted `TemplateAffGame`
type Interpreted e s =
  ( stateRef ∷ READER (Ref s)
  , env      ∷ READER e
  , effect   ∷ EFFECT
  , aff      ∷ AFF
  )

-- | The `effect`, `aff`, and `affGame` effects are required to be supported by
-- | every `AffGameUpdate`. Reducers for `AffGame` can interpret the extra
-- | effects in terms of them.
type Req extra = (effect ∷ EFFECT, aff ∷ AFF, affGame ∷ AFFGAME extra)


-- |
newtype AffGame extra a = AffGame (Reducer extra Req → Aff a)

derive instance newtypeAffGame ∷ Newtype (AffGame extra a) _

derive instance functorAffGame ∷ Functor (AffGame extra)

instance applyAffGame ∷ Apply (AffGame extra) where
  apply (AffGame f) (AffGame a) = AffGame \r → (f r <*> a r)

instance applicativeAffGame ∷ Applicative (AffGame extra) where
  pure x = liftAff (pure x)

instance bindAffGame ∷ Bind (AffGame extra) where
  bind (AffGame a) f = AffGame \r → (a r >>= f >>> runGameAff r)

instance monadAffGame ∷ Monad (AffGame extra)

instance monadEffectAffGame ∷ MonadEffect (AffGame extra) where
  liftEffect a = liftAff (liftEffect a)

instance monadAffAffGame ∷ MonadAff (AffGame extra) where
  liftAff a = AffGame \_ → a

instance monadRecAffGame ∷ MonadRec (AffGame extra) where
  tailRecM f a = AffGame \r → tailRecM (\a' → runGameAff r (f a')) a

instance monadThrowAffGame ∷ MonadThrow Error (AffGame extra) where
  throwError e = liftAff (throwError e)

instance monadErrorAffGame ∷ MonadError Error (AffGame extra) where
  catchError (AffGame a) f = AffGame \r → catchError (a r) (f >>> runGameAff r)

instance monadForkAffGame ∷ MonadFork Fiber (AffGame extra) where
  suspend (AffGame a) = AffGame \r → suspend (a r)
  fork    (AffGame a) = AffGame \r → fork    (a r)
  join    fiber       = liftAff (join fiber)

instance monadKillAffGame ∷ MonadKill Error Fiber (AffGame extra) where
  kill error fiber = liftAff (kill error fiber)

instance monadBracketAffGame ∷ MonadBracket Error Fiber (AffGame extra) where
  bracket (AffGame acquire) release run = AffGame \r →
    bracket (acquire r)
      (\c a → runGameAff r (release c a))
      (\a → runGameAff r (run a))
  uninterruptible k = AffGame \r ->
    uninterruptible (runGameAff r k)
  never = liftAff never

instance altAffGame ∷ Alt (AffGame extra) where
  alt (AffGame a) (AffGame b) = AffGame \r → a r <|> b r

instance plusAffGame ∷ Plus (AffGame extra) where
  empty = liftAff empty

instance semigroupAffGame ∷ Semigroup a ⇒ Semigroup (AffGame extra a) where
  append = lift2 append

instance monoidAffGame ∷ Monoid a ⇒ Monoid (AffGame extra a) where
  mempty = pure mempty

instance lazyAffGame ∷ Lazy (AffGame extra a) where
  defer f = pure unit >>= f

instance parallelAffGame ∷ Parallel (ParAffGame extra) (AffGame extra) where
  parallel = over AffGame (map parallel)
  sequential = over ParAffGame (map sequential)

-- |
newtype ParAffGame extra a = ParAffGame (Reducer extra Req → ParAff a)

derive instance newtypeParAffGame ∷ Newtype (ParAffGame extra a) _

derive instance functorParAffGame ∷ Functor (ParAffGame extra)

instance applyParAffGame ∷ Apply (ParAffGame extra) where
  apply (ParAffGame a) (ParAffGame b) = ParAffGame \r → a r <*> b r

instance applicativeParAffGame ∷ Applicative (ParAffGame extra) where
  pure x = ParAffGame \_ → pure x

instance altParAffGame ∷ Alt (ParAffGame extra) where
  alt (ParAffGame a) (ParAffGame b) = ParAffGame \r → a r <|> b r

instance plusParAffGame ∷ Plus (ParAffGame extra) where
  empty = ParAffGame \_ → empty

instance semigroupParAffGame ∷ Semigroup a ⇒ Semigroup (ParAffGame extra a)
  where
    append = lift2 append

instance monoidParAffGame ∷ Monoid a ⇒ Monoid (ParAffGame extra a) where
  mempty = pure mempty


type AFFGAME extra = FProxy (AffGame extra)

_affGame ∷ SProxy "affGame"
_affGame = SProxy

liftAffGame ∷ ∀ extra a r. AffGame extra a → Run (affGame ∷ AFFGAME extra | r) a
liftAffGame = liftAffGameAt _affGame

liftAffGameAt ∷
  ∀ t extra a r s
  . IsSymbol s
  ⇒ Row.Cons s (AFFGAME extra) t r
  ⇒ SProxy s
  → AffGame extra a
  → Run r a
liftAffGameAt = lift

runAffGame ∷
  ∀ extra r
  . Reducer extra Req
  → Run (aff ∷ AFF, affGame ∷ AFFGAME extra | r) ~> Run (aff ∷ AFF | r)
runAffGame = runAffGameAt (SProxy ∷ _ "aff") _affGame

runAffGameAt ∷
  ∀ aff affGame extra r0 r1 r2
  . IsSymbol aff
  ⇒ IsSymbol affGame
  ⇒ Row.Cons aff AFF r0 r1
  ⇒ Row.Cons affGame (AFFGAME extra) r1 r2
  ⇒ SProxy aff
  → SProxy affGame
  → Reducer extra Req
  → Run r2 ~> Run r1
runAffGameAt aff affGame reducer = interpret
  (on affGame (runGameAff reducer >>> lift aff) send)

-- | Runs a base `AffGame` effect
runBaseAffGame ∷ ∀ extra. Run (affGame ∷ AFFGAME extra) ~> AffGame extra
runBaseAffGame = runBaseAffGameAt _affGame

-- | Runs a base `AffGame` effect at the provided label
runBaseAffGameAt ∷
  ∀ extra s r
  . IsSymbol s ⇒ Row.Cons s (AFFGAME extra) () r
  ⇒ SProxy s → Run r ~> AffGame extra
runBaseAffGameAt p = run (case_ # on p identity)

-- | Runs base `AffGame`, `Aff` and `Effect` together as one effect
runBaseAffGame' ∷
  ∀ extra
  . Run (effect ∷ EFFECT, aff ∷ AFF, affGame ∷ AFFGAME extra) ~> AffGame extra
runBaseAffGame' = runBaseAffGameAt'
  (SProxy ∷ _ "effect")
  (SProxy ∷ _ "aff")
  _affGame

-- | Runs base `AffGame`, `Aff` and `Effect` together as one effect at the
-- | provided labels
runBaseAffGameAt' ∷
  ∀ effect aff affGame extra r1 r2 r3
  . IsSymbol effect
  ⇒ IsSymbol aff
  ⇒ IsSymbol affGame
  ⇒ Row.Cons effect   EFFECT         () r1
  ⇒ Row.Cons aff      AFF            r1 r2
  ⇒ Row.Cons affGame (AFFGAME extra) r2 r3
  ⇒ SProxy effect
  → SProxy aff
  → SProxy affGame
  → Run r3 ~> AffGame extra
runBaseAffGameAt' effect aff affGame = case_
  # on effect  liftEffect
  # on aff     liftAff
  # on affGame identity
  # run


simpleAffGame ∷
  ∀ extra a. Run (effect ∷ EFFECT, aff ∷ AFF | extra) a → AffGame extra a
simpleAffGame game = AffGame \reducer → game
  # runReducer reducer
  # runBaseAff'

type AffGameUpdate extra e s a =
  GameUpdate extra Req (ExecOut e s a) Unit

type TemplateAffGame extra e s a =
  { init    ∷ Run (effect ∷ EFFECT, aff ∷ AFF) { env ∷ e, initState ∷ s }
  , updates ∷ Array (AffGameUpdate extra e s a)
  }

interpretAffGame ∷ ∀ e s a. Run (ExecOut e s a) Unit → Run (Interpreted e s) a
interpretAffGame execOut = forever execOut
  # runExceptAt _end
  # map fromLeft

parallelizeAffGame ∷
  ∀ e s a. Array (Run (Interpreted e s) a) → Run (Interpreted e s) a
parallelizeAffGame games = do
  stateRef ← askAt _stateRef
  env ← askAt _env
  games
    # map (   runReaderAt _stateRef stateRef
          >>> runReaderAt _env env
          >>> runBaseAff' )
    # parOneOfMap try
    # (=<<) (either throwError pure)
    # Run.liftAff

-- | Make an `AffGame` from a `TemplateAffGame`
mkAffGame ∷
  ∀ extra e s a
  . TemplateAffGame extra e s a
  → AffGame extra a
mkAffGame { init, updates } = AffGame \reducer → runBaseAff' do
  { env, initState } ← init
  stateRef ← newRef initState
  mkRunGame interpretAffGame parallelizeAffGame reducer updates
    # runReaderAt _stateRef stateRef
    # runReaderAt _env env

-- | Run an `AffGame` in `Run`
runGame ∷
  ∀ extra a r
  . Reducer extra Req
  → AffGame extra a
  → Run (aff ∷ AFF | r) a
runGame reducer game = Run.liftAff (runGameAff reducer game)

-- | Run an `AffGame` in `Aff`
runGameAff ∷
  ∀ extra a
  . Reducer extra Req
  → AffGame extra a
  → Aff a
runGameAff reducer (AffGame game) = game reducer

-- | Launch an `AffGame` in `Effect`, returning the `Fiber`.
launchGame ∷
  ∀ extra a
  . Reducer extra Req
  → AffGame extra a
  → Effect (Fiber a)
launchGame reducer game = launchAff do runGameAff reducer game

-- | Launch an `AffGame` in `Effect`. Discards the result value.
launchGame_ ∷
  ∀ extra a
  . Reducer extra Req
  → AffGame extra a
  → Effect Unit
launchGame_ reducer game = void do launchGame reducer game


onStart ∷
  ∀ extra e s a
  . Run (OnStartExecIn e s a extra) Unit
  → AffGameUpdate extra e s a
onStart effect = GameUpdate \reducer → do
  stateRef ← askAt _stateRef
  (runReducer reducer effect ∷ Run (OnStartExecIn e s a ()) Unit)
    # runStateWithRef stateRef
    # expand
  Run.liftAff never

loopUpdate ∷
  ∀ extra e s a b
  . Aff Unit
  → Run (LoopExecIn e s a extra) b
  → (b → Run (LoopExecIn e s a extra) b)
  → AffGameUpdate extra e s a
loopUpdate wait init loop = GameUpdate \reducer → do
  stateRef ← askAt _stateRef
  let
    init' = (runReducer reducer init ∷ Run (LoopExecIn e s a ()) b)
      # runReaderAt _dt (Seconds 0.0)
      # runStateWithRef stateRef
      # expand
    step { time, passThrough } = do
      now ← liftEffect nowSeconds
      passThrough' ←
        (runReducer reducer $ loop passThrough ∷ Run (LoopExecIn e s a ()) b)
          # runReaderAt _dt (now `over2 Seconds (-)` time)
          # runStateWithRef stateRef
          # expand
      pure { time: now, passThrough: passThrough' }
  iterateM
    (\prev → step prev <* liftAff wait)
    ({ time: _, passThrough: _} <$> nowSeconds <*> init')

loopUpdate' ∷
  ∀ extra e s a
  . Aff Unit
  → Run (LoopExecIn e s a extra) Unit
  → AffGameUpdate extra e s a
loopUpdate' wait loop = loopUpdate wait (pure unit) (const loop)

matchInterval ∷
  ∀ extra e s a d
  . Duration d
  ⇒ Aff Unit
  → Run (LoopExecIn e s a extra) d
  → Run (LoopExecIn e s a extra) Unit
  → AffGameUpdate extra e s a
matchInterval wait duration loop = loopUpdate wait (askAt _dt) \accDt' → do
  d ← duration
  dt ← askAt _dt
  let newAccDt = case accDt' <> dt, convertDuration d of
        Seconds accDt, Seconds frameTime
          | accDt < frameTime       → Left accDt
          | frameTime <= 0.0        → Right 0.0
          | accDt > frameTime * 3.0 → Right 0.0
          | otherwise               → Right (accDt - frameTime)
  Seconds <$> case newAccDt of
    Left  accDt → pure accDt
    Right accDt → loop $> accDt


newtype FPS = FPS Number

derive instance newtypeFPS ∷ Newtype FPS _
derive newtype instance eqFPS ∷ Eq FPS
derive newtype instance ordFPS ∷ Ord FPS

instance showFPS ∷ Show FPS where
  show (FPS n) = "(FPS " <> show n <> ")"

instance durationFPS ∷ Duration FPS where
  fromDuration (FPS n) = Milliseconds if n == 0.0
    then 0.0
    else 1000.0 / n
  toDuration (Milliseconds n) = FPS if n == 0.0
    then 0.0
    else 1000.0 / n