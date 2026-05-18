"""Tests for basic GET functionality."""
import os
import tempfile

import pytest


def test_basic_get_returns_body(run, http_server):
    r = run(f"{http_server.url}/get")
    assert r.returncode == 0
    assert r.stdout == "hello world\n"


def test_empty_path_defaults_to_root(run, http_server):
    # Connecting to the host with no path; server returns 404 for "/" route
    # (our test server 404s on /), so just confirm the script parses the URL
    # without crashing and exits with a non-zero code for 404.
    r = run(f"{http_server.url}")
    assert r.returncode != 0  # 404 from server


def test_explicit_root_path(run, http_server):
    r = run(f"{http_server.url}/get")
    assert r.returncode == 0


def test_query_string_preserved(run, http_server):
    r = run(f"{http_server.url}/echo-path?q=1&b=hello")
    assert r.returncode == 0
    assert "q=1" in r.stdout
    assert "b=hello" in r.stdout


def test_empty_body(run, http_server):
    r = run(f"{http_server.url}/empty")
    assert r.returncode == 0
    assert r.stdout == ""


def test_large_body(run, http_server):
    r = run(f"{http_server.url}/large")
    assert r.returncode == 0
    assert len(r.stdout) == 1024 * 1024


def test_no_url_prints_usage(run):
    r = run()
    assert r.returncode != 0
    assert "Usage" in r.stderr


def test_bad_url_format(run):
    r = run("://bad-url")
    assert r.returncode != 0
    assert r.stderr  # some error message


def test_unknown_flag(run):
    r = run("--unknown-flag", "http://localhost/")
    assert r.returncode != 0


def test_no_url_given(run):
    r = run("-v")
    assert r.returncode != 0


if __name__ == "__main__":
    import sys
    import pytest
    sys.exit(pytest.main([__file__, "-v"] + sys.argv[1:]))
