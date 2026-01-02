#!/usr/bin/env python3
"""TUI frontend for the orchestrator.

This provides an interactive terminal interface for manually using the orchestrator.
Features:
- Split screen: large output browser (top) + command input (bottom)
- Browse output using less-style controls
- Switch environments with /bash, /python, /editor, etc.
- Ctrl-W to switch focus between browser and input
"""

import json
import shutil
import subprocess
import sys
import traceback
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, ScrollableContainer
from textual.widgets import Footer, Header, Input, Static


class OrchestratorTUI(App):
    """TUI frontend for orchestrator."""

    CSS = """
    Screen {
        layout: vertical;
    }

    #output-container {
        height: 1fr;
        border: solid green;
    }

    #output-log {
        height: 100%;
        scrollbar-gutter: stable;
    }

    #input-container {
        height: auto;
        border: solid blue;
        padding: 0 1;
    }

    #command-input {
        width: 100%;
    }

    .focused {
        border: solid yellow;
    }
    """

    BINDINGS = [
        Binding("ctrl+w", "switch_focus", "Switch Focus", show=True, priority=True),
        Binding("ctrl+c", "quit", "Quit", show=True),
    ]

    def __init__(self):
        """Initialize TUI."""
        super().__init__()
        self.current_env = "bash"
        self.orchestrator_proc = None
        self.output_focused = False
        self.output_lines = []

    def write_output(self, text: str) -> None:
        """Append text to output log."""
        self.output_lines.append(text)
        output_log = self.query_one("#output-log", Static)
        output_log.update("\n".join(self.output_lines))

    def compose(self) -> ComposeResult:
        """Create UI widgets."""
        yield Header()

        # Output browser (large, top)
        with ScrollableContainer(id="output-container", can_focus=True):
            yield Static("", id="output-log")

        # Command input (small, bottom)
        with Container(id="input-container"):
            yield Input(
                placeholder=f"[{self.current_env}]> Enter command (or /env to switch)",
                id="command-input",
            )

        yield Footer()

    def on_mount(self) -> None:
        """Handle app mount - start orchestrator."""
        self.title = "Orchestrator TUI"
        self.sub_title = f"Environment: {self.current_env}"

        # Start orchestrator subprocess
        project_dir = Path.cwd()
        env_vars = {**dict(subprocess.os.environ), "PROJECT_DIR": str(project_dir)}

        # Try to use the orchestrator command directly, fall back to module
        orchestrator_cmd = shutil.which("orchestrator")
        if orchestrator_cmd:
            cmd = [orchestrator_cmd]
        else:
            cmd = [sys.executable, "-m", "orchestrator"]

        self.orchestrator_proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # Line buffered
            env=env_vars,
        )

        # Focus input initially
        self.query_one("#command-input", Input).focus()

        # Show welcome message
        self.write_output("[bold green]Orchestrator TUI started![/bold green]")
        self.write_output(f"[yellow]Current environment: {self.current_env}[/yellow]")
        self.write_output("[dim]Commands:[/dim]")
        self.write_output(
            "[dim]  /bash, /python, /editor, /timer - switch environment[/dim]"
        )
        self.write_output("[dim]  Ctrl-W - switch focus[/dim]")
        self.write_output("[dim]  Ctrl-C - quit[/dim]")
        self.write_output("")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle command submission."""
        command = event.value.strip()
        if not command:
            return

        input_widget = self.query_one("#command-input", Input)

        # Clear input
        input_widget.value = ""

        # Handle environment switch commands
        if command.startswith("/"):
            env_name = command[1:].lower()
            self.current_env = env_name
            self.sub_title = f"Environment: {self.current_env}"
            input_widget.placeholder = (
                f"[{self.current_env}]> Enter command (or /env to switch)"
            )
            self.write_output(
                f"[yellow]→ Switched to environment: {self.current_env}[/yellow]"
            )
            self.write_output("")
            return

        # Show command being executed
        self.write_output(f"[cyan][{self.current_env}]>[/cyan] {command}")

        # Send command to orchestrator
        try:
            message = {"env": self.current_env, "command": command}
            json_line = json.dumps(message) + "\n"
            self.orchestrator_proc.stdin.write(json_line)
            self.orchestrator_proc.stdin.flush()

            # Read response
            response_line = self.orchestrator_proc.stdout.readline()
            if not response_line:
                self.write_output(
                    "[bold red]Error: No response from orchestrator[/bold red]"
                )
                return

            response = json.loads(response_line)

            # Handle error response
            if response.get("type") == "error":
                self.write_output(
                    f"[bold red]Error: {response.get('message')}[/bold red]"
                )
                self.write_output("")
                return

            # Show command response
            cmd_response = response.get("response", {})
            success = cmd_response.get("success", False)
            output = cmd_response.get("output", "")

            if success:
                self.write_output("[green]✓ Success[/green]")
            else:
                self.write_output("[red]✗ Failed[/red]")

            if output:
                # Show output with proper formatting
                for line in output.split("\n"):
                    self.write_output(f"  {line}")

            # Show screen sections
            screen = response.get("screen", {})
            if screen:
                self.write_output("")
                self.write_output("[bold]─── Screen ───[/bold]")
                for env_name, section in screen.items():
                    content = section.get("content", "")
                    if content and content.strip():
                        self.write_output(f"[bold yellow]{env_name}:[/bold yellow]")
                        for line in content.split("\n"):
                            self.write_output(f"  {line}")
                        self.write_output("")

        except BrokenPipeError:
            self.write_output("[bold red]Error: Orchestrator process died[/bold red]")
            # Try to read stderr to see what happened
            if self.orchestrator_proc.stderr:
                stderr_output = self.orchestrator_proc.stderr.read()
                if stderr_output:
                    self.write_output("[red]Orchestrator stderr:[/red]")
                    for line in stderr_output.split("\n"):
                        if line.strip():
                            self.write_output(f"  {line}")
        except Exception as e:
            self.write_output(f"[bold red]Error: {e}[/bold red]")
            self.write_output(f"[dim]{traceback.format_exc()}[/dim]")

        self.write_output("")

    def action_switch_focus(self) -> None:
        """Switch focus between output browser and command input."""
        output_container = self.query_one("#output-container", ScrollableContainer)
        input_container = self.query_one("#input-container")
        input_widget = self.query_one("#command-input", Input)

        if self.output_focused:
            # Switch to input
            self.output_focused = False
            output_container.remove_class("focused")
            input_container.add_class("focused")
            input_widget.focus()
        else:
            # Switch to output browser
            self.output_focused = True
            input_container.remove_class("focused")
            output_container.add_class("focused")
            output_container.focus()

    def on_unmount(self) -> None:
        """Handle app unmount - shutdown orchestrator."""
        if self.orchestrator_proc:
            try:
                # Send EOF to orchestrator
                self.orchestrator_proc.stdin.close()
                self.orchestrator_proc.wait(timeout=5)
            except Exception:
                self.orchestrator_proc.kill()
                self.orchestrator_proc.wait()


def main():
    """Run the TUI app."""
    app = OrchestratorTUI()
    app.run()


if __name__ == "__main__":
    main()
