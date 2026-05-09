-- | Readline-based stdin service.
module Agent.Services.Stdin
    ( readLine
    , closeStdin
    , writePrompt
    ) where

import Prelude
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)

foreign import readLineImpl   :: (String -> Effect Unit) -> Effect Unit
foreign import closeStdinImpl :: Effect Unit
foreign import writePromptImpl :: String -> Effect Unit

-- | Read one line from stdin. Returns "" on EOF.
readLine :: Aff String
readLine = makeAff \resolve -> do
    readLineImpl (\line -> resolve (Right line))
    pure nonCanceler

-- | Close the readline interface.
closeStdin :: Effect Unit
closeStdin = closeStdinImpl

-- | Write a prompt string to stdout (no newline).
writePrompt :: String -> Effect Unit
writePrompt = writePromptImpl
