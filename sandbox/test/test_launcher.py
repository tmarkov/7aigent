"""
Tests for the 7aigent-sandbox launcher.

These tests run the built launcher (result/bin/7aigent-sandbox) with
SANDBOX_DRY_RUN=1 and verify the generated kernel.json and config.json
match the requirements in design/sandbox-requirements.md.

Requirements tested:
  S2  — network namespace present (air-gap)
  S3  — root is readonly
  S4  — /nix/store is ro
  S8  — transport is ipc
  S9  — kernel.json fields and HMAC key
  S10 — /workspace bind mount is rw
  S11 — /workspace/.git overlay is ro and comes after /workspace
  S21 — launcher CLI interface
  S22 — invalid workspace → non-zero exit
"""

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
BUILT_LAUNCHER = REPO_ROOT / "result" / "bin" / "7aigent-sandbox"
UUID4_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)


def get_launcher() -> Path:
    if BUILT_LAUNCHER.exists():
        return BUILT_LAUNCHER
    pytest.skip(
        "Built launcher not found at result/bin/7aigent-sandbox. "
        "Run `nix build .#sandbox` first."
    )


@pytest.fixture
def workspace(tmp_path):
    """A minimal workspace directory with a .git subdirectory."""
    git_dir = tmp_path / ".git"
    git_dir.mkdir()
    (git_dir / "HEAD").write_text("ref: refs/heads/main\n")
    return tmp_path


@pytest.fixture
def dry_run_output(workspace):
    """Run the launcher in dry-run mode; return (kernel_json_path, config_json)."""
    launcher = get_launcher()
    result = subprocess.run(
        [str(launcher), str(workspace)],
        capture_output=True,
        text=True,
        env={**os.environ, "SANDBOX_DRY_RUN": "1"},
    )
    assert result.returncode == 0, f"Launcher failed:\n{result.stderr}"
    kernel_json_path = Path(result.stdout.strip())
    assert kernel_json_path.exists(), f"kernel.json not found at {kernel_json_path}"

    runtime_dir = kernel_json_path.parent.parent
    config_json_path = runtime_dir / "bundle" / "config.json"
    assert config_json_path.exists(), f"config.json not found at {config_json_path}"

    with kernel_json_path.open() as f:
        kernel_json = json.load(f)
    with config_json_path.open() as f:
        config_json = json.load(f)

    return kernel_json, config_json


# ── S9: connection file shape ────────────────────────────────────────────────

class TestConnectionFile:
    def test_transport_is_ipc(self, dry_run_output):
        """S8: transport must be ipc."""
        kernel_json, _ = dry_run_output
        assert kernel_json["transport"] == "ipc"

    def test_ip_is_absolute_sockets_path(self, dry_run_output):
        """S8: ip must be an absolute path under /sockets."""
        kernel_json, _ = dry_run_output
        assert kernel_json["ip"].startswith("/")

    def test_signature_scheme(self, dry_run_output):
        """S9: signature scheme must be hmac-sha256."""
        kernel_json, _ = dry_run_output
        assert kernel_json["signature_scheme"] == "hmac-sha256"

    def test_key_is_uuid4(self, dry_run_output):
        """S9: HMAC key must be a UUID4."""
        kernel_json, _ = dry_run_output
        assert UUID4_RE.match(kernel_json["key"]), (
            f"key {kernel_json['key']!r} is not a UUID4"
        )

    def test_all_five_ports_present(self, dry_run_output):
        """S8: all five Jupyter channel ports must be present."""
        kernel_json, _ = dry_run_output
        for port_field in ("shell_port", "iopub_port", "stdin_port",
                           "control_port", "hb_port"):
            assert port_field in kernel_json, f"Missing field: {port_field}"
            assert isinstance(kernel_json[port_field], int)

    def test_key_is_fresh_each_run(self, workspace):
        """S9: each launcher invocation generates a distinct HMAC key."""
        launcher = get_launcher()
        env = {**os.environ, "SANDBOX_DRY_RUN": "1"}
        r1 = subprocess.run([str(launcher), str(workspace)],
                            capture_output=True, text=True, env=env)
        r2 = subprocess.run([str(launcher), str(workspace)],
                            capture_output=True, text=True, env=env)
        k1 = json.loads(Path(r1.stdout.strip()).read_text())["key"]
        k2 = json.loads(Path(r2.stdout.strip()).read_text())["key"]
        assert k1 != k2, "Two runs produced the same HMAC key"


# ── S4, S10, S11: OCI mount configuration ────────────────────────────────────

def _find_mount(mounts, destination):
    """Return the first mount entry with the given destination, or None."""
    return next((m for m in mounts if m["destination"] == destination), None)


def _mount_index(mounts, destination):
    """Return the index of the first mount with the given destination, or -1."""
    for i, m in enumerate(mounts):
        if m["destination"] == destination:
            return i
    return -1


class TestOCIConfig:
    def test_nix_store_is_readonly(self, dry_run_output):
        """S4: /nix/store must be a ro bind mount."""
        _, config = dry_run_output
        mount = _find_mount(config["mounts"], "/nix/store")
        assert mount is not None, "/nix/store mount missing"
        assert "ro" in mount["options"], "/nix/store mount is not read-only"

    def test_workspace_is_readwrite(self, dry_run_output, workspace):
        """S10: /workspace must be a bind mount of the workspace path."""
        _, config = dry_run_output
        mount = _find_mount(config["mounts"], "/workspace")
        assert mount is not None, "/workspace mount missing"
        assert mount["source"] == str(workspace)
        assert "ro" not in mount["options"], "/workspace must be rw, not ro"

    def test_git_is_readonly(self, dry_run_output, workspace):
        """S11: /workspace/.git must be a ro bind mount of <workspace>/.git."""
        _, config = dry_run_output
        mount = _find_mount(config["mounts"], "/workspace/.git")
        assert mount is not None, "/workspace/.git mount missing"
        assert mount["source"] == str(workspace / ".git")
        assert "ro" in mount["options"], "/workspace/.git must be read-only"

    def test_git_mount_after_workspace_mount(self, dry_run_output):
        """S11: /workspace/.git overlay must come after /workspace in mount order."""
        _, config = dry_run_output
        ws_idx = _mount_index(config["mounts"], "/workspace")
        git_idx = _mount_index(config["mounts"], "/workspace/.git")
        assert ws_idx != -1 and git_idx != -1
        assert git_idx > ws_idx, (
            "/workspace/.git mount must come after /workspace mount"
        )

    def test_sockets_dir_is_readwrite(self, dry_run_output):
        """S7: /sockets must be a rw bind mount."""
        _, config = dry_run_output
        mount = _find_mount(config["mounts"], "/sockets")
        assert mount is not None, "/sockets mount missing"
        assert "ro" not in mount["options"], "/sockets must be rw"

    def test_root_is_readonly(self, dry_run_output):
        """S3: OCI root must be readonly."""
        _, config = dry_run_output
        assert config["root"]["readonly"] is True

    def test_network_namespace_present(self, dry_run_output):
        """S2/S5: a network namespace must be declared to isolate the container."""
        _, config = dry_run_output
        namespaces = config["linux"]["namespaces"]
        ns_types = [ns["type"] for ns in namespaces]
        assert "network" in ns_types, (
            "network namespace missing from linux.namespaces"
        )


# ── S21, S22: launcher CLI ────────────────────────────────────────────────────

class TestLauncherCLI:
    def test_prints_kernel_json_path_to_stdout(self, workspace):
        """S15/S21: launcher must print the kernel.json path to stdout."""
        launcher = get_launcher()
        result = subprocess.run(
            [str(launcher), str(workspace)],
            capture_output=True, text=True,
            env={**os.environ, "SANDBOX_DRY_RUN": "1"},
        )
        assert result.returncode == 0
        path = Path(result.stdout.strip())
        assert path.name == "kernel.json"
        assert path.exists()

    def test_missing_workspace_arg_fails(self):
        """S21: no workspace argument → non-zero exit."""
        launcher = get_launcher()
        result = subprocess.run(
            [str(launcher)], capture_output=True, text=True,
        )
        assert result.returncode != 0
        assert result.stderr.strip() != ""

    def test_nonexistent_workspace_fails(self, tmp_path):
        """S22: non-existent workspace → non-zero exit with stderr message."""
        launcher = get_launcher()
        result = subprocess.run(
            [str(launcher), str(tmp_path / "does_not_exist")],
            capture_output=True, text=True,
        )
        assert result.returncode != 0
        assert result.stderr.strip() != ""
