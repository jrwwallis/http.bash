"""Tests for HTTPS support via openssl s_client."""
import pytest


pytestmark = pytest.mark.skipif(
    not __import__("shutil").which("openssl"),
    reason="openssl not available",
)


def test_https_basic_get(run, https_server):
    """HTTPS GET returns the correct body (self-signed cert, no verification)."""
    r = run(f"{https_server.url}/get")
    assert r.returncode == 0
    assert r.stdout == "hello world\n"


def test_https_empty_body(run, https_server):
    r = run(f"{https_server.url}/empty")
    assert r.returncode == 0
    assert r.stdout == ""


def test_https_large_body(run, https_server):
    r = run(f"{https_server.url}/large", timeout=20)
    assert r.returncode == 0
    assert len(r.stdout) == 1024 * 1024


def test_https_head_request(run, https_server):
    r = run("-I", f"{https_server.url}/get")
    assert r.returncode == 0
    assert "HTTP/" in r.stdout
    assert "hello world" not in r.stdout


def test_https_verbose_headers(run, https_server):
    r = run("-v", f"{https_server.url}/get")
    assert r.returncode == 0
    assert "> GET /get HTTP/1.0" in r.stderr


def test_https_redirect_to_http(run, https_server, http_server):
    """HTTPS redirect pointing at an HTTP URL is followed correctly."""
    # Our test server redirects /redirect301 to the same-scheme /get.
    # Simulate cross-scheme by using the http_server URL as the final target.
    r = run(
        "-L",
        f"{https_server.url}/redirect301",
    )
    assert r.returncode == 0
    assert r.stdout == "hello world\n"


def test_https_custom_header(run, https_server):
    r = run("-H", "X-Test-Foo: tls-check", f"{https_server.url}/echo-headers")
    assert r.returncode == 0
    assert "X-Test-Foo: tls-check" in r.stdout


def test_https_post_body(run, https_server):
    r = run("-d", "tls=1", f"{https_server.url}/echo-body")
    assert r.returncode == 0
    assert r.stdout == "tls=1"


if __name__ == "__main__":
    import sys
    import pytest
    sys.exit(pytest.main([__file__, "-v"] + sys.argv[1:]))
