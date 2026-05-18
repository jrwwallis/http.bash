# http.bash

A minimal HTTP/HTTPS client implemented as a single bash script.

## Introduction

`http.bash` lets you fetch URLs from the command line using almost nothing but
bash itself. It covers the everyday use cases — GET, POST, redirects, basic
auth, custom headers, HTTPS — without pulling in curl, wget, or any other
compiled HTTP library.

The main use case is environments where you need to transfer a small, portable
tool over a slow or restricted link and then use it immediately: embedded
systems, minimal containers, CI bootstrap stages, and so on. A single script
is easy to copy with `scp`, embed in a heredoc, or paste into a terminal, and
it runs on any host that has bash 4.1+ or zsh 5.x — including stock macOS.

## Design principles

1. **Shell built-ins first.** Network I/O goes through `/dev/tcp` (bash) or
   `ztcp` (zsh), response parsing uses `read` and `[[ =~ ]]`, and header
   handling is pure shell string manipulation. External tools are used only
   where the shell fundamentally cannot do the job.

2. **Minimal, deliberate exceptions.** Two external dependencies are
   unavoidable:
   - `openssl` — required for TLS (HTTPS) and for base64-encoding Basic auth
     credentials. Bash has no native TLS support.
   - `cat` — required for binary-safe body transfer. Bash's `read` silently
     drops null bytes (`\0`), making it unsuitable for arbitrary binary data.

3. **Single file, readable source.** The entire implementation lives in
   `http.bash`. No build step, no compiled components, no install. Copy the
   file and run it. The source is kept small but not minified; clarity is
   preferred over brevity when the two conflict.

4. **curl-compatible CLI.** Flags follow curl conventions so that usage is
   familiar and the tool can act as a drop-in replacement for common curl
   one-liners.

5. **HTTP/1.0 requests.** Using HTTP/1.0 avoids chunked transfer encoding and
   most of the complexity that comes with HTTP/1.1 persistent connections.
   Servers respond with a single body and close the connection, keeping the
   response-parsing logic simple.

6. **Correct over clever.** HTTP edge cases (Content-Length in bytes not
   characters, 301/302/303 dropping the request body, HEAD never sending a
   body) are handled correctly even where a naive implementation would not
   notice the difference.

## Requirements

- **bash 4.1+** *or* **zsh 5.x** — the script works with either shell
- `openssl` — for HTTPS and `-u` basic auth (optional for plain HTTP)
- `cat` — for binary body output (present on virtually every Unix system)

### macOS

macOS ships with bash 3.2 (too old) and zsh 5.x (fully supported). The
script detects the situation automatically at startup and re-execs under
the best available shell:

1. If a bash 4.1+ binary is found in `PATH` (e.g. from Homebrew: `brew install bash`), it is preferred.
2. Otherwise, zsh is used — which works out of the box on any stock macOS system.

No manual shell selection is needed; just run `./http.bash` as usual.

**macOS dependencies for development:**

```bash
brew install shellcheck       # linter (required by `make lint`)
python3 -m venv .venv        # create a virtualenv (system Python is externally managed)
.venv/bin/pip install -r requirements.txt  # install pytest
```

Runtime dependencies (`openssl`, `cat`, `zsh`) are pre-installed on macOS.

## Installation

```bash
curl -O https://raw.githubusercontent.com/.../http.bash
chmod +x http.bash
```

Or copy the single file to wherever you need it.

## Usage

```
http.bash [OPTIONS] URL
```

### Options

| Flag | Description |
|------|-------------|
| `-v` | Verbose: print request and response headers to stderr |
| `-s` | Silent: suppress all stderr output |
| `-o <file>` | Write response body to `<file>` instead of stdout |
| `-I` | HEAD request: print response headers, no body |
| `-L` | Follow redirects (3xx responses) |
| `-H "Name: Val"` | Add a request header (repeatable) |
| `-u user:pass` | HTTP Basic authentication |
| `-X METHOD` | HTTP method (default: GET, or POST when `-d` is given) |
| `-d <data>` | Request body; implies POST unless `-X` overrides |
| `-D <file>` | Dump response headers to `<file>` |
| `-A <agent>` | Custom User-Agent string |
| `-e <url>` | Referer URL |
| `--max-redirs N` | Maximum redirects to follow (default: 10) |
| `--connect-timeout N` | Seconds to wait for the first response byte |
| `--help` | Print help and exit |

## Examples

### Basic GET (HTTP)

```bash
./http.bash http://example.com/
```

### Basic GET (HTTPS)

```bash
./http.bash https://example.com/
```

### Save body to a file

```bash
./http.bash -o index.html http://example.com/
```

### Verbose output (see request/response headers)

```bash
./http.bash -v http://httpbin.org/get
```

### Follow redirects

```bash
./http.bash -L http://httpbin.org/redirect/3
```

### POST form data

```bash
./http.bash -d "name=alice&role=admin" http://httpbin.org/post
```

### POST JSON

```bash
./http.bash -X POST \
  -H "Content-Type: application/json" \
  -d '{"name":"alice"}' \
  http://httpbin.org/post
```

### HTTP Basic auth

```bash
./http.bash -u alice:secret http://httpbin.org/basic-auth/alice/secret
```

### Custom headers

```bash
./http.bash -H "Accept: application/json" \
            -H "X-Request-ID: abc123" \
            http://httpbin.org/headers
```

### HEAD request (response headers only)

```bash
./http.bash -I http://example.com/
```

### Dump response headers to a file

```bash
./http.bash -D headers.txt http://example.com/
```

### Set a connection timeout

```bash
./http.bash --connect-timeout 5 http://slow.example.com/
```

### Limit redirects

```bash
./http.bash -L --max-redirs 2 http://example.com/redirect-chain
```

## Notes

- **HTTP/1.0 only.** Servers that require HTTP/1.1 features (chunked encoding,
  virtual hosting without a Host header) may not work correctly. In practice
  this is rare; virtually all servers accept HTTP/1.0 requests.

- **No certificate verification.** The `openssl s_client` invocation does not
  verify the server certificate. This is intentional for a minimal tool; use
  curl if you need strict TLS certificate checking.

- **Body data is passed as a shell argument.** Binary data with null bytes
  cannot be passed via `-d`; use curl for that case.

- **Redirect body semantics match curl.** 301, 302, and 303 redirects drop the
  request body and switch to GET. 307 and 308 preserve the method and body.

## Development

Run the full test suite and linter:

```bash
make check
```

Run only the linter:

```bash
make lint
```

Run only the tests:

```bash
make test
```

Run a single test module:

```bash
make test-cli
make test-redirects
```

Run the zsh compatibility suite:

```bash
make test-zsh
```

Tests require Python 3 with `pytest` (`pip install -r requirements.txt`) and
`openssl` for the HTTPS suite. The zsh suite is automatically skipped if
`zsh` is not installed.
