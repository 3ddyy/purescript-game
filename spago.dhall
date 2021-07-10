{ name = "game"
, dependencies =
  [ "aff"
  , "control"
  , "datetime"
  , "effect"
  , "either"
  , "exceptions"
  , "filterable"
  , "foldable-traversable"
  , "fork"
  , "functors"
  , "js-timers"
  , "maybe"
  , "newtype"
  , "now"
  , "parallel"
  , "polymorphic-vectors"
  , "prelude"
  , "refs"
  , "run"
  , "safe-coerce"
  , "tailrec"
  , "transformers"
  , "tuples"
  , "typelevel-prelude"
  , "unsafe-coerce"
  , "variant"
  , "web-dom"
  , "web-html"
  , "web-uievents"
  ]
, packages = ./packages.dhall
, sources = [ "src/**/*.purs" ]
, license = "MIT"
, repository = "https://github.com/artemisSystem/purescript-game.git"
}
