-- | Terminal output helpers.
module Agent.Services.Terminal
    ( printLn
    , printStr
    , printErr
    ) where

import Prelude
import Effect (Effect)

foreign import printLnImpl  :: String -> Effect Unit
foreign import printStrImpl :: String -> Effect Unit
foreign import printErrImpl :: String -> Effect Unit

-- | Write a line to stdout.
printLn :: String -> Effect Unit
printLn = printLnImpl

-- | Write a string to stdout without a trailing newline.
printStr :: String -> Effect Unit
printStr = printStrImpl

-- | Write a line to stderr.
printErr :: String -> Effect Unit
printErr = printErrImpl
