"""
Verify that http.bash only uses the declared external dependencies.

Runs the script with PATH restricted to a temp directory containing only
symlinks to the allowed binaries.  If the script invokes anything else it
gets "command not found" and fails, making the test self-enforcing.

This also serves as positive proof that each dependency is actually needed
(e.g. openssl is required for HTTPS but not for plain HTTP).
"""
from __future__ import annotations

import os
import shutil
import subprocess

import pytest


def _restricted_env(tmp_path, *allowed_names: str) -> dict:
    """Return an env dict with PATH pointing to a dir containing only the
    named binaries (symlinked from their real locations)."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in allowed_names:
        real = shutil.which(name)
        assert real is not None, f"{name} not found on host PATH"
        (bin_dir / name).symlink_to(real)
    return {**os.environ, "PATH": str(bin_dir)}


def _run(http_bash, env, *args, timeout=10):
    return subprocess.run(
        ["bash", http_bash, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
    )


# ---------------------------------------------------------------------------
# Plain HTTP: only cat should be needed at runtime
# ---------------------------------------------------------------------------

def test_plain_http_works_with_only_cat(http_bash, http_server, tmp_path):
    env = _restricted_env(tmp_path, "bash", "cat")
    r = _run(http_bash, env, f"{http_server.url}/get")
    assert r.returncode == 0
    assert "hello world" in r.stdout


def test_plain_http_post_works_with_only_cat(http_bash, http_server, tmp_path):
    env = _restricted_env(tmp_path, "bash", "cat")
    r = _run(http_bash, env, "-d", "x=1", f"{http_server.url}/echo-body")
    assert r.returncode == 0
    assert r.stdout == "x=1"


# ---------------------------------------------------------------------------
# HTTPS: requires openssl (and cat for body)
# ---------------------------------------------------------------------------

def test_https_works_with_openssl_and_cat(http_bash, https_server, tmp_path):
    env = _restricted_env(tmp_path, "bash", "openssl", "cat")
    r = _run(http_bash, env, f"{https_server.url}/get")
    assert r.returncode == 0
    assert "hello world" in r.stdout


def test_https_fails_without_openssl(http_bash, https_server, tmp_path):
    """HTTPS should fail with a clear error when openssl is absent."""
    env = _restricted_env(tmp_path, "bash", "cat")
    r = _run(http_bash, env, f"{https_server.url}/get")
    assert r.returncode != 0
    assert "openssl" in r.stderr


# ---------------------------------------------------------------------------
# Basic auth: requires openssl for base64 encoding
# ---------------------------------------------------------------------------

def test_basic_auth_works_with_openssl(http_bash, http_server, tmp_path):
    env = _restricted_env(tmp_path, "bash", "openssl", "cat")
    r = _run(http_bash, env, "-u", "user:pass", f"{http_server.url}/get")
    assert r.returncode == 0


def test_basic_auth_fails_without_openssl(http_bash, http_server, tmp_path):
    """Basic auth base64 encoding should fail clearly when openssl is absent."""
    env = _restricted_env(tmp_path, "bash", "cat")
    r = _run(http_bash, env, "-u", "user:pass", f"{http_server.url}/get")
    assert r.returncode != 0
    assert "openssl" in r.stderr
