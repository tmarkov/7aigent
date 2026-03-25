/// Integration tests for auxiliary LLM queries
///
/// These tests verify the full protocol round trip for auxiliary LLM queries.
///
/// Test 1: Agent receives auxiliary request and handles it with mock LLM
/// Test 2: Mock orchestrator subprocess sends request, agent responds
use agent::llm::mock::MockLlmClient;
use agent::llm::{CompletionRequest, LlmClient};
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use tempfile::TempDir;

#[tokio::test]
async fn test_agent_handles_auxiliary_request_with_mock_llm() {
    // Create a mock orchestrator subprocess that sends auxiliary request
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let workspace = temp_dir.path();

    // Create a Python script that sends auxiliary request and verifies response
    let test_script = r#"
import sys
import json

# Send auxiliary request
request = {
    "type": "auxiliary_llm_request",
    "request_id": "test-req-001",
    "prompt": "Summarize this code",
    "context": "def hello(): return 'world'"
}
json.dump(request, sys.stdout)
sys.stdout.write("\n")
sys.stdout.flush()

# Read response
line = sys.stdin.readline()
if not line:
    sys.exit(1)

response = json.loads(line)

# Verify response structure
assert response["type"] == "auxiliary_llm_response", f"Wrong type: {response.get('type')}"
assert response["request_id"] == "test-req-001", f"Wrong request_id: {response.get('request_id')}"
assert "response" in response, "Missing response field"
assert response["response"] == "Mock summary of code", f"Wrong response: {response.get('response')}"

# Signal success
print("AUXILIARY_TEST_PASSED", file=sys.stderr)
sys.stderr.flush()
"#;

    std::fs::write(workspace.join("test_auxiliary.py"), test_script)
        .expect("Failed to write test script");

    // Spawn the test script as orchestrator
    let mut child = Command::new("python3")
        .arg(workspace.join("test_auxiliary.py"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Failed to spawn test script");

    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut stderr = BufReader::new(child.stderr.take().unwrap());

    let mut reader = BufReader::new(stdout);

    // Read the auxiliary request from the script
    let mut request_line = String::new();
    reader
        .read_line(&mut request_line)
        .expect("Failed to read request");

    let request: serde_json::Value =
        serde_json::from_str(&request_line).expect("Failed to parse request");

    // Verify it's an auxiliary request
    assert_eq!(request["type"], "auxiliary_llm_request");
    assert_eq!(request["request_id"], "test-req-001");
    assert_eq!(request["prompt"], "Summarize this code");

    // Create mock LLM and agent to handle the request
    let mock_llm = MockLlmClient::new("Mock summary of code");

    // Simulate agent handling the request
    // We'll create the LLM messages and call the mock
    let llm_request = CompletionRequest {
        messages: vec![
            agent::llm::LlmMessage::system(
                "You specialize in providing concise summaries and explanations.".to_string(),
            ),
            agent::llm::LlmMessage::user(format!(
                "{}\n\nContext:\n{}",
                request["prompt"].as_str().unwrap(),
                request["context"].as_str().unwrap()
            )),
        ],
        model: "gpt-4".to_string(),
        max_tokens: Some(5000),
        temperature: Some(0.7),
        reasoning_effort: None,
    };

    let llm_response = mock_llm.complete(llm_request).await.unwrap();

    // Send response back to script
    let response = serde_json::json!({
        "type": "auxiliary_llm_response",
        "request_id": "test-req-001",
        "response": llm_response.content,
    });

    serde_json::to_writer(&mut stdin, &response).expect("Failed to write response");
    stdin.write_all(b"\n").expect("Failed to write newline");
    stdin.flush().expect("Failed to flush");

    // Read stderr to see if test passed
    let mut stderr_output = String::new();
    stderr
        .read_line(&mut stderr_output)
        .expect("Failed to read stderr");

    assert!(
        stderr_output.contains("AUXILIARY_TEST_PASSED"),
        "Test script did not pass: {}",
        stderr_output
    );

    // Verify mock LLM was called correctly
    let requests = mock_llm.get_requests();
    assert_eq!(requests.len(), 1, "Mock LLM should be called once");

    let recorded_request = &requests[0];
    assert_eq!(
        recorded_request.messages.len(),
        2,
        "Should have system + user message"
    );
    assert_eq!(recorded_request.messages[0].role, "system");
    assert_eq!(recorded_request.messages[1].role, "user");
    assert!(recorded_request.messages[1].content.contains("Summarize"));
    assert!(recorded_request.messages[1].content.contains("def hello()"));

    // Clean up
    drop(stdin);
    let status = child.wait().expect("Failed to wait for child");
    assert!(status.success(), "Test script exited with error");
}

#[tokio::test]
async fn test_orchestrator_auxiliary_query_with_mock_agent() {
    // Create a test that runs the orchestrator's request_auxiliary_llm_query()
    // with a mock agent responding

    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let workspace = temp_dir.path();

    // Create a Python script that uses request_auxiliary_llm_query
    let test_script = r#"
import sys
import os

# Add orchestrator to path
sys.path.insert(0, os.environ.get('ORCHESTRATOR_PATH', '.'))

from orchestrator.auxiliary import request_auxiliary_llm_query

try:
    # Call the function - it will send request to stdin and wait for response
    response = request_auxiliary_llm_query(
        "Explain this function",
        "def add(a, b): return a + b"
    )

    # Verify we got a response
    assert isinstance(response, str), f"Response should be string, got {type(response)}"
    assert len(response) > 0, "Response should not be empty"
    assert response == "Mock explanation", f"Wrong response: {response}"

    print("ORCHESTRATOR_TEST_PASSED", file=sys.stderr)
    sys.stderr.flush()
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.stderr.flush()
    sys.exit(1)
"#;

    std::fs::write(workspace.join("test_orchestrator.py"), test_script)
        .expect("Failed to write test script");

    // Spawn the test script
    // Use ORCHESTRATOR_PATH from the build environment if available (e.g. Nix build),
    // otherwise fall back to the repo-relative path for local development.
    let orchestrator_path = std::env::var("ORCHESTRATOR_PATH").unwrap_or_else(|_| {
        std::env::current_dir()
            .unwrap()
            .join("orchestrator")
            .to_str()
            .unwrap()
            .to_string()
    });

    let mut child = Command::new("python3")
        .arg(workspace.join("test_orchestrator.py"))
        .env("ORCHESTRATOR_PATH", orchestrator_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("Failed to spawn test script");

    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut stderr = BufReader::new(child.stderr.take().unwrap());

    let mut reader = BufReader::new(stdout);

    // Read the auxiliary request that the script sends
    let mut request_line = String::new();
    reader
        .read_line(&mut request_line)
        .expect("Failed to read auxiliary request");

    let request: serde_json::Value =
        serde_json::from_str(&request_line).expect("Failed to parse request");

    // Verify it's a proper auxiliary request
    assert_eq!(request["type"], "auxiliary_llm_request");
    let request_id = request["request_id"].as_str().unwrap();
    assert!(
        request_id.starts_with("aux-"),
        "Request ID should start with aux-"
    );
    assert_eq!(request["prompt"], "Explain this function");
    assert_eq!(request["context"], "def add(a, b): return a + b");

    // Send mock response back
    let response = serde_json::json!({
        "type": "auxiliary_llm_response",
        "request_id": request_id,
        "response": "Mock explanation",
    });

    serde_json::to_writer(&mut stdin, &response).expect("Failed to write response");
    stdin.write_all(b"\n").expect("Failed to write newline");
    stdin.flush().expect("Failed to flush");

    // Read stderr to see if test passed
    let mut stderr_output = String::new();
    stderr
        .read_line(&mut stderr_output)
        .expect("Failed to read stderr");

    assert!(
        stderr_output.contains("ORCHESTRATOR_TEST_PASSED"),
        "Orchestrator test did not pass: {}",
        stderr_output
    );

    // Clean up
    drop(stdin);
    let status = child.wait().expect("Failed to wait for child");
    assert!(status.success(), "Test script exited with error");
}
