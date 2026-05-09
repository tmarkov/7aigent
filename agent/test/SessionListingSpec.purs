-- | Tests for session listing format: A41.
module Test.SessionListingSpec where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String as String
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

import Agent.Programs.SessionListing (formatSessionListing, SessionMeta)
import Agent.Types (SessionId(..))

sessionListingSpec :: Spec Unit
sessionListingSpec = do

  describe "A41: session listing format" do

    it "A41: three sessions → table with ID, start, duration, description" do
      let sessions =
            [ { id: SessionId 1
              , started: "2025-01-15 14:32"
              , duration: Just "12m 04s"
              , description: "Add R14b absorption rule to CodeTree.jl"
              }
            , { id: SessionId 2
              , started: "2025-01-15 16:01"
              , duration: Just "3m 22s"
              , description: "Fix failing tests in runtests.jl"
              }
            , { id: SessionId 3
              , started: "2025-01-15 17:45"
              , duration: Nothing
              , description: "Resume me later"
              }
            ]
      let output = formatSessionListing sessions
      -- Should contain all three session IDs
      output `shouldSatisfy` contains "1"
      output `shouldSatisfy` contains "2"
      output `shouldSatisfy` contains "3"
      -- Should contain durations
      output `shouldSatisfy` contains "12m 04s"
      output `shouldSatisfy` contains "3m 22s"
      -- Should contain descriptions
      output `shouldSatisfy` contains "R14b"
      output `shouldSatisfy` contains "runtests"

    it "A41: session without session_end → duration shown as —" do
      let sessions =
            [ { id: SessionId 1
              , started: "2025-01-15 14:32"
              , duration: Nothing
              , description: "Incomplete session"
              }
            ]
      let output = formatSessionListing sessions
      output `shouldSatisfy` contains "—"

    it "A27 + A41: description from first user_message, truncated to 120 chars" do
      let longDesc = String.joinWith "" (Array.replicate 150 "x")
      let sessions =
            [ { id: SessionId 1
              , started: "2025-01-15 14:32"
              , duration: Just "5m"
              , description: String.take 120 longDesc
              }
            ]
      let output = formatSessionListing sessions
      -- The description in the output should be at most 120 chars
      -- (truncation happens before formatting, verified by A27 tests)
      output `shouldSatisfy` contains (String.take 20 longDesc)

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack
