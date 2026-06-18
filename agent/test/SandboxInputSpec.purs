-- | Tests for sandbox global stdin FIFO writes: A17a + S8a.
module Test.SandboxInputSpec where

import Prelude

import Data.Array (replicate)
import Data.Either (Either(..), isLeft)
import Data.String as String
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldSatisfy)

sandboxInputSpec :: Spec Unit
sandboxInputSpec = do

  describe "A17a + S8a: bounded sandbox stdin FIFO writes" do

    it "A17a + S8a: writes a short value completely" do
      result <- runFifoCase testSuccessfulFifoWriteImpl "hello\n"
      result `shouldEqual` Right "hello\n"

    it "A17a: rejects oversized timeout input before writing" do
      let oversized = String.joinWith "" (replicate 4097 "x")
      result <- runFifoCase testOversizeFifoWriteImpl oversized
      result `shouldSatisfy` isLeft
      case result of
        Left err -> err `shouldSatisfy` contains "4096 byte limit"
        Right _ -> pure unit

    it "A17a: reports would-block instead of hanging when the FIFO is full" do
      result <- runFifoCase testWouldBlockFifoWriteImpl "x"
      result `shouldSatisfy` isLeft
      case result of
        Left err -> err `shouldSatisfy` contains "would block"
        Right _ -> pure unit

  where
  contains :: String -> String -> Boolean
  contains needle haystack =
    String.contains (String.Pattern needle) haystack

runFifoCase
  :: (String -> (String -> Effect Unit) -> (String -> Effect Unit) -> Effect Unit)
  -> String
  -> Aff (Either String String)
runFifoCase run value = makeAff \resolve -> do
  run value
    (\err -> resolve (Right (Left err)))
    (\output -> resolve (Right (Right output)))
  pure nonCanceler

foreign import testSuccessfulFifoWriteImpl
  :: String -> (String -> Effect Unit) -> (String -> Effect Unit) -> Effect Unit

foreign import testOversizeFifoWriteImpl
  :: String -> (String -> Effect Unit) -> (String -> Effect Unit) -> Effect Unit

foreign import testWouldBlockFifoWriteImpl
  :: String -> (String -> Effect Unit) -> (String -> Effect Unit) -> Effect Unit
