module Agent.Programs.Jupyter
    ( collectOutput
    , IopubMessage(..)
    ) where

import Prelude
import Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.String as String

data IopubMessage
    = IopubStream
        { name :: String, text :: String }
    | IopubExecuteResult
        { "data" :: Map.Map String String }
    | IopubError
        { traceback :: Array String }
    | IopubDisplayData
        { "data" :: Map.Map String String }

collectOutput :: Array IopubMessage -> String
collectOutput msgs =
    String.joinWith "" (map extractText msgs)
  where
    extractText :: IopubMessage -> String
    extractText (IopubStream r) = r.text
    extractText (IopubExecuteResult r) =
        fromMaybe ""
            (Map.lookup "text/plain" r."data")
    extractText (IopubError r) =
        String.joinWith "\n" r.traceback
    extractText (IopubDisplayData r) =
        fromMaybe ""
            (Map.lookup "text/plain" r."data")
