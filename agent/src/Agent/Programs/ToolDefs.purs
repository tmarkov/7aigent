module Agent.Programs.ToolDefs
    ( toolDefinitions
    , ToolDef
    , ToolParam
    ) where

import Agent.Types (ToolName(..))

type ToolParam =
    { name :: String
    , schemaType :: String
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
              , schemaType: "string"
              , description:
                    "Julia source code to execute."
              , required: true
              }
            , { name: "timeout_seconds"
              , schemaType: "integer"
              , description:
                    "Initial timeout-check deadline for this execution."
              , required: true
              }
            ]
      }
    , { name: GitStage
       , description:
            "Stage all current changes or the selected CodeTree-backed selectors."
       , parameters:
            [ { name: "what"
              , schemaType: "string"
              , description:
                    "Which current changes to stage: 'all' or a list of selectors."
              , required: true
              }
            ]
       }
    , { name: GitCommit
       , description:
            "Commit changes to the repository."
       , parameters:
            [ { name: "what"
              , schemaType: "string"
              , description:
                    "Which changes to commit: 'staged', 'all', or a list of selectors."
              , required: true
              }
            , { name: "message"
              , schemaType: "string"
              , description:
                    "Commit message subject line."
              , required: true
              }
            , { name: "body"
              , schemaType: "string"
              , description:
                    "Optional commit message body."
              , required: false
              }
            ]
      }
    ]
