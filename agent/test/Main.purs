module Test.Main where

import Prelude
import Effect (Effect)
import Effect.Aff (launchAff_)
import Data.Maybe (Maybe(..))
import Data.Time.Duration (Milliseconds(..))
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner (defaultConfig, runSpec')

import Test.CLISpec (cliSpec)
import Test.CompactionSpec (compactionSpec)
import Test.ConfigSpec (configSpec)
import Test.ControllerSpec (controllerSpec)
import Test.GitCommitSpec (gitCommitSpec)
import Test.GitStageSpec (gitStageSpec)
import Test.InterruptionSpec (interruptionSpec)
import Test.JuliaDefsSpec (juliaDefsSpec)
import Test.JupyterSpec (jupyterSpec)
import Test.McpSpec (mcpSpec)
import Test.OutputThresholdSpec (outputThresholdSpec)
import Test.ReactStepSpec (reactStepSpec)
import Test.ReflectionSpec (reflectionSpec)
import Test.ReplSerializeSpec (replSerializeSpec)
import Test.RetrySpec (retrySpec)
import Test.SandboxPreflightSpec (sandboxPreflightSpec)
import Test.SessionListingSpec (sessionListingSpec)
import Test.SessionLogSpec (sessionLogSpec)
import Test.SessionResumeSpec (sessionResumeSpec)
import Test.StartupSpec (startupSpec)
import Test.StdinRequestSpec (stdinRequestSpec)
import Test.SummaryRequestSpec (summaryRequestSpec)
import Test.SteeringSpec (steeringSpec)
import Test.TemplateSpec (templateSpec)
import Test.TimeoutSpec (timeoutSpec)
import Test.ToolStepSpec (toolStepSpec)
import Test.ToolDefsSpec (toolDefsSpec)
import Test.ToolInputSpec (toolInputSpec)
import Test.ToolExecutionSpec (toolExecutionSpec)
import Test.WireFormatSpec (wireFormatSpec)
import Test.RoundStepSpec (roundStepSpec)

main :: Effect Unit
main = launchAff_ $ runSpec' (defaultConfig { timeout = Just (Milliseconds 5000.0) })
  [ consoleReporter ] do
  cliSpec
  compactionSpec
  configSpec
  controllerSpec
  gitCommitSpec
  gitStageSpec
  interruptionSpec
  juliaDefsSpec
  jupyterSpec
  mcpSpec
  outputThresholdSpec
  reactStepSpec
  reflectionSpec
  replSerializeSpec
  retrySpec
  roundStepSpec
  sandboxPreflightSpec
  sessionListingSpec
  sessionLogSpec
  sessionResumeSpec
  startupSpec
  stdinRequestSpec
  summaryRequestSpec
  steeringSpec
  templateSpec
  timeoutSpec
  toolStepSpec
  toolDefsSpec
  toolInputSpec
  toolExecutionSpec
  wireFormatSpec
