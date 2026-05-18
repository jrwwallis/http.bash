"""
Zsh compatibility tests for http.bash.

Runs a representative cross-section of the test suite under zsh to confirm
parity with the bash path. Automatically skipped if zsh is not on PATH.
"""
from __future__ import annotations

import shutil
import subprocess

import pytest


# Skip the entire module if zsh is unavailable.
pytestmark = pytest.mark.skipif(
    shutil.which("zsh") is None,
    reason="zsh not found in PATH",
)


def _zsh_coproc_fds_ok() -> bool:
    """Return True if zsh exposes COPROC FD numbers after starting a coproc.

    Some non-standard zsh builds (e.g. Zoox-modified 5.9) do not populate the
    $COPROC array, making the openssl s_client coproc path unusable.  The HTTPS
    tests are skipped automatically in those environments.
    """
    if shutil.which("zsh") is None:
        return False
    # Use a coproc that stays alive long enough to probe $COPROC, then kill it.
    r = subprocess.run(
        ["zsh", "-c", 'coproc { sleep 10; }; rc=1; [[ -n "${COPROC[1]}" ]] && rc=0; kill $! 2>/dev/null; exit $rc'],
        capture_output=True,
        timeout=5,
    )
    return r.returncode == 0


# ---------------------------------------------------------------------------
# Basic HTTP GET
# ---------------------------------------------------------------------------

def test_zsh_basic_get(zsh_run, http_server):
    r = zsh_run(f"{http_server.url}/get")
    assert r.returncode == 0
    assert "hello world" in r.stdout


def test_zsh_get_empty_body(zsh_run, http_server):
    r = zsh_run(f"{http_server.url}/empty")
    assert r.returncode == 0
    assert r.stdout == ""


# ---------------------------------------------------------------------------
# HTTP errors
# ---------------------------------------------------------------------------

def test_zsh_404_fails(zsh_run, http_server):
    r = zsh_run(f"{http_server.url}/notfound")
    assert r.returncode != 0
    assert "404" in r.stderr


def test_zsh_500_fails(zsh_run, http_server):
    r = zsh_run(f"{http_server.url}/servererror")
    assert r.returncode != 0
    assert "500" in r.stderr


# ---------------------------------------------------------------------------
# POST / request body
# ---------------------------------------------------------------------------

def test_zsh_post_data(zsh_run, http_server):
    r = zsh_run("-d", "foo=bar", f"{http_server.url}/echo-body")
    assert r.returncode == 0
    assert r.stdout == "foo=bar"


def test_zsh_post_explicit_method(zsh_run, http_server):
    r = zsh_run("-X", "POST", f"{http_server.url}/echo-method")
    assert r.returncode == 0
    assert r.stdout.strip() == "POST"


# ---------------------------------------------------------------------------
# HEAD request
# ---------------------------------------------------------------------------

def test_zsh_head_request(zsh_run, http_server):
    r = zsh_run("-I", f"{http_server.url}/get")
    assert r.returncode == 0
    assert "HTTP/1.0 200" in r.stdout
    assert "Content-Length" in r.stdout
    # Body must be absent.
    assert "hello world" not in r.stdout


def test_zsh_head_with_data_ignores_body(zsh_run, http_server):
    """HEAD + -d must not send a request body (Content-Length absent from request)."""
    r = zsh_run("-I", "-d", "x=1", "-v", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    # Check only outgoing request headers ("> " prefix), not response headers ("< ").
    sent = [l for l in r.stderr.splitlines() if l.startswith("> ")]
    sent_text = "\n".join(sent)
    assert "Content-Length" not in sent_text
    assert "Content-Type" not in sent_text


# ---------------------------------------------------------------------------
# Custom headers and User-Agent
# ---------------------------------------------------------------------------

def test_zsh_custom_header(zsh_run, http_server):
    r = zsh_run("-H", "X-Test-Foo: bar", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    assert "X-Test-Foo: bar" in r.stdout


def test_zsh_custom_user_agent(zsh_run, http_server):
    r = zsh_run("-A", "my-agent/2.0", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    assert "my-agent/2.0" in r.stdout


# ---------------------------------------------------------------------------
# Basic auth
# ---------------------------------------------------------------------------

def test_zsh_basic_auth_header_sent(zsh_run, http_server):
    r = zsh_run("-u", "user:secret", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    assert "Authorization" in r.stdout


# ---------------------------------------------------------------------------
# Redirects
# ---------------------------------------------------------------------------

def test_zsh_redirect_not_followed_by_default(zsh_run, http_server):
    r = zsh_run(f"{http_server.url}/redirect301")
    assert r.returncode != 0
    assert "301" in r.stderr


def test_zsh_follow_redirect_301(zsh_run, http_server):
    r = zsh_run("-L", f"{http_server.url}/redirect301")
    assert r.returncode == 0
    assert "hello world" in r.stdout


def test_zsh_follow_redirect_302(zsh_run, http_server):
    r = zsh_run("-L", f"{http_server.url}/redirect302")
    assert r.returncode == 0
    assert "hello world" in r.stdout


def test_zsh_redirect_301_drops_body(zsh_run, http_server):
    """POST body must be dropped on 301 (downgrade to GET)."""
    r = zsh_run("-L", "-d", "key=val", f"{http_server.url}/redirect301-to-echo")
    assert r.returncode == 0
    # If the body were forwarded, the echoed headers would include Content-Length.
    assert "Content-Length" not in r.stdout


def test_zsh_redirect_307_preserves_method(zsh_run, http_server):
    r = zsh_run("-L", "-X", "POST", f"{http_server.url}/redirect307")
    assert r.returncode == 0
    assert "hello world" in r.stdout


def test_zsh_max_redirs_exceeded(zsh_run, http_server):
    r = zsh_run("-L", "--max-redirs", "1", f"{http_server.url}/chain1")
    assert r.returncode != 0
    assert "Too many redirects" in r.stderr


# ---------------------------------------------------------------------------
# HTTPS (requires openssl)
# ---------------------------------------------------------------------------

_SKIP_ZSH_HTTPS = pytest.mark.skipif(
    shutil.which("openssl") is None or not _zsh_coproc_fds_ok(),
    reason="openssl not available or zsh coproc FDs not exposed (non-standard build)",
)


@_SKIP_ZSH_HTTPS
def test_zsh_https_get(zsh_run, https_server):
    """HTTPS GET via zsh (openssl s_client coproc path)."""
    r = zsh_run(f"{https_server.url}/get")
    assert r.returncode == 0
    assert r.stdout == "hello world\n"


@_SKIP_ZSH_HTTPS
def test_zsh_https_post(zsh_run, https_server):
    r = zsh_run("-d", "tls=1", f"{https_server.url}/echo-body")
    assert r.returncode == 0
    assert r.stdout == "tls=1"


# ---------------------------------------------------------------------------
# Verbose output
# ---------------------------------------------------------------------------

def test_zsh_verbose_shows_request_headers(zsh_run, http_server):
    r = zsh_run("-v", f"{http_server.url}/get")
    assert r.returncode == 0
    assert "> GET" in r.stderr
    assert "> Host:" in r.stderr
    assert "> User-Agent:" in r.stderr
    assert "< HTTP/1.0 200" in r.stderr


def test_zsh_silent_suppresses_stderr(zsh_run, http_server):
    r = zsh_run("-s", f"{http_server.url}/notfound")
    assert r.returncode != 0
    assert r.stderr == ""


# ---------------------------------------------------------------------------
# Output to file
# ---------------------------------------------------------------------------

def test_zsh_output_to_file(zsh_run, http_server, tmp_path):
    out = tmp_path / "body.txt"
    r = zsh_run("-o", str(out), f"{http_server.url}/get")
    assert r.returncode == 0
    assert out.read_text() == "hello world\n"
