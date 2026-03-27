//! Integration tests for agent -> sandbox -> orchestrator chain.
//!
//! These tests verify the full system works end-to-end:
//! - Agent spawns sandbox with orchestrator
//! - Commands sent through sandbox reach orchestrator
//! - Responses received correctly
//! - Multiple environments work (bash, python, editor)
//! - Workspace files accessible
//! - Error handling works
//! - Clean shutdown
//!
//! These are TIER 1 tests - fast integration tests that spawn real subprocesses (~2-5s).
//! Timeouts enforce test completion to prevent hanging the test suite.

use agent::container::ContainerManager;
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::TempDir;

/// Maximum time allowed for the entire integration test (3 minutes)
const TEST_TIMEOUT_SECS: u64 = 180;

/// Test execution log for diagnostics on timeout/failure
#[derive(Debug, Clone)]
struct TestLog {
    entries: Vec<String>,
}

impl TestLog {
    fn new() -> Arc<Mutex<Self>> {
        Arc::new(Mutex::new(TestLog {
            entries: Vec::new(),
        }))
    }

    fn log(log: &Arc<Mutex<TestLog>>, msg: impl Into<String>) {
        let msg = msg.into();
        eprintln!("{}", msg);
        log.lock().unwrap().entries.push(msg);
    }

    fn dump(&self) -> String {
        self.entries.join("\n")
    }
}

/// Comprehensive integration test with STRICT timeout enforcement.
///
/// Requirements tested:
/// 1. Agent can spawn sandbox with orchestrator
/// 2. Can send commands and receive responses
/// 3. Multiple sequential commands work
/// 4. Commands work across different environments (bash, python, editor)
/// 5. Error handling works correctly
/// 6. Workspace access works (read files, subdirectories)
/// 7. Sandbox shuts down cleanly
///
/// If test exceeds TEST_TIMEOUT_SECS, it FAILS immediately with full diagnostic log.
#[test]
fn test_agent_orchestrator_integration() {
    // Create shared log for diagnostics
    let log = TestLog::new();
    let log_clone = log.clone();

    // Run test in thread with timeout
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        let result = std::panic::catch_unwind(|| {
            run_integration_test(log_clone);
        });
        let _ = tx.send(result);
    });

    // Enforce timeout
    match rx.recv_timeout(Duration::from_secs(TEST_TIMEOUT_SECS)) {
        Ok(Ok(())) => {
            // Test passed
        }
        Ok(Err(e)) => {
            // Test panicked - show log before re-panicking
            let log_dump = log.lock().unwrap().dump();
            eprintln!("\n=== TEST FAILED - EXECUTION LOG ===");
            eprintln!("{}", log_dump);
            eprintln!("=== END LOG ===\n");
            std::panic::resume_unwind(e);
        }
        Err(_) => {
            // Timeout - show full log to diagnose hang
            let log_dump = log.lock().unwrap().dump();
            panic!(
                "\n=== TEST TIMEOUT ===\n\
                Integration test exceeded {} seconds.\n\
                Sandbox/orchestrator likely hung during execution.\n\
                \n\
                === EXECUTION LOG (shows last successful step) ===\n\
                {}\n\
                === END LOG ===\n",
                TEST_TIMEOUT_SECS, log_dump
            );
        }
    }
}

/// Actual test logic (run in thread for timeout enforcement)
fn run_integration_test(log: Arc<Mutex<TestLog>>) {
    let start_time = Instant::now();

    // Create temp project directory with test files
    TestLog::log(&log, "Creating temporary test workspace");
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    std::fs::write(temp_dir.path().join("test.txt"), "test content")
        .expect("Failed to write test.txt");
    std::fs::write(temp_dir.path().join("data.txt"), "42").expect("Failed to write data.txt");
    std::fs::write(
        temp_dir.path().join("script.py"),
        "print('Hello from Python')\n",
    )
    .expect("Failed to write script.py");
    std::fs::create_dir(temp_dir.path().join("subdir")).expect("Failed to create subdir");
    std::fs::write(temp_dir.path().join("subdir/nested.txt"), "nested file")
        .expect("Failed to write nested.txt");

    TestLog::log(&log, "=== Test 1: Sandbox Spawn ===");
    let manager = ContainerManager::new().expect("Failed to create container manager");

    TestLog::log(&log, "Spawning sandbox with orchestrator...");
    let config = agent::config::SandboxConfig::default();
    let mut handle = manager
        .spawn_container(temp_dir.path(), &config)
        .expect("Failed to spawn sandbox");
    TestLog::log(&log, "✓ Sandbox spawned successfully");

    TestLog::log(&log, "=== Test 2: Basic Bash Command ===");
    TestLog::log(&log, "Sending: bash 'echo hello'");
    handle
        .send_command("bash", "echo hello")
        .expect("Failed to send echo command");

    TestLog::log(&log, "Waiting for response...");
    let (response, screen) = handle
        .receive_response()
        .expect("Failed to receive echo response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(response.processed, "Echo command should execute");
    assert_eq!(response.exit_code, Some(0), "Echo should succeed (exit 0)");
    assert!(
        response.output.contains("hello"),
        "Output should contain 'hello', got: {:?}",
        response.output
    );
    TestLog::log(&log, "✓ Basic bash command works");

    // Verify screen has all expected environments
    assert!(
        screen.sections.contains_key("bash"),
        "Screen should have bash section"
    );
    assert!(
        screen.sections.contains_key("python"),
        "Screen should have python section"
    );
    assert!(
        screen.sections.contains_key("editor"),
        "Screen should have editor section"
    );
    TestLog::log(&log, "✓ Screen state has all environments");

    TestLog::log(&log, "=== Test 3: Workspace File Access ===");
    TestLog::log(&log, "Sending: bash 'ls'");
    handle
        .send_command("bash", "ls")
        .expect("Failed to send ls command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive ls response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(response.processed, "ls command should execute");
    assert_eq!(response.exit_code, Some(0), "ls should succeed (exit 0)");
    assert!(
        response.output.contains("test.txt"),
        "Should see test.txt in workspace"
    );
    assert!(
        response.output.contains("data.txt"),
        "Should see data.txt in workspace"
    );
    assert!(
        response.output.contains("script.py"),
        "Should see script.py in workspace"
    );
    TestLog::log(&log, "✓ Workspace files visible");

    TestLog::log(&log, "Sending: bash 'cat data.txt'");
    handle
        .send_command("bash", "cat data.txt")
        .expect("Failed to send cat command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive cat response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(response.processed, "cat command should execute");
    assert_eq!(response.exit_code, Some(0), "cat should succeed (exit 0)");
    assert!(
        response.output.contains("42"),
        "Should read file content '42'"
    );
    TestLog::log(&log, "✓ Can read workspace files");

    TestLog::log(&log, "Sending: bash 'cat subdir/nested.txt'");
    handle
        .send_command("bash", "cat subdir/nested.txt")
        .expect("Failed to send nested cat command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive nested cat response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(response.processed, "nested cat should execute");
    assert_eq!(
        response.exit_code,
        Some(0),
        "nested cat should succeed (exit 0)"
    );
    assert!(
        response.output.contains("nested file"),
        "Should read nested file content"
    );
    TestLog::log(&log, "✓ Can access nested directories");

    TestLog::log(&log, "=== Test 4: Python Environment ===");
    TestLog::log(&log, "Sending: python 'print(2 + 2)'");
    handle
        .send_command("python", "print(2 + 2)")
        .expect("Failed to send python command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive python response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(response.processed, "Python command should succeed");
    assert!(response.output.contains("4"), "Python should compute 2+2=4");
    TestLog::log(&log, "✓ Python environment works");

    TestLog::log(&log, "Sending: python 'import math; print(math.pi)'");
    handle
        .send_command("python", "import math; print(math.pi)")
        .expect("Failed to send python import command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive python import response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(response.processed, "Python import should succeed");
    assert!(response.output.contains("3.14"), "Should print pi value");
    TestLog::log(&log, "✓ Python imports work");

    TestLog::log(&log, "=== Test 5: Editor Environment ===");
    TestLog::log(&log, "Sending: editor 'peek /test/ in test.txt'");
    handle
        .send_command("editor", "read-only-peek /test/ in test.txt")
        .expect("Failed to send editor command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _screen) = handle
        .receive_response()
        .expect("Failed to receive editor response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(response.processed, "Editor read-only-peek should succeed");

    // Check that response contains content from the file
    assert!(
        response.output.contains("test content") || response.output.contains("test.txt"),
        "Editor read-only-peek should return file content, got: {:?}",
        response.output
    );
    TestLog::log(&log, "✓ Editor environment works");

    TestLog::log(&log, "=== Test 6: Environment Switching ===");
    TestLog::log(&log, "Sending: bash 'pwd'");
    handle
        .send_command("bash", "pwd")
        .expect("Failed to send pwd command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive pwd response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(response.processed, "pwd command should execute");
    assert_eq!(response.exit_code, Some(0), "pwd should succeed (exit 0)");
    TestLog::log(&log, "✓ Can switch between environments");

    TestLog::log(&log, "=== Test 7: Error Handling ===");
    TestLog::log(&log, "Sending: bash 'cat /nonexistent/file.txt'");
    handle
        .send_command("bash", "cat /nonexistent/file.txt")
        .expect("Failed to send failing command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive error response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    // Bash environment should execute the command (even though it fails)
    assert!(
        response.processed,
        "Command should execute (execution succeeds)"
    );
    assert_ne!(
        response.exit_code,
        Some(0),
        "cat nonexistent should fail (exit != 0)"
    );
    // Verify specific error type via output
    assert!(
        response.output.contains("No such file")
            || response.output.contains("cannot access")
            || response.output.contains("not found"),
        "Output should indicate file not found error"
    );
    TestLog::log(&log, "✓ Error output captured correctly");

    TestLog::log(&log, "Sending: python '1 / 0'");
    handle
        .send_command("python", "1 / 0")
        .expect("Failed to send python error command");

    TestLog::log(&log, "Waiting for response...");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive python error response");

    TestLog::log(
        &log,
        format!(
            "Response: processed={}, output={:?}",
            response.processed, response.output
        ),
    );
    assert!(
        response.processed,
        "Python command executes even with exception"
    );
    assert!(
        response.output.contains("ZeroDivisionError") || response.output.contains("division"),
        "Output should show Python exception"
    );
    TestLog::log(&log, "✓ Python exceptions captured correctly");

    TestLog::log(&log, "=== Test 8: Sequential Commands with State ===");
    TestLog::log(&log, "Sending: bash 'export MY_VAR=hello'");
    handle
        .send_command("bash", "export MY_VAR=hello")
        .expect("Failed to send export command");

    handle
        .receive_response()
        .expect("Failed to receive export response");

    TestLog::log(&log, "Sending: bash 'echo $MY_VAR'");
    handle
        .send_command("bash", "echo $MY_VAR")
        .expect("Failed to send echo var command");

    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive echo var response");

    assert!(response.processed, "echo $MY_VAR should execute");
    assert_eq!(response.exit_code, Some(0), "echo should succeed (exit 0)");
    assert!(
        response.output.contains("hello"),
        "Environment variable should persist across commands"
    );
    TestLog::log(&log, "✓ Bash state persists across commands");

    TestLog::log(&log, "Sending: python 'x = 100'");
    handle
        .send_command("python", "x = 100")
        .expect("Failed to send python assignment");

    handle
        .receive_response()
        .expect("Failed to receive python assignment response");

    TestLog::log(&log, "Sending: python 'print(x * 2)'");
    handle
        .send_command("python", "print(x * 2)")
        .expect("Failed to send python print x command");

    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive python print response");

    assert!(
        response.output.contains("200"),
        "Python variable should persist across commands"
    );
    TestLog::log(&log, "✓ Python state persists across commands");

    TestLog::log(&log, "=== Test 9: Bash Exit Codes ===");

    // Test: true command
    TestLog::log(&log, "Sending: bash 'true'");
    handle
        .send_command("bash", "true")
        .expect("Failed to send true command");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive true response");
    assert!(response.processed, "true should execute");
    assert_eq!(response.exit_code, Some(0), "true should exit 0");
    TestLog::log(&log, "✓ true exits with 0");

    // Test: false command
    TestLog::log(&log, "Sending: bash 'false'");
    handle
        .send_command("bash", "false")
        .expect("Failed to send false command");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive false response");
    assert!(
        response.processed,
        "false should execute (execution succeeds)"
    );
    assert_eq!(
        response.exit_code,
        Some(1),
        "false should exit 1 (operation fails)"
    );
    TestLog::log(&log, "✓ false exits with 1");

    // Test: exit command terminates bash process
    // Since the process exits with non-zero code, it should be treated as an error
    TestLog::log(&log, "Sending: bash 'exit 42'");
    handle
        .send_command("bash", "exit 42")
        .expect("Failed to send exit 42 command");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive exit 42 response");
    assert!(
        !response.processed,
        "exit 42 terminates process with error (non-zero exit)"
    );
    TestLog::log(&log, "✓ exit 42 terminates bash process (error)");

    // Test: exit 0 should be treated as clean termination
    TestLog::log(&log, "Sending: bash 'exit 0'");
    handle
        .send_command("bash", "exit 0")
        .expect("Failed to send exit 0 command");
    let (response, _) = handle
        .receive_response()
        .expect("Failed to receive exit 0 response");
    assert!(
        response.processed,
        "exit 0 terminates cleanly (processed=true)"
    );
    assert_eq!(
        response.exit_code,
        Some(0),
        "exit 0 should have exit code 0"
    );
    TestLog::log(&log, "✓ exit 0 terminates bash process cleanly");

    TestLog::log(&log, "=== Test 10: Sandbox Shutdown ===");
    handle.shutdown().expect("Failed to shutdown sandbox");
    TestLog::log(&log, "✓ Sandbox shut down cleanly");

    let duration = start_time.elapsed();
    let msg = format!(
        "=== All Integration Tests Passed! Total time: {:.1}s ===",
        duration.as_secs_f64()
    );
    TestLog::log(&log, msg);
}
