module Agent.Programs.ToolDefs
    ( toolDefinitions
    , ToolDef
    , ToolParam
    ) where

import Prelude ((<>))
import Agent.Types (ToolName(..))

type ToolParam =
    { name :: String
    , description :: String
    , required :: Boolean
    }

type ToolDef =
    { name :: ToolName
    , description :: String
    , parameters :: Array ToolParam
    }

toolDefinitions :: Array ToolDef
toolDefinitions =
    [ { name: JuliaRepl
      , description:
            "Execute Julia code in the sandbox REPL."
      , parameters:
            [ { name: "code"
              , description:
                    "Julia source code to execute."
              , required: true
              }
            ]
      }
    , { name: GitDiff
      , description:
            "Show the current git diff with hunk IDs."
      , parameters: []
      }
    , { name: GitCommit
      , description:
            "Commit changes to the repository."
      , parameters:
            [ { name: "what"
              , description:
                    "Which hunks to commit: 'all' or "
                    <> "a list of hunk IDs."
              , required: true
              }
            , { name: "message"
              , description:
                    "Commit message subject line."
              , required: true
              }
            , { name: "body"
              , description:
                    "Optional commit message body."
              , required: false
              }
            ]
      }
    ]
