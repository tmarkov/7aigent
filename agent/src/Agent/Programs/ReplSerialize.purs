module Agent.Programs.ReplSerialize
    ( buildSerializationSnippet
    ) where

import Prelude
import Data.String as String
import Agent.Types (SessionId(..))

buildSerializationSnippet :: SessionId -> String -> String
buildSerializationSnippet (SessionId sid) workspacePath =
    let sessionDir =
            workspacePath <> "/.7aigent/sessions/"
            <> show sid
        statePath = sessionDir <> "/julia_state.jls"
    in  String.joinWith "\n"
            [ "let"
            , "    _names = names(Main, all=false,"
              <> " imported=false)"
            , "    for _n in _names"
            , "        try"
            , "            Serialization.serialize(\""
              <> statePath
              <> "\", getfield(Main, _n))"
            , "        catch e"
            , "            @warn \"Skipping"
              <> " $(_n): $(e)\""
            , "        end"
            , "    end"
            , "end"
            ]
