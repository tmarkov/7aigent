module Agent.Programs.Template
    ( substituteTemplate
    ) where

import Prelude
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.String.CodeUnits as CU
import Agent.Types (AppError(..))

substituteTemplate
    :: Map.Map String String
    -> String
    -> Either AppError String
substituteTemplate vars template =
    go "" template
  where
    go :: String -> String -> Either AppError String
    go acc remaining = case nextOpen remaining of
        Nothing ->
            if String.contains (String.Pattern "}}") remaining
            then Left (TemplateError
                "Unmatched '}}' in template")
            else Right (acc <> remaining)
        Just { before, afterOpen } ->
            case nextClose afterOpen of
                Nothing ->
                    Left (TemplateError
                        "Unmatched '{{' in template")
                Just { key, afterClose } ->
                    if String.null key
                    then Left (TemplateError
                        ("Empty placeholder '{{}}' "
                        <> "in template"))
                    else if String.contains
                        (String.Pattern "{{") key
                    then Left (TemplateError
                        ("Nested '{{' inside "
                        <> "placeholder: " <> key))
                    else case Map.lookup key vars of
                        Nothing ->
                            Left (TemplateError
                                ("Unknown variable: "
                                <> key))
                        Just val ->
                            go (acc <> before <> val)
                                afterClose

    nextOpen
        :: String
        -> Maybe { before :: String
                 , afterOpen :: String }
    nextOpen s =
        case CU.indexOf (String.Pattern "{{") s of
            Nothing -> Nothing
            Just i ->
                Just { before: CU.take i s
                     , afterOpen: CU.drop (i + 2) s
                     }

    nextClose
        :: String
        -> Maybe { key :: String
                 , afterClose :: String }
    nextClose s =
        case CU.indexOf (String.Pattern "}}") s of
            Nothing -> Nothing
            Just i ->
                Just { key: CU.take i s
                     , afterClose: CU.drop (i + 2) s
                     }
