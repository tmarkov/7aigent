module Test.Main where

import Prelude
import Effect (Effect)
import Effect.Aff (launchAff_)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner (runSpec)

import Test.CLISpec (cliSpec)
import Test.CompactionSpec (compactionSpec)
import Test.ConfigSpec (configSpec)
import Test.GitCommitSpec (gitCommitSpec)
import Test.GitDiffSpec (gitDiffSpec)
import Test.InterruptionSpec (interruptionSpec)
import Test.JuliaDefsSpec (juliaDefsSpec)
import Test.JupyterSpec (jupyterSpec)
import Test.McpSpec (mcpSpec)
import Test.OutputThresholdSpec (outputThresholdSpec)
import Test.ReactStepSpec (reactStepSpec)
import Test.ReplSerializeSpec (replSerializeSpec)
import Test.RetrySpec (retrySpec)
import Test.SandboxPreflightSpec (sandboxPreflightSpec)
import Test.SessionListingSpec (sessionListingSpec)
import Test.SessionLogSpec (sessionLogSpec)
import Test.SessionResumeSpec (sessionResumeSpec)
import Test.StartupSpec (startupSpec)
import Test.SteeringSpec (steeringSpec)
import Test.TemplateSpec (templateSpec)
import Test.TimeoutSpec (timeoutSpec)
import Test.ToolDefsSpec (toolDefsSpec)

main :: Effect Unit
main = launchAff_ $ runSpec [ consoleReporter ] do
  cliSpec
  compactionSpec
  configSpec
  gitCommitSpec
  gitDiffSpec
  interruptionSpec
  juliaDefsSpec
  jupyterSpec
  mcpSpec
  outputThresholdSpec
  reactStepSpec
  replSerializeSpec
  retrySpec
  sandboxPreflightSpec
  sessionListingSpec
  sessionLogSpec
  sessionResumeSpec
  startupSpec
  steeringSpec
  templateSpec
  timeoutSpec
  toolDefsSpec
