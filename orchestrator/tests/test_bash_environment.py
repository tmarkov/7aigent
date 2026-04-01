"""Tests for bash environment."""

import tempfile
from pathlib import Path

from orchestrator.core_types import CommandText
from orchestrator.environments.bash import BashEnvironment

from . import timeout


class TestBashEnvironment:
    """Test BashEnvironment implementation."""

    @timeout(10)
    def test_bash_environment_maintains_state_across_commands(self) -> None:
        """Bash environment must maintain shell state between commands.

        Requirements tested:
        1. Environment variables persist across commands
        2. Working directory persists across commands
        3. Shell functions persist across commands
        4. All state persists in same process
        """
        env = BashEnvironment()
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                # Set up state: env var, directory, function
                env.handle_command(CommandText("export MY_VAR=hello"))
                env.handle_command(CommandText(f"cd {tmpdir}"))
                env.handle_command(CommandText("my_func() { echo $MY_VAR; }"))

                # Verify all state persists
                response = env.handle_command(CommandText("echo $MY_VAR"))
                assert "hello" in response.output, "Env var should persist"

                response = env.handle_command(CommandText("pwd"))
                assert tmpdir in response.output, "Directory should persist"

                response = env.handle_command(CommandText("my_func"))
                assert "hello" in response.output, "Function should persist"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_screen_reflects_state(self) -> None:
        """Screen must show current state after first use, and only help before first use.

        Requirements tested:
        1. Screen contains only help before first use (lazy state)
        2. Working directory appears in screen after first use
        3. Screen updates after each command
        4. Running background jobs appear in screen
        5. Help text always shown
        """
        env = BashEnvironment()
        try:
            help_text = env.get_help()

            # Before first use — screen must contain only help, no state
            screen_before = env.get_screen()
            assert (
                screen_before.content.strip() == help_text.strip()
            ), "Screen before first use must contain only help text"

            with tempfile.TemporaryDirectory() as tmpdir:
                # After first use — working directory must appear in screen
                env.handle_command(CommandText(f"cd {tmpdir}"))
                screen_after_cd = env.get_screen()
                assert (
                    tmpdir in screen_after_cd.content
                ), f"Current directory must appear in screen: {tmpdir}"

                # Screen updates after each command
                env.handle_command(CommandText("false"))
                screen_after_false = env.get_screen()
                assert (
                    screen_after_false.content != screen_after_cd.content
                ), "Screen must update after command"

                # Running background job appears in screen
                env.handle_command(CommandText("sleep 10 &"))
                screen = env.get_screen()
                assert (
                    "sleep" in screen.content
                ), "Running background job must appear in screen"

                # Help text always shown
                assert help_text in screen.content, "Help text must always be shown"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_captures_stdout_and_stderr(self) -> None:
        """Output capture must include both stdout and stderr (combined).

        Requirements tested:
        1. Stdout captured in output
        2. Stderr captured in output
        3. Output combined (matches terminal behavior)
        """
        env = BashEnvironment()
        try:
            # Command that writes to both stdout and stderr
            cmd = "echo 'stdout message' && echo 'stderr message' >&2"
            response = env.handle_command(CommandText(cmd))

            assert response.processed is True, "Command should succeed"
            assert "stdout message" in response.output, "Stdout must be captured"
            assert "stderr message" in response.output, "Stderr must be captured"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_provides_exit_code_field(self) -> None:
        """Exit codes must be tracked and provided in response.exit_code field.

        Requirements tested:
        1. Zero exit code (true) → response.exit_code = 0
        2. Non-zero exit code (false) → response.exit_code = 1
        3. processed is always True (unless infrastructure failure)
        4. Exit code shown in screen (screen updates when exit code changes)
        5. Exit code persists until next command (screen unchanged on repeat call)
        """
        env = BashEnvironment()
        try:
            # Success case
            response = env.handle_command(CommandText("true"))
            assert (
                response.processed is True
            ), "Command should be processed successfully"
            assert hasattr(
                response, "exit_code"
            ), "Response should have exit_code field"
            assert response.exit_code == 0, "Exit code 0 for successful command"

            # Exit code persists until next command (screen unchanged on repeat call)
            screen_after_success = env.get_screen()
            screen_repeat = env.get_screen()
            assert (
                screen_after_success.content == screen_repeat.content
            ), "Exit code must persist until next command (screen must not change)"

            # Failure case - command executed but operation failed
            response = env.handle_command(CommandText("false"))
            assert (
                response.processed is True
            ), "Command should be processed (execution succeeded)"
            assert hasattr(
                response, "exit_code"
            ), "Response should have exit_code field"
            assert response.exit_code == 1, "Exit code 1 for failed operation"

            # Screen must update to reflect the new (failed) exit code
            screen_after_failure = env.get_screen()
            assert (
                screen_after_failure.content != screen_after_success.content
            ), "Screen must update when exit code changes from 0 to 1"

            # Success again
            response = env.handle_command(CommandText("true"))
            assert response.processed is True, "Command should be processed"
            assert response.exit_code == 0, "Exit code should update to 0"

            screen_after_recovery = env.get_screen()
            assert (
                screen_after_recovery.content != screen_after_failure.content
            ), "Screen must update when exit code changes back to 0"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_tracks_background_jobs(self) -> None:
        """Background jobs must be tracked and shown in screen.

        Requirements tested:
        1. Background jobs (using &) are tracked
        2. Background jobs shown in screen with job info
        3. Jobs updated on each command
        """
        env = BashEnvironment()
        try:
            # Start a background job (sleep for short time)
            response = env.handle_command(CommandText("sleep 2 &"))
            assert response.processed is True, "Background job command should succeed"

            # Check screen shows background job
            screen = env.get_screen()
            assert (
                "sleep" in screen.content
            ), "Running background job must appear in screen"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_enforces_output_size_limit(self) -> None:
        """Large output must be truncated at MAX_OUTPUT_SIZE with warning.

        Requirements tested:
        1. Output over MAX_OUTPUT_SIZE is truncated
        2. Truncation warning message appended
        3. Output size is at most MAX_OUTPUT_SIZE + warning length
        """
        env = BashEnvironment()
        try:
            # Generate output larger than MAX_OUTPUT_SIZE (10MB)
            # Use Python to generate large output
            large_size = 11 * 1024 * 1024  # 11MB
            cmd = f"python3 -c \"print('A' * {large_size})\""

            response = env.handle_command(CommandText(cmd))

            # Should be truncated
            max_expected = BashEnvironment.MAX_OUTPUT_SIZE + 200  # Allow for warning
            assert (
                len(response.output) <= max_expected
            ), f"Output must be truncated at ~{BashEnvironment.MAX_OUTPUT_SIZE} bytes"

            assert (
                "[WARNING: Output truncated" in response.output
            ), "Must include truncation warning"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_help_text_always_shown(self) -> None:
        """Requirement: Help text must always appear in screen, before and after first use.

        Requirements tested:
        1. Help shown before first use
        2. Help shown after first use
        3. Help shown after many uses
        4. Help text is consistent across calls
        """
        env = BashEnvironment()
        try:
            # Retrieve help text via public API rather than hardcoding template strings
            help_text = env.get_help()
            assert help_text.strip(), "get_help() must return non-empty content"

            # Before first use
            screen_before = env.get_screen()
            assert (
                help_text in screen_before.content
            ), "Help must be shown before first use"

            # After first use
            env.handle_command(CommandText("echo test"))
            screen_after = env.get_screen()
            assert (
                help_text in screen_after.content
            ), "Help must be shown after first use"

            # After many uses
            env.handle_command(CommandText("pwd"))
            env.handle_command(CommandText("ls"))
            env.handle_command(CommandText("echo hello"))
            screen_later = env.get_screen()
            assert (
                help_text in screen_later.content
            ), "Help must persist after many commands"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_lifecycle(self) -> None:
        """Bash environment must handle initialization and shutdown correctly.

        Requirements tested:
        1. Environment can be created without starting process
        2. Process starts on first command
        3. Process can be started, used, and shutdown
        4. Shutdown terminates process
        5. Shutdown can be called before starting process (graceful)
        6. Shutdown can be called multiple times (idempotent)
        """
        # Before first use — screen contains only help (no active process state)
        env = BashEnvironment()
        help_text = env.get_help()
        screen = env.get_screen()
        assert (
            screen.content.strip() == help_text.strip()
        ), "Screen before first use must contain only help (process not started yet)"

        # First command starts process and produces output
        response = env.handle_command(CommandText("echo alive"))
        assert response.processed is True, "First command must succeed"
        assert "alive" in response.output, "Process must start and execute command"

        # Shutdown terminates process (must not raise)
        env.shutdown()

        # Shutdown before starting process is graceful (must not raise)
        env2 = BashEnvironment()
        env2.shutdown()

        # Shutdown is idempotent (multiple calls are safe)
        env3 = BashEnvironment()
        env3.handle_command(CommandText("echo test"))
        env3.shutdown()
        env3.shutdown()  # Should not raise

    @timeout(10)
    def test_bash_environment_handles_edge_cases(self) -> None:
        """Bash environment must handle edge cases gracefully.

        Requirements tested:
        1. Empty command handled (succeeds with no output)
        2. Multiline output captured correctly
        3. Special characters in output preserved
        """
        env = BashEnvironment()
        try:
            # Empty command
            response = env.handle_command(CommandText(""))
            assert (
                response.processed is True
            ), "Empty command should succeed (bash treats it as no-op)"

            # Multiline output
            response = env.handle_command(
                CommandText("echo -e 'line1\\nline2\\nline3'")
            )
            assert response.processed is True
            assert "line1" in response.output
            assert "line2" in response.output
            assert "line3" in response.output

            # Special characters
            response = env.handle_command(
                CommandText("echo 'special: !@#$%^&*()[]{}|\\\"'")
            )
            assert response.processed is True
            assert "special:" in response.output
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_get_help_loads_builtin_template(self) -> None:
        """Requirement: get_help() must return the built-in bash help template content.

        The help template must contain bash-tagged example blocks so the agent
        can see concrete examples of how to use the environment.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            env = BashEnvironment(project_dir=Path(tmpdir))
            help_text = env.get_help()

            assert help_text.strip(), "get_help() must return non-empty content"
            assert "<bash>" in help_text, "Help must contain bash example blocks"
            assert "</bash>" in help_text, "Help must close bash example blocks"

    @timeout(15)
    def test_bash_environment_large_heredoc_command(self) -> None:
        """Large heredoc commands must complete without hanging.

        pexpect.send() calls os.write() once, which on a PTY with canonical
        mode can silently return fewer bytes than requested when the command
        exceeds N_TTY_BUF_SIZE (4096 bytes on Linux). This drops everything
        after the buffer fills up — including the heredoc EOF terminator —
        causing bash to hang waiting for it indefinitely.

        Requirements tested:
        1. Heredoc commands larger than 4096 bytes complete successfully
        2. All lines of file content are written (no truncation)
        3. Command returns a response (no hang)
        """
        env = BashEnvironment()
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                # Build a heredoc command larger than 4096 bytes.
                # 100 lines × ~50 bytes each ≈ 5000 bytes total command.
                content_lines = [f"line_{i:03d}: {'x' * 40}" for i in range(100)]
                content = "\n".join(content_lines)
                output_file = f"{tmpdir}/out.txt"

                cmd = f"cat > {output_file} << 'HEREDOC'\n{content}\nHEREDOC"

                # Must complete within timeout (not hang)
                response = env.handle_command(CommandText(cmd))
                assert response.processed is True, "Large heredoc command must succeed"

                # Verify all 100 lines were written (nothing was truncated)
                response = env.handle_command(CommandText(f"wc -l {output_file}"))
                assert "100" in response.output, "All 100 lines must be written to file"

                response = env.handle_command(CommandText(f"head -1 {output_file}"))
                assert "line_000" in response.output, "First line must be correct"

                response = env.handle_command(CommandText(f"tail -1 {output_file}"))
                assert "line_099" in response.output, "Last line must be correct"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_get_help_uses_project_override(self) -> None:
        """Requirement: project_dir/env/bash/help.md must override the built-in help.

        Projects must be able to supply custom bash help tailored to their tooling
        and conventions; the override must appear in both get_help() and get_screen().
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            override_dir = project_dir / "env" / "bash"
            override_dir.mkdir(parents=True)
            (override_dir / "help.md").write_text(
                "Project-specific bash help for this repo.", encoding="utf-8"
            )

            env = BashEnvironment(project_dir=project_dir)

            help_text = env.get_help()
            assert "Project-specific bash help for this repo." in help_text

            screen = env.get_screen()
            assert "Project-specific bash help for this repo." in screen.content

    @timeout(10)
    def test_bash_environment_multiline_command_no_stale_output(self) -> None:
        """Multi-line commands must not leak stale output into subsequent commands.

        Each line sent to bash generates exactly one prompt (PS1 or PS2).
        Consuming one prompt per line prevents stale output from accumulating
        in the pexpect buffer and appearing as the output of a later command.

        Requirements tested:
        1. All lines of a multi-line command execute correctly
        2. Output of a subsequent command is not contaminated by earlier output
        3. Exit code reflects the last line of the multi-line command
        """
        env = BashEnvironment()
        try:
            # Multi-line command: three separate statements
            response = env.handle_command(
                CommandText("echo 'first'\necho 'second'\necho 'third'")
            )
            assert response.processed is True
            assert "first" in response.output
            assert "second" in response.output
            assert "third" in response.output

            # Subsequent command must return its own output, not leftovers
            response = env.handle_command(CommandText("echo 'clean'"))
            assert response.processed is True
            assert "clean" in response.output
            assert "first" not in response.output
            assert "second" not in response.output
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_exec_bash_preserves_prompts(self) -> None:
        """PS1 and PS2 must survive into any exec'd bash (e.g. after nix develop).

        Tools like 'nix develop' replace the current bash process with a new one
        via exec. If PS1 and PS2 are only shell variables (not exported), the new
        bash resets them to defaults. PS1 defaults to 'bash-5.x$' (so pexpect can
        no longer match <<<PROMPT>>>), and PS2 defaults to '> ' (so heredocs hang
        because pexpect is waiting for <<<PROMPT2>>> but the shell emits '> ').

        This is exactly what happened in agent session 9: nix develop exec'd a new
        bash, whose PS2 was '> '. The next heredoc command hung indefinitely.

        Requirements tested:
        1. After exec bash --norc --noprofile, single-line commands still work
           (PS1 was exported → new bash inherits it)
        2. After exec bash --norc --noprofile, heredocs still work
           (PS2 was exported → new bash inherits it, no hang)
        """
        env = BashEnvironment()
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                # exec bash replaces the current process; the new bash must still
                # have our custom PS1 and PS2 (requires them to be exported)
                response = env.handle_command(
                    CommandText("exec bash --norc --noprofile")
                )
                assert (
                    response.processed is True
                ), "exec bash must complete (PS1 exported → new bash matches prompt)"

                # Single-line command must work in the new shell
                response = env.handle_command(CommandText("echo hello_after_exec"))
                assert response.processed is True
                assert "hello_after_exec" in response.output

                # Heredoc must not hang (PS2 must still be <<<PROMPT2>>>)
                outfile = f"{tmpdir}/test.txt"
                response = env.handle_command(
                    CommandText(f"cat > {outfile} << 'EOF'\nhello heredoc\nEOF")
                )
                assert response.processed is True

                # Verify the file was written
                response = env.handle_command(CommandText(f"cat {outfile}"))
                assert "hello heredoc" in response.output
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_heredoc_continuation_state(self) -> None:
        """Incomplete heredoc must report continuation state to the LLM.

        When an agent sends only the opening line of a heredoc (no terminator),
        bash is waiting for more input. The environment must:
        1. Report the continuation state in the response output
        2. Show "waiting for continuation" in the screen state
        3. Accept the remaining lines in the next command and complete normally

        Requirements tested:
        1. Incomplete heredoc → response mentions continuation
        2. Screen shows continuation status
        3. Completing the heredoc in a follow-up command produces correct output
        """
        env = BashEnvironment()
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                outfile = f"{tmpdir}/out.txt"

                # Send only the opening line of a heredoc — bash will wait for more
                response = env.handle_command(CommandText(f"cat > {outfile} << 'EOF'"))
                assert response.processed is True
                assert "continuation" in response.output.lower()

                screen = env.get_screen()
                assert "continuation" in screen.content.lower()

                # Complete the heredoc
                response = env.handle_command(CommandText("hello from heredoc\nEOF"))
                assert response.processed is True
                assert "continuation" not in response.output.lower()

                # Verify the file was written
                response = env.handle_command(CommandText(f"cat {outfile}"))
                assert "hello from heredoc" in response.output
        finally:
            env.shutdown()
