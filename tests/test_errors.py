"""Tests for error handling."""
import pytest


def test_404_exits_nonzero(run, http_server):
    r = run(f"{http_server.url}/notfound")
    assert r.returncode != 0


def test_404_error_message(run, http_server):
    r = run(f"{http_server.url}/notfound")
    assert "404" in r.stderr


def test_500_exits_nonzero(run, http_server):
    r = run(f"{http_server.url}/servererror")
    assert r.returncode != 0


def test_500_error_message(run, http_server):
    r = run(f"{http_server.url}/servererror")
    assert "500" in r.stderr


def test_connection_refused(run):
    # Connect to a port that is almost certainly not listening.
    r = run("http://127.0.0.1:19999/")
    assert r.returncode != 0


def test_bad_url_no_host(run):
    r = run("http:///path")
    assert r.returncode != 0


def test_redirect_without_follow_flag(run, http_server):
    r = run(f"{http_server.url}/redirect301")
    assert r.returncode != 0
    assert "301" in r.stderr


def test_silent_suppresses_stderr(run, http_server):
    r = run("-s", f"{http_server.url}/notfound")
    assert r.returncode != 0
    assert r.stderr == ""  # -s suppresses all stderr


def test_silent_no_output_on_success(run, http_server):
    r = run("-s", "-o", "/dev/null", f"{http_server.url}/get")
    assert r.returncode == 0
    assert r.stderr == ""


if __name__ == "__main__":
    import sys
    import pytest
    sys.exit(pytest.main([__file__, "-v"] + sys.argv[1:]))
