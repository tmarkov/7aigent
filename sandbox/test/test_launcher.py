"""
Tests for the 7aigent-sandbox launcher.

These tests run the built launcher (result/bin/7aigent-sandbox) with
SANDBOX_DRY_RUN=1 and verify the generated kernel.json and config.json
match the requirements in design/sandbox-requirements.md.

Requirements tested:
  S2   — runsc config declares a network namespace
  S2a  — bwrap compatibility path contains the network-namespace probe/warning
  S3   — root is readonly
  S4   — only the minimal runtime Nix store closure is mounted
  S7a  — runsc launcher enables host UDS creation for /sockets IPC
  S8   — transport is ipc
  S9   — kernel.json fields and HMAC key
  S10  — /workspace bind mount is rw
  S10a — /workspace/.7aigent/state is required and read-only
  S11  — nogit sentinel blocks newly appeared .git metadata on restart
  S11a — nogit sentinel lifecycle
  S11b — trusted git metadata is read-only for .git directories, symlinks, and gitfiles
  S17  — cleanup is handled by the resident launcher (covered indirectly by integration tests)
  S21  — launcher CLI interface and exact arity
  S22  — invalid workspace / malformed git metadata fail loudly
  S23  — built launcher contains the expected compatibility-runner hardening
"""

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
BUILT_LAUNCHER = REPO_ROOT / "result" / "bin" / "7aigent-sandbox"
SANDBOX_GIT_ROOT = "/git-metadata"
UUID4_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)


@dataclass
class DryRunOutput:
    result: subprocess.CompletedProcess
    kernel_json_path: Path
    runtime_dir: Path
    kernel_json: dict
    config_json: dict


def get_launcher() -> Path:
    if BUILT_LAUNCHER.exists():
        return BUILT_LAUNCHER
    pytest.skip(
        "Built launcher not found at result/bin/7aigent-sandbox. "
        "Run `nix build .#sandbox` first."
    )


def run_dry_run(workspace: Path, extra_env: dict | None = None) -> DryRunOutput:
    launcher = get_launcher()
    env = {**os.environ, "SANDBOX_DRY_RUN": "1"}
    if extra_env:
        env.update(extra_env)

    result = subprocess.run(
        [str(launcher), str(workspace)],
        capture_output=True,
        text=True,
        env=env,
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

    return DryRunOutput(
        result=result,
        kernel_json_path=kernel_json_path,
        runtime_dir=runtime_dir,
        kernel_json=kernel_json,
        config_json=config_json,
    )


def ensure_state_dir(workspace: Path) -> Path:
    state_dir = workspace / ".7aigent" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir


def runtime_store_paths() -> list[str]:
    share_dir = get_launcher().resolve().parent.parent / "share" / "sandbox"
    return [
        line
        for line in (share_dir / "runtime-store-paths").read_text().splitlines()
        if line
    ]


@pytest.fixture
def workspace(tmp_path):
    """A minimal workspace directory with a .git subdirectory."""
    ensure_state_dir(tmp_path)
    git_dir = tmp_path / ".git"
    git_dir.mkdir()
    (git_dir / "HEAD").write_text("ref: refs/heads/main\n")
    return tmp_path


@pytest.fixture
def gitfile_workspace(tmp_path):
    """A real git worktree whose .git is a gitfile."""
    git = shutil.which("git")
    if git is None:
        pytest.skip("git executable not available")

    repo = tmp_path / "repo"
    subprocess.run([git, "init", str(repo)], check=True, capture_output=True, text=True)
    subprocess.run(
        [git, "config", "user.email", "sandbox@example.com"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        [git, "config", "user.name", "Sandbox Test"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    (repo / "tracked.txt").write_text("hello\n")
    subprocess.run([git, "add", "tracked.txt"], cwd=repo, check=True, capture_output=True, text=True)
    subprocess.run([git, "commit", "-m", "init"], cwd=repo, check=True, capture_output=True, text=True)

    workspace = tmp_path / "worktree"
    subprocess.run(
        [git, "worktree", "add", str(workspace)],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    ensure_state_dir(workspace)

    gitfile_line = (workspace / ".git").read_text().splitlines()[0]
    gitdir_path = gitfile_line.removeprefix("gitdir: ").strip()
    actual_gitdir = Path(gitdir_path)
    if not actual_gitdir.is_absolute():
        actual_gitdir = (workspace / actual_gitdir).resolve()

    commondir_entry = (actual_gitdir / "commondir").read_text().strip()
    actual_common_dir = (actual_gitdir / commondir_entry).resolve()
    relative_gitdir = os.path.relpath(actual_gitdir, actual_common_dir)
    return workspace, actual_common_dir, relative_gitdir


@pytest.fixture
def git_symlink_workspace(tmp_path):
    """A workspace whose .git is a symlink to an external git directory."""
    external_git_dir = tmp_path / "external-git"
    external_git_dir.mkdir()
    (external_git_dir / "HEAD").write_text("ref: refs/heads/main\n")

    workspace = tmp_path / "workspace"
    workspace.mkdir()
    ensure_state_dir(workspace)
    (workspace / ".git").symlink_to(external_git_dir, target_is_directory=True)
    return workspace, external_git_dir.resolve()


@pytest.fixture
def no_git_workspace(tmp_path):
    """A workspace with no git metadata but with the required state directory."""
    ensure_state_dir(tmp_path)
    return tmp_path


@pytest.fixture
def dry_run_output(workspace):
    return run_dry_run(workspace)


# ── S9: connection file shape ────────────────────────────────────────────────


class TestConnectionFile:
    def test_transport_is_ipc(self, dry_run_output):
        """S8: transport must be ipc."""
        assert dry_run_output.kernel_json["transport"] == "ipc"

    def test_ip_is_absolute_sockets_path(self, dry_run_output):
        """S8: ip must be an absolute path under /sockets."""
        assert dry_run_output.kernel_json["ip"].startswith("/")

    def test_signature_scheme(self, dry_run_output):
        """S9: signature scheme must be hmac-sha256."""
        assert dry_run_output.kernel_json["signature_scheme"] == "hmac-sha256"

    def test_key_is_uuid4(self, dry_run_output):
        """S9: HMAC key must be a UUID4."""
        assert UUID4_RE.match(dry_run_output.kernel_json["key"]), (
            f"key {dry_run_output.kernel_json['key']!r} is not a UUID4"
        )

    def test_all_five_ports_present(self, dry_run_output):
        """S8: all five Jupyter channel ports must be present."""
        for port_field in (
            "shell_port",
            "iopub_port",
            "stdin_port",
            "control_port",
            "hb_port",
        ):
            assert port_field in dry_run_output.kernel_json
            assert isinstance(dry_run_output.kernel_json[port_field], int)

    def test_key_is_fresh_each_run(self, workspace):
        """S9: each launcher invocation generates a distinct HMAC key."""
        k1 = run_dry_run(workspace).kernel_json["key"]
        k2 = run_dry_run(workspace).kernel_json["key"]
        assert k1 != k2, "Two runs produced the same HMAC key"


# ── S4, S10, S10a, S11: OCI mount configuration ─────────────────────────────


def _find_mount(mounts, destination):
    """Return the first mount entry with the given destination, or None."""
    return next((m for m in mounts if m["destination"] == destination), None)


def _mount_index(mounts, destination):
    """Return the index of the first mount with the given destination, or -1."""
    for i, mount in enumerate(mounts):
        if mount["destination"] == destination:
            return i
    return -1


class TestOCIConfig:
    def test_nix_store_is_minimal_runtime_closure(self, dry_run_output):
        """S4: mount individual runtime store paths, not the whole host store."""
        mount = _find_mount(dry_run_output.config_json["mounts"], "/nix/store")
        assert mount is None, "/nix/store root must not be mounted wholesale"

        store_mounts = [
            m for m in dry_run_output.config_json["mounts"]
            if m["destination"].startswith("/nix/store/")
        ]
        assert store_mounts, "expected individual runtime store path mounts"

    def test_runtime_store_paths_include_built_sandbox_output(self):
        """S4: the runtime closure must include the built sandbox output itself."""
        sandbox_out = str(get_launcher().resolve().parent.parent)
        assert sandbox_out in runtime_store_paths()

    def test_host_git_store_path_is_not_exposed(self):
        """S4/S12: unrelated host store tooling should not be mounted into the sandbox."""
        git_path = shutil.which("git")
        if git_path is None or not git_path.startswith("/nix/store/"):
            pytest.skip("host git is not a Nix store path in this environment")

        git_store_path = str(Path(git_path).parents[1])
        assert git_store_path not in runtime_store_paths()

    def test_workspace_is_readwrite(self, dry_run_output, workspace):
        """S10: /workspace must be a bind mount of the workspace path."""
        mount = _find_mount(dry_run_output.config_json["mounts"], "/workspace")
        assert mount is not None, "/workspace mount missing"
        assert mount["source"] == str(workspace.resolve())
        assert "ro" not in mount["options"], "/workspace must be rw, not ro"

    def test_state_dir_is_readonly(self, dry_run_output, workspace):
        """S10a: /workspace/.7aigent/state must be a read-only bind mount."""
        state_dir = (workspace / ".7aigent" / "state").resolve()
        mount = _find_mount(dry_run_output.config_json["mounts"], "/workspace/.7aigent/state")
        assert mount is not None, "/workspace/.7aigent/state mount missing"
        assert mount["source"] == str(state_dir)
        assert "ro" in mount["options"], "/workspace/.7aigent/state must be read-only"

    def test_state_mount_after_workspace_mount(self, dry_run_output):
        """S10a: the state overlay must come after /workspace in mount order."""
        mounts = dry_run_output.config_json["mounts"]
        ws_idx = _mount_index(mounts, "/workspace")
        state_idx = _mount_index(mounts, "/workspace/.7aigent/state")
        assert ws_idx != -1 and state_idx != -1
        assert state_idx > ws_idx

    def test_git_directory_is_readonly(self, dry_run_output, workspace):
        """S11b: .git directories are over-mounted read-only."""
        mount = _find_mount(dry_run_output.config_json["mounts"], "/workspace/.git")
        assert mount is not None, "/workspace/.git mount missing"
        assert mount["source"] == str((workspace / ".git").resolve())
        assert "ro" in mount["options"], "/workspace/.git must be read-only"

    def test_git_mount_after_workspace_mount(self, dry_run_output):
        """S11b: the git overlay must come after /workspace in mount order."""
        mounts = dry_run_output.config_json["mounts"]
        ws_idx = _mount_index(mounts, "/workspace")
        git_idx = _mount_index(mounts, "/workspace/.git")
        assert ws_idx != -1 and git_idx != -1
        assert git_idx > ws_idx, (
            "/workspace/.git mount must come after /workspace mount"
        )

    def test_gitfile_workspace_gets_overlay_and_common_git_mount(self, gitfile_workspace):
        """S11b: gitfiles use a readonly overlay and preserve common-dir layout."""
        workspace, actual_common_dir, relative_gitdir = gitfile_workspace
        dry_run = run_dry_run(workspace)
        mounts = dry_run.config_json["mounts"]

        gitfile_mount = _find_mount(mounts, "/workspace/.git")
        common_mount = _find_mount(mounts, SANDBOX_GIT_ROOT)
        assert gitfile_mount is not None, "/workspace/.git gitfile overlay missing"
        assert common_mount is not None, f"{SANDBOX_GIT_ROOT} mount missing for gitfile workspace"
        assert common_mount["source"] == str(actual_common_dir)
        assert gitfile_mount["source"] != str((workspace / ".git").resolve())

        overlay_path = Path(gitfile_mount["source"])
        expected_gitdir = SANDBOX_GIT_ROOT
        if relative_gitdir != ".":
            expected_gitdir = f"{SANDBOX_GIT_ROOT}/{relative_gitdir}"
        assert overlay_path.read_text() == f"gitdir: {expected_gitdir}\n"

    def test_git_symlink_workspace_mounts_resolved_target_readonly(self, git_symlink_workspace):
        """S11b: .git symlinks are over-mounted from their resolved target."""
        workspace, actual_gitdir = git_symlink_workspace
        dry_run = run_dry_run(workspace)
        mount = _find_mount(dry_run.config_json["mounts"], "/workspace/.git")
        assert mount is not None
        assert mount["source"] == str(actual_gitdir)
        assert "ro" in mount["options"]

    def test_sockets_dir_is_readwrite(self, dry_run_output):
        """S7: /sockets must be a rw bind mount."""
        mount = _find_mount(dry_run_output.config_json["mounts"], "/sockets")
        assert mount is not None, "/sockets mount missing"
        assert "ro" not in mount["options"], "/sockets must be rw"

    def test_root_is_readonly(self, dry_run_output):
        """S3: OCI root must be readonly."""
        assert dry_run_output.config_json["root"]["readonly"] is True

    def test_network_namespace_present(self, dry_run_output):
        """S2/S5: the runsc OCI config must include a network namespace."""
        namespaces = dry_run_output.config_json["linux"]["namespaces"]
        ns_types = [ns["type"] for ns in namespaces]
        assert "network" in ns_types, (
            "network namespace missing from linux.namespaces"
        )


class TestLauncherHardening:
    def test_nogit_workspace_creates_sentinel(self, no_git_workspace):
        """S11/S11a: a no-git startup creates the readonly-state sentinel."""
        run_dry_run(no_git_workspace)
        assert (no_git_workspace / ".7aigent" / "state" / "nogit").exists()

    def test_stale_nogit_without_git_still_allows_start(self, no_git_workspace):
        """S11a: a stale nogit marker is harmless if .git is still absent."""
        nogit = no_git_workspace / ".7aigent" / "state" / "nogit"
        nogit.write_text("stale\n")
        run_dry_run(no_git_workspace)
        assert nogit.exists()

    def test_nogit_blocks_new_git_on_restart(self, no_git_workspace):
        """S11: if nogit exists and .git appears later, startup must fail closed."""
        run_dry_run(no_git_workspace)
        git_dir = no_git_workspace / ".git"
        git_dir.mkdir()
        (git_dir / "HEAD").write_text("ref: refs/heads/main\n")

        result = subprocess.run(
            [str(get_launcher()), str(no_git_workspace)],
            capture_output=True,
            text=True,
            env={**os.environ, "SANDBOX_DRY_RUN": "1"},
        )
        assert result.returncode != 0
        assert "nogit" in result.stderr

    def test_workspace_paths_with_special_characters_still_generate_valid_json(
        self, tmp_path
    ):
        """Workspace paths must be serialized safely into config.json."""
        for name in ('ws"quote', "ws|pipe", "ws&and", "ws space"):
            workspace = tmp_path / name
            workspace.mkdir()
            ensure_state_dir(workspace)
            (workspace / ".git").mkdir()
            dry_run = run_dry_run(workspace)
            mount = _find_mount(dry_run.config_json["mounts"], "/workspace")
            assert mount["source"] == str(workspace.resolve())

    def test_missing_state_dir_fails(self, tmp_path):
        """S10a/S22: the launcher should reject workspaces without .7aigent/state."""
        workspace = tmp_path / "workspace"
        workspace.mkdir()
        (workspace / ".git").mkdir()

        result = subprocess.run(
            [str(get_launcher()), str(workspace)],
            capture_output=True,
            text=True,
            env={**os.environ, "SANDBOX_DRY_RUN": "1"},
        )
        assert result.returncode != 0
        assert ".7aigent/state" in result.stderr

    def test_symlinked_state_dir_fails(self, tmp_path):
        """S10a/S22: the readonly state directory itself must not be a symlink."""
        workspace = tmp_path / "workspace"
        workspace.mkdir()
        (workspace / ".git").mkdir()
        (workspace / ".7aigent").mkdir()
        external_state = tmp_path / "external-state"
        external_state.mkdir()
        (workspace / ".7aigent" / "state").symlink_to(external_state, target_is_directory=True)

        result = subprocess.run(
            [str(get_launcher()), str(workspace)],
            capture_output=True,
            text=True,
            env={**os.environ, "SANDBOX_DRY_RUN": "1"},
        )
        assert result.returncode != 0
        assert ".7aigent/state" in result.stderr

    def test_malformed_gitfile_fails(self, tmp_path):
        """S22: malformed .git files should fail loudly before launch."""
        workspace = tmp_path / "workspace"
        workspace.mkdir()
        ensure_state_dir(workspace)
        (workspace / ".git").write_text("not-a-gitdir\n")

        result = subprocess.run(
            [str(get_launcher()), str(workspace)],
            capture_output=True,
            text=True,
            env={**os.environ, "SANDBOX_DRY_RUN": "1"},
        )
        assert result.returncode != 0
        assert "gitdir" in result.stderr

    def test_invalid_runner_fails(self, workspace):
        result = subprocess.run(
            [str(get_launcher()), str(workspace)],
            capture_output=True,
            text=True,
            env={**os.environ, "SANDBOX_DRY_RUN": "1", "SANDBOX_RUNNER": "bogus"},
        )
        assert result.returncode != 0
        assert "unsupported sandbox runner" in result.stderr

    def test_bwrap_script_contains_expected_hardening(self):
        """S2a/S23: the built launcher contains the intended bwrap controls."""
        launcher_text = get_launcher().read_text()
        for token in (
            "--clearenv",
            "--unshare-pid",
            "--unshare-ipc",
            "--unshare-uts",
            "--unshare-net",
            "bubblewrap network namespace unavailable",
            "--die-with-parent",
        ):
            assert token in launcher_text

    def test_runsc_launcher_enables_host_uds_create(self):
        """S7a: the runsc path enables host UDS creation for /sockets IPC."""
        launcher_text = get_launcher().read_text()
        assert "--host-uds=create" in launcher_text

    def test_bwrap_launcher_exits_on_sigint(self, workspace):
        """S16/S17: the resident launcher should stop and clean up on Ctrl+C."""
        proc = subprocess.Popen(
            [str(get_launcher()), str(workspace)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "SANDBOX_RUNNER": "bwrap"},
        )

        kernel_json_path = Path(proc.stdout.readline().strip())
        if not kernel_json_path.exists():
            stderr = proc.stderr.read().strip()
            pytest.skip(
                "bwrap launcher could not start in this environment: "
                f"{stderr or 'no kernel.json produced'}"
            )

        runtime_dir = kernel_json_path.parent.parent
        time.sleep(1.0)
        proc.send_signal(signal.SIGINT)

        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
            pytest.fail("launcher did not exit after SIGINT")

        assert not runtime_dir.exists(), f"runtime directory leaked: {runtime_dir}"

    def test_bwrap_cleans_session_nogit_on_sigint(self, no_git_workspace):
        """S11a/S16/S17: a normal no-git session should clean up its nogit marker."""
        proc = subprocess.Popen(
            [str(get_launcher()), str(no_git_workspace)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "SANDBOX_RUNNER": "bwrap"},
        )

        kernel_json_path = Path(proc.stdout.readline().strip())
        if not kernel_json_path.exists():
            stderr = proc.stderr.read().strip()
            pytest.skip(
                "bwrap launcher could not start in this environment: "
                f"{stderr or 'no kernel.json produced'}"
            )

        time.sleep(1.0)
        proc.send_signal(signal.SIGINT)

        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
            pytest.fail("launcher did not exit after SIGINT")

        assert not (no_git_workspace / ".7aigent" / "state" / "nogit").exists()


# ── S21, S22: launcher CLI ───────────────────────────────────────────────────


class TestLauncherCLI:
    def test_prints_kernel_json_path_to_stdout(self, workspace):
        """S15/S21: launcher must print the kernel.json path to stdout."""
        dry_run = run_dry_run(workspace)
        path = dry_run.kernel_json_path
        assert path.name == "kernel.json"
        assert path.exists()

    def test_missing_workspace_arg_fails(self):
        """S21: no workspace argument → non-zero exit."""
        result = subprocess.run(
            [str(get_launcher())],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0
        assert result.stderr.strip() != ""

    def test_extra_workspace_arg_fails(self, workspace):
        """S21: extra positional arguments are rejected."""
        result = subprocess.run(
            [str(get_launcher()), str(workspace), "extra"],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0
        assert "Usage:" in result.stderr

    def test_nonexistent_workspace_fails(self, tmp_path):
        """S22: non-existent workspace → non-zero exit with stderr message."""
        result = subprocess.run(
            [str(get_launcher()), str(tmp_path / "does_not_exist")],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0
        assert result.stderr.strip() != ""
