"""Tests for CLI flags."""
import os
import tempfile

import pytest


def test_verbose_shows_request_headers(run, http_server):
    r = run("-v", f"{http_server.url}/get")
    assert r.returncode == 0
    assert "> GET /get HTTP/1.0" in r.stderr
    assert "> Host:" in r.stderr


def test_verbose_shows_response_headers(run, http_server):
    r = run("-v", f"{http_server.url}/get")
    assert r.returncode == 0
    assert "< HTTP/1.0 200 OK" in r.stderr


def test_output_to_file(run, http_server, tmp_path):
    out = str(tmp_path / "body.txt")
    r = run("-o", out, f"{http_server.url}/get")
    assert r.returncode == 0
    assert r.stdout == ""  # nothing to stdout
    with open(out) as f:
        assert f.read() == "hello world\n"


def test_head_request_prints_headers_to_stdout(run, http_server):
    r = run("-I", f"{http_server.url}/get")
    assert r.returncode == 0
    assert "HTTP/1.0 200 OK" in r.stdout
    assert "Content-Type" in r.stdout
    # Body must NOT appear.
    assert "hello world" not in r.stdout


def test_head_request_no_body(run, http_server):
    r = run("-I", f"{http_server.url}/get")
    assert r.returncode == 0
    # Stdout contains only header lines, no body content.
    assert "hello world" not in r.stdout


def test_custom_header_sent(run, http_server):
    r = run("-H", "X-Test-Foo: bar", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    assert "X-Test-Foo: bar" in r.stdout


def test_multiple_custom_headers(run, http_server):
    r = run(
        "-H", "X-Test-A: one",
        "-H", "X-Test-B: two",
        f"{http_server.url}/echo-headers",
    )
    assert r.returncode == 0
    assert "X-Test-A: one" in r.stdout
    assert "X-Test-B: two" in r.stdout


def test_custom_user_agent(run, http_server):
    r = run("-A", "MyAgent/2.0", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    assert "MyAgent/2.0" in r.stdout


def test_post_data(run, http_server):
    r = run("-d", "key=value", f"{http_server.url}/echo-body")
    assert r.returncode == 0
    assert r.stdout == "key=value"


def test_post_data_multibyte_content_length(run, http_server):
    """Content-Length must be byte count, not character count, for non-ASCII data."""
    payload = "café"  # 4 chars, 5 UTF-8 bytes
    r = run("-v", "-d", payload, f"{http_server.url}/echo-body")
    assert r.returncode == 0
    assert r.stdout == payload
    # Verbose output should show Content-Length: 5 (bytes), not 4 (chars).
    assert "> Content-Length: 5" in r.stderr


def test_post_data_implies_post_method(run, http_server):
    r = run("-d", "x=1", f"{http_server.url}/echo-method")
    assert r.returncode == 0
    assert r.stdout.strip() == "POST"


def test_explicit_method_overrides_default(run, http_server):
    r = run("-X", "DELETE", f"{http_server.url}/echo-method")
    assert r.returncode == 0
    assert r.stdout.strip() == "DELETE"


def test_referer_header(run, http_server):
    r = run("-e", "http://example.com/page", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    assert "example.com/page" in r.stdout


def test_referer_header_logged_in_verbose(run, http_server):
    r = run("-v", "-e", "http://example.com/page", f"{http_server.url}/get")
    assert r.returncode == 0
    assert "> Referer: http://example.com/page" in r.stderr


def test_dump_headers_to_file(run, http_server, tmp_path):
    dumpfile = str(tmp_path / "headers.txt")
    r = run("-D", dumpfile, f"{http_server.url}/get")
    assert r.returncode == 0
    with open(dumpfile) as f:
        content = f.read()
    assert "Content-Type" in content
    assert "Content-Length" in content


def test_help_flag(run):
    r = run("--help")
    assert r.returncode == 0
    assert "Usage" in r.stderr
    assert "--max-redirs" in r.stderr
    assert "curl" in r.stderr


def test_head_with_data_ignores_body(run, http_server):
    """-I combined with -d must send HEAD with no body or Content-* headers."""
    r = run("-I", "-v", "-d", "key=value", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    # Status line on stdout (HEAD behaviour)
    assert "HTTP/1.0 200" in r.stdout
    # Outgoing request headers (prefixed "> ") must not include body headers
    sent = [l for l in r.stderr.splitlines() if l.startswith("> ")]
    sent_text = "\n".join(sent)
    assert "Content-Length" not in sent_text
    assert "Content-Type" not in sent_text
    assert "> HEAD " in sent_text


def test_basic_auth(run, http_server):
    """Basic auth header should be sent (encoded correctly)."""
    r = run("-u", "user:password123", f"{http_server.url}/echo-headers")
    assert r.returncode == 0
    # The Authorization header should be present in the echo output.
    assert "Authorization: Basic" in r.stdout


if __name__ == "__main__":
    import sys
    import pytest
    sys.exit(pytest.main([__file__, "-v"] + sys.argv[1:]))
