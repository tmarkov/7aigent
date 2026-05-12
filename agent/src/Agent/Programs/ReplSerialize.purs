module Agent.Programs.ReplSerialize
    ( buildSerializationSnippet
    , buildRestoreSnippet
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
            , "    _names = names(Main, all=false, imported=false)"
            , "    open(\"" <> statePath <> "\", \"w\") do _io"
            , "        for _n in _names"
            , "        try"
            , "            _buf = IOBuffer()"
            , "            Serialization.serialize(_buf, getfield(Main, _n))"
            , "            Serialization.serialize(_io, (String(_n), take!(_buf)))"
            , "        catch e"
            , "            @warn \"Skipping"
              <> " $(_n): $(e)\""
            , "        end"
            , "        end"
            , "    end"
            , "end"
            ]

buildRestoreSnippet :: SessionId -> String -> String
buildRestoreSnippet (SessionId sid) workspacePath =
    let statePath =
            workspacePath <> "/.7aigent/sessions/"
            <> show sid <> "/julia_state.jls"
    in String.joinWith "\n"
        [ "let"
        , "    _state_path = \"" <> statePath <> "\""
        , "    if isfile(_state_path)"
        , "        open(_state_path, \"r\") do _io"
        , "            while !eof(_io)"
        , "                _entry = try"
        , "                    Serialization.deserialize(_io)"
        , "                catch e"
        , "                    println(\"Warning: failed to read serialized entry: \" * sprint(showerror, e))"
        , "                    break"
        , "                end"
        , "                try"
        , "                    _name, _payload = _entry"
        , "                    _value = Serialization.deserialize(IOBuffer(_payload))"
        , "                    Core.eval(Main, Expr(:(=), Symbol(_name), _value))"
        , "                catch e"
        , "                    println(\"Warning: failed to restore \" * string(first(_entry)) * \": \" * sprint(showerror, e))"
        , "                end"
        , "            end"
        , "        end"
        , "    else"
        , "        println(\"Warning: julia_state.jls missing; globals will not be restored\")"
        , "    end"
        , "end"
        ]
