"""
Shared fixtures for http.bash tests.

Provides:
  - http_server:  a session-scoped HTTP/1.0 test server with well-known endpoints.
  - https_server: a session-scoped HTTPS test server using a self-signed cert.
  - http_bash:    path to the http.bash script under test.
  - run:          helper that invokes http.bash as a subprocess.
"""
from __future__ import annotations

import os
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import NamedTuple

import pytest


# ---------------------------------------------------------------------------
# Script location
# ---------------------------------------------------------------------------

def _find_script() -> str:
    """Return the path to http.bash, handling both Bazel and direct invocation."""
    # Bazel sets TEST_SRCDIR to the runfiles tree root.
    srcdir = os.environ.get("TEST_SRCDIR", "")
    workspace = os.environ.get("TEST_WORKSPACE", "_main")
    if srcdir:
        for candidate in [
            os.path.join(srcdir, workspace, "http.bash"),
            os.path.join(srcdir, "_main", "http.bash"),
            os.path.join(srcdir, "http_bash", "http.bash"),
        ]:
            if os.path.isfile(candidate):
                return candidate
    # Direct pytest invocation from the repo root or tests/ directory.
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in [
        os.path.join(here, "..", "http.bash"),
        os.path.join(here, "http.bash"),
    ]:
        path = os.path.realpath(candidate)
        if os.path.isfile(path):
            return path
    raise FileNotFoundError("http.bash not found; run via Bazel or from the repo root")


_SCRIPT_PATH: str = _find_script()


@pytest.fixture(scope="session")
def http_bash() -> str:
    return _SCRIPT_PATH


# ---------------------------------------------------------------------------
# Test HTTP server
# ---------------------------------------------------------------------------

class _TestHandler(BaseHTTPRequestHandler):
    """Dispatch on URL path; always respond with HTTP/1.0."""

    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):  # suppress server logs in test output
        pass

    # Route all methods through a single dispatcher.
    def do_GET(self):   self._dispatch()
    def do_HEAD(self):  self._dispatch(head_only=True)
    def do_POST(self):  self._dispatch()
    def do_PUT(self):   self._dispatch()
    def do_DELETE(self): self._dispatch()

    def _dispatch(self, head_only: bool = False) -> None:
        # Strip query string for routing; the raw path is still in self.path.
        route = self.path.split("?")[0].split("#")[0]

        if route == "/get":
            self._send(200, b"hello world\n", extra_headers=self._echo_headers())
        elif route == "/empty":
            self._send(200, b"")
        elif route == "/large":
            self._send(200, b"x" * (1024 * 1024))
        elif route == "/echo-method":
            self._send(200, self.command.encode())
        elif route == "/echo-path":
            self._send(200, self.path.encode())
        elif route == "/echo-headers":
            lines = "\n".join(f"{k}: {v}" for k, v in self.headers.items())
            self._send(200, lines.encode())
        elif route == "/echo-body":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b""
            self._send(200, body)
        elif route == "/notfound":
            self._send(404, b"Not Found")
        elif route == "/servererror":
            self._send(500, b"Internal Server Error")
        elif route == "/redirect301-to-echo":
            self._redirect(301, "/echo-headers")
        elif route == "/redirect301":
            self._redirect(301, "/get")
        elif route == "/redirect302":
            self._redirect(302, "/get")
        elif route == "/redirect303":
            self._redirect(303, "/get")
        elif route == "/redirect307":
            self._redirect(307, "/get")
        elif route == "/redirect308":
            self._redirect(308, "/get")
        elif route == "/chain1":
            self._redirect(301, "/chain2")
        elif route == "/chain2":
            self._redirect(302, "/get")
        elif route == "/loop":
            self._redirect(301, "/loop")
        elif route == "/relative":
            # Location without leading slash (path-relative).
            self._redirect(301, "get", absolute=False)
        elif route == "/proto-relative":
            # Protocol-relative Location.
            host = self.headers.get("Host", "localhost")
            self._redirect(301, f"//{host}/get", absolute=False)
        else:
            self._send(404, b"Not Found")

    def _send(
        self,
        code: int,
        body: bytes,
        content_type: str = "text/plain",
        extra_headers: list[tuple[str, str]] | None = None,
        head_only: bool = False,
    ) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra_headers or []):
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _redirect(self, code: int, location: str, absolute: bool = True) -> None:
        if absolute and not location.startswith(("http", "//")):
            # Make it root-relative.
            pass
        self.send_response(code)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _echo_headers(self) -> list[tuple[str, str]]:
        """Echo request headers that start with X-Test- back in the response."""
        return [
            (f"Echo-{k}", v)
            for k, v in self.headers.items()
            if k.lower().startswith("x-test-")
        ]


class ServerInfo(NamedTuple):
    host: str
    port: int
    url: str


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start_server(handler_cls, ssl_context=None) -> tuple[HTTPServer, ServerInfo]:
    port = _free_port()
    httpd = HTTPServer(("127.0.0.1", port), handler_cls)
    if ssl_context:
        httpd.socket = ssl_context.wrap_socket(httpd.socket, server_side=True)
    scheme = "https" if ssl_context else "http"
    info = ServerInfo(host="127.0.0.1", port=port, url=f"{scheme}://127.0.0.1:{port}")
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd, info


@pytest.fixture(scope="session")
def http_server() -> ServerInfo:
    _, info = _start_server(_TestHandler)
    return info


# ---------------------------------------------------------------------------
# HTTPS test server with self-signed cert
# ---------------------------------------------------------------------------

def _create_self_signed_cert(tmpdir: str) -> tuple[str, str]:
    """Generate a self-signed cert + key for 127.0.0.1 / localhost."""
    cert = os.path.join(tmpdir, "cert.pem")
    key = os.path.join(tmpdir, "key.pem")
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", key, "-out", cert,
            "-days", "1", "-nodes",
            "-subj", "/CN=localhost",
            "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost",
        ],
        check=True,
        capture_output=True,
    )
    return cert, key


@pytest.fixture(scope="session")
def https_server() -> ServerInfo:
    tmpdir = tempfile.mkdtemp(prefix="http_bash_test_")
    cert, key = _create_self_signed_cert(tmpdir)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    _, info = _start_server(_TestHandler, ssl_context=ctx)
    return info


@pytest.fixture(scope="session")
def https_cert_dir(https_server) -> str:
    """Return the temp dir where the HTTPS server's self-signed cert lives."""
    # The cert was created in a temp dir with prefix http_bash_test_.
    # We need to find it; easier to store on the fixture.
    # Re-derive: the https_server fixture creates the cert in the same call.
    # Workaround: scan /tmp for the cert dir.
    for entry in os.scandir(tempfile.gettempdir()):
        if entry.name.startswith("http_bash_test_") and entry.is_dir():
            if os.path.isfile(os.path.join(entry.path, "cert.pem")):
                return entry.path
    raise RuntimeError("Could not find HTTPS cert dir")


# ---------------------------------------------------------------------------
# Script runner
# ---------------------------------------------------------------------------

class RunResult(NamedTuple):
    returncode: int
    stdout: str
    stderr: str


@pytest.fixture(scope="session")
def run(http_bash):
    """Return a callable that runs http.bash with the given args."""

    def _run(*args, input_data=None, timeout=10) -> RunResult:
        result = subprocess.run(
            ["bash", http_bash, *args],
            capture_output=True,
            text=True,
            input=input_data,
            timeout=timeout,
        )
        return RunResult(result.returncode, result.stdout, result.stderr)

    return _run
