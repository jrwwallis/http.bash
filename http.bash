#!/bin/bash
# http.bash — minimal HTTP/HTTPS client.
# Flags follow curl conventions; run --help for usage.
# Requires bash 4.1+ or zsh 5.x. On macOS the bootstrap below auto-selects
# zsh (the default shell) when no suitable bash is installed.
# External deps (intentional exceptions to the shell-only rule):
#   openssl — TLS (HTTPS) and base64 for -u auth
#   cat     — binary-safe body transfer (shell read drops null bytes)

# -- Bootstrap: ensure we're running in bash 4.1+ or zsh 5.x --
# _HTTP_SHELL_SELECTED is exported to the re-exec'd process to prevent loops.
if [[ -z "${_HTTP_SHELL_SELECTED}" ]]; then
  if [[ "${BASH_VERSINFO[0]}" -gt 4 ]] ||
     [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 1 ]]; then
    _HTTP_SHELL_SELECTED=bash
  else
    for _candidate in bash-5 bash5 bash-4 bash4 bash; do
      if command -v "${_candidate}" &>/dev/null; then
        # shellcheck disable=SC2016  # single quotes intentional: expr runs in $_candidate
        _bash_ver=$("${_candidate}" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null)
        case "${_bash_ver}" in
          [5-9].*|4.[1-9]*|4.[1-9][0-9]*)
            _HTTP_SHELL_SELECTED="${_candidate}" exec "${_candidate}" -- "$0" "$@" ;;
        esac
      fi
    done
    if command -v zsh &>/dev/null; then
      _HTTP_SHELL_SELECTED=zsh exec zsh -- "$0" "$@"
    fi
    printf 'http.bash: needs bash 4.1+ or zsh 5.x; neither found\n' >&2
    exit 1
  fi
fi

# -- Shell detection and zsh-specific setup --
[[ -n "${ZSH_VERSION}" ]] && _IS_ZSH=1 || _IS_ZSH=''
if [[ -n "${_IS_ZSH}" ]]; then
  zmodload zsh/net/tcp || { printf 'http.bash: zsh/net/tcp module required\n' >&2; exit 1; }
fi

set -o pipefail

opt_max_redirs=10
opt_headers=()

die()  { [[ -z "${opt_silent}" ]] && printf 'http.bash: %s\n' "$*" >&2; exit 1; }
log()  { [[ -z "${opt_silent}" ]] && printf '%s\n' "$*" >&2; return 0; }
vlog() { [[ -n "${opt_verbose}" && -z "${opt_silent}" ]] && printf '%s\n' "$*" >&2; return 0; }

usage() {
  printf '%s\n' \
    'Usage: http.bash [OPTIONS] URL' \
    '' \
    'Minimal HTTP/HTTPS client (bash/zsh built-ins + openssl for HTTPS).' \
    'Flags follow curl conventions.' \
    '' \
    'Options:' \
    '  -v              Verbose: show request/response headers on stderr' \
    '  -o <file>       Write body to <file> instead of stdout' \
    '  -I              HEAD request: show response headers, no body' \
    '  -L              Follow redirects' \
    '  -H "Name: Val"  Add request header (repeatable)' \
    '  -s              Silent: suppress all stderr output' \
    '  -u user:pass    HTTP Basic auth' \
    '  -X METHOD       HTTP method (default: GET, or POST when -d is given)' \
    '  -d <data>       Request body (implies POST unless -X overrides)' \
    '  -D <file>       Dump response headers to <file>' \
    '  -A <agent>      Custom User-Agent' \
    '  -e <url>        Referer URL' \
    '  --max-redirs N  Max redirects to follow (default: 10)' \
    '  --connect-timeout N  Seconds to wait for first response byte' \
    '  --help          Show this help and exit' \
    '' \
    'External dependencies:' \
    '  openssl  HTTPS and -u basic auth' \
    '  cat      Binary-safe body output' \
    >&2
}

# -- Compatibility shims (bash 4.1+ / zsh 5.x) --

# _regex STR PATTERN — match STR against PATTERN and populate _regex_groups[].
# _regex_groups[1]=group1, [2]=group2, ... (same indexing in bash and zsh because
# BASH_REMATCH[N] and zsh $match[N] both store group N at index N).
_regex() {
  local str="$1" pattern="$2"
  if [[ -n "${_IS_ZSH}" ]]; then
    # shellcheck disable=SC2154  # $match is the zsh regex capture array
    if [[ "${str}" =~ ${pattern} ]]; then
      _regex_groups=("${match[@]}"); return 0
    fi
    return 1
  else
    if [[ "${str}" =~ ${pattern} ]]; then
      _regex_groups=("${BASH_REMATCH[@]}"); return 0
    fi
    return 1
  fi
}

# _tolower STR — print STR lowercased; typeset -l works in bash 4.0+ and zsh.
_tolower() {
  local _lower
  typeset -l _lower
  _lower="$1"
  printf '%s' "${_lower}"
}

# _tcp_connect HOST PORT — open a plain TCP socket.
# Sets conn_read_fd, conn_write_fd, conn_is_tls=''.
_tcp_connect() {
  if [[ -n "${_IS_ZSH}" ]]; then
    ztcp "$1" "$2" || die "Could not connect to $1:$2"
    conn_read_fd="${REPLY}"; conn_write_fd="${REPLY}"
  else
    exec 3<>"/dev/tcp/$1/$2" || die "Could not connect to $1:$2"
    conn_read_fd=3; conn_write_fd=3
  fi
  conn_is_tls=''
}

# _tls_connect HOST PORT — open a TLS connection via openssl s_client coproc.
# Sets conn_read_fd, conn_write_fd, tls_pid, conn_is_tls=1.
#
# Both branches use `coproc { ... }` syntax (valid in bash and zsh).
# zsh unnamed coprocs expose FDs via <&p / >&p (no COPROC array);
# bash exposes them via COPROC[0] (read) and COPROC[1] (write).
_tls_connect() {
  command -v openssl &>/dev/null || die "openssl is required for HTTPS"
  # shellcheck disable=SC2031,SC2154  # $COPROC is set by coproc builtin
  coproc { exec openssl s_client -quiet \
    -connect "$1:$2" -servername "$1" 2>/dev/null; }
  tls_pid=$!
  if [[ -n "${_IS_ZSH}" ]]; then
    # zsh: dup coproc stdout/stdin via the p descriptor.
    # {var}<&p allocates an FD and stores its number in the variable.
    exec {conn_read_fd}<&p
    exec {conn_write_fd}>&p
  else
    # bash (0-indexed): COPROC[0]=read(stdout), COPROC[1]=write(stdin).
    local _read_fd
    eval "exec {_read_fd}<&${COPROC[0]}"
    conn_read_fd="${_read_fd}"; conn_write_fd="${COPROC[1]}"
  fi
  conn_is_tls=1
}

# Header-dump FD helpers. zsh cannot use multi-digit FDs in `exec N>file`
# syntax; use {var}>file instead which allocates a FD dynamically.
_DUMP_FD=''
_open_write_fd() {
  if [[ -n "${_IS_ZSH}" ]]; then
    exec {_DUMP_FD}>"$1"
  else
    eval "exec {_DUMP_FD}>\"$1\""
  fi
}
_close_write_fd() {
  if [[ -n "${_IS_ZSH}" ]]; then
    exec {_DUMP_FD}>&-
  else
    eval "exec ${_DUMP_FD}>&-"
  fi
}

# -- Argument parsing --
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v) opt_verbose=1;  shift ;;
    -I) opt_head=1;     shift ;;
    -s) opt_silent=1;   shift ;;
    -L) opt_follow=1;   shift ;;
    -o) [[ $# -lt 2 ]] && die "-o requires an argument"
        opt_output="$2";        shift 2 ;;
    -H) [[ $# -lt 2 ]] && die "-H requires an argument"
        opt_headers+=("$2");    shift 2 ;;
    -u) [[ $# -lt 2 ]] && die "-u requires an argument"
        opt_auth="$2";          shift 2 ;;
    -X) [[ $# -lt 2 ]] && die "-X requires an argument"
        opt_method="$2";        shift 2 ;;
    -d) [[ $# -lt 2 ]] && die "-d requires an argument"
        opt_data="$2";          shift 2 ;;
    -D) [[ $# -lt 2 ]] && die "-D requires an argument"
        opt_dump_headers="$2";  shift 2 ;;
    -A) [[ $# -lt 2 ]] && die "-A requires an argument"
        opt_agent="$2";         shift 2 ;;
    -e) [[ $# -lt 2 ]] && die "-e requires an argument"
        opt_referer="$2";       shift 2 ;;
    --max-redirs)
        [[ $# -lt 2 ]] && die "--max-redirs requires an argument"
        opt_max_redirs="$2";    shift 2 ;;
    --connect-timeout)
        [[ $# -lt 2 ]] && die "--connect-timeout requires an argument"
        opt_connect_timeout="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1" ;;
    *)  break ;;
  esac
done

[[ $# -lt 1 ]] && { usage; exit 1; }
url="$1"

if [[ -n "${opt_head}" ]]; then
  method="HEAD"
elif [[ -n "${opt_method}" ]]; then
  method="${opt_method}"
elif [[ -n "${opt_data}" ]]; then
  method="POST"
else
  method="GET"
fi

# -- URL parsing --
parse_url() {
  local raw_url="$1"
  local url_re='^((https?)://)?([A-Za-z0-9._~%-]+)(:([0-9]+))?(/[^#]*)?(#.*)?$'
  if _regex "${raw_url}" "${url_re}"; then
    url_scheme="${_regex_groups[2]:-http}"
    url_host="${_regex_groups[3]}"
    url_port="${_regex_groups[5]}"
    url_path="${_regex_groups[6]:-/}"
  else
    die "Malformed URL: ${raw_url}"
  fi
  [[ -z "${url_host}" ]] && die "No host in URL: ${raw_url}"
  [[ -z "${url_port}" ]] && { [[ "${url_scheme}" == "https" ]] && url_port=443 || url_port=80; }
}

# Emit :PORT only for non-default ports (used in Host header and URL reconstruction).
port_suffix() {
  if [[ ("${url_scheme}" == "http"  && "${url_port}" != "80") ||
        ("${url_scheme}" == "https" && "${url_port}" != "443") ]]; then
    printf ':%s' "${url_port}"
  fi
}

# Resolve a Location value (possibly relative) against the current URL.
resolve_url() {
  local location="$1"
  case "${location}" in
    http://*|https://*) printf '%s' "${location}" ;;
    //*) printf '%s:%s' "${url_scheme}" "${location}" ;;
    /*)  printf '%s://%s%s%s' "${url_scheme}" "${url_host}" "$(port_suffix)" "${location}" ;;
    *)
      local url_dir="${url_path%/*}"
      printf '%s://%s%s%s/%s' "${url_scheme}" "${url_host}" "$(port_suffix)" "${url_dir%/}" "${location}" ;;
  esac
}

# -- Connection management --
open_connection() {
  if [[ "${url_scheme}" == "https" ]]; then
    _tls_connect "${url_host}" "${url_port}"
  else
    _tcp_connect "${url_host}" "${url_port}"
  fi
}

close_connection() {
  if [[ -n "${conn_is_tls}" && -n "${tls_pid}" ]]; then
    if [[ -n "${_IS_ZSH}" ]]; then
      { exec {conn_write_fd}>&-; } 2>/dev/null || true
      wait "${tls_pid}" 2>/dev/null || true
      { exec {conn_read_fd}<&-; } 2>/dev/null || true
    else
      { eval "exec ${conn_write_fd}>&-"; } 2>/dev/null || true
      wait "${tls_pid}" 2>/dev/null || true
      { eval "exec ${conn_read_fd}<&-"; } 2>/dev/null || true
    fi
    tls_pid=''
  elif [[ -n "${_IS_ZSH}" ]]; then
    if [[ -n "${conn_read_fd}" ]]; then { ztcp -c "${conn_read_fd}"; } 2>/dev/null || true; fi
  else
    if [[ "${conn_read_fd}" == "3" ]]; then { exec 3>&-; } 2>/dev/null || true; fi
  fi
  conn_read_fd=''
  conn_write_fd=''
  conn_is_tls=''
}

trap close_connection EXIT

# -- Request --
send_request() {
  local method="$1"
  # HTTP/1.0 avoids chunked transfer encoding; identity avoids compression.
  vlog "> ${method} ${url_path} HTTP/1.0"
  printf '%s %s HTTP/1.0\r\n' "${method}" "${url_path}" >&"${conn_write_fd}"

  local host_header
  host_header="${url_host}$(port_suffix)"
  printf 'Host: %s\r\n' "${host_header}" >&"${conn_write_fd}"
  vlog "> Host: ${host_header}"

  printf 'Accept-Encoding: identity\r\n' >&"${conn_write_fd}"
  vlog '> Accept-Encoding: identity'

  local user_agent="${opt_agent:-http.bash/1.0}"
  printf 'User-Agent: %s\r\n' "${user_agent}" >&"${conn_write_fd}"
  vlog "> User-Agent: ${user_agent}"

  local header
  for header in "${opt_headers[@]}"; do
    printf '%s\r\n' "${header}" >&"${conn_write_fd}"
    vlog "> ${header}"
  done

  if [[ -n "${opt_auth}" ]]; then
    local encoded
    encoded=$(printf '%s' "${opt_auth}" | openssl enc -base64 -A 2>/dev/null) \
      || die "Failed to base64-encode credentials (openssl missing?)"
    printf 'Authorization: Basic %s\r\n' "${encoded}" >&"${conn_write_fd}"
    vlog '> Authorization: Basic ***'
  fi

  if [[ -n "${opt_referer}" ]]; then
    printf 'Referer: %s\r\n' "${opt_referer}" >&"${conn_write_fd}"
    vlog "> Referer: ${opt_referer}"
  fi

  if [[ -n "${opt_data}" && -z "${opt_head}" ]]; then
    local byte_len
    # ${#var} counts characters; LC_ALL=C in a subshell makes bash/zsh count bytes.
    byte_len=$(LC_ALL=C; echo "${#opt_data}")
    printf 'Content-Type: application/x-www-form-urlencoded\r\n' >&"${conn_write_fd}"
    printf 'Content-Length: %d\r\n' "${byte_len}" >&"${conn_write_fd}"
    vlog "> Content-Length: ${byte_len}"
  fi

  printf '\r\n' >&"${conn_write_fd}"
  [[ -n "${opt_data}" && -z "${opt_head}" ]] && printf '%s' "${opt_data}" >&"${conn_write_fd}"
}

# -- Response --
read_status_line() {
  local timeout_flag=()
  [[ -n "${opt_connect_timeout}" ]] && timeout_flag=(-t "${opt_connect_timeout}")

  local raw_line
  if ! IFS= read -r "${timeout_flag[@]}" -u "${conn_read_fd}" raw_line; then
    [[ -n "${opt_connect_timeout}" ]] \
      && die "Timed out waiting for response from ${url_host}"
    die "Connection closed before status line received"
  fi
  local status_line="${raw_line%$'\r'}"
  vlog "< ${status_line}"
  [[ -n "${opt_head}" ]] && printf '%s\n' "${status_line}"

  local status_re='^HTTP/([0-9.]+) +([0-9]+) *(.*)$'
  if _regex "${status_line}" "${status_re}"; then
    resp_code="${_regex_groups[2]}"
    resp_msg="${_regex_groups[3]}"
  else
    die "Malformed HTTP status line: ${status_line}"
  fi
}

read_response_headers() {
  resp_location=''
  local dump_fd=''
  if [[ -n "${opt_dump_headers}" ]]; then
    _open_write_fd "${opt_dump_headers}" \
      || die "Cannot open ${opt_dump_headers} for writing"
    dump_fd="${_DUMP_FD}"
  fi

  local raw_line header_line header_name
  local header_re='^([A-Za-z0-9-]+): *(.*)$'
  while IFS= read -r -u "${conn_read_fd}" raw_line; do
    header_line="${raw_line%$'\r'}"
    [[ -z "${header_line}" ]] && break
    vlog "< ${header_line}"
    [[ -n "${dump_fd}" ]] && printf '%s\n' "${header_line}" >&"${dump_fd}"
    [[ -n "${opt_head}" ]] && printf '%s\n' "${header_line}"
    if _regex "${header_line}" "${header_re}"; then
      header_name="$(_tolower "${_regex_groups[1]}")"
      [[ "${header_name}" == "location" ]] && resp_location="${_regex_groups[2]}"
    fi
  done

  [[ -n "${dump_fd}" ]] && _close_write_fd
}

# -- Main loop --
parse_url "${url}"
redirs_left="${opt_max_redirs}"

while true; do
  open_connection
  send_request "${method}"
  read_status_line
  read_response_headers

  if [[ "${resp_code}" -ge 200 && "${resp_code}" -lt 300 ]]; then
    # cat for binary-safe transfer (shell read drops null bytes).
    if [[ -z "${opt_head}" ]]; then
      if [[ -n "${opt_output}" ]]; then
        cat <&"${conn_read_fd}" > "${opt_output}" \
          || die "Failed to write body to ${opt_output}"
      else
        cat <&"${conn_read_fd}"
      fi
    fi
    close_connection
    exit 0

  elif [[ "${resp_code}" -ge 300 && "${resp_code}" -lt 400 ]]; then
    [[ -z "${opt_follow}" ]]    && die "HTTP ${resp_code} ${resp_msg} (use -L to follow redirects)"
    [[ -z "${resp_location}" ]] && die "HTTP ${resp_code} with no Location header"
    [[ "${redirs_left}" -le 0 ]] && die "Too many redirects (--max-redirs ${opt_max_redirs})"
    (( redirs_left-- )) || true
    new_url=$(resolve_url "${resp_location}")
    log "Redirect [${resp_code}] -> ${new_url}"
    close_connection
    url="${new_url}"
    parse_url "${url}"
    # 301/302/303: downgrade to GET and drop body (curl behaviour). 307/308: preserve method.
    case "${resp_code}" in 301|302|303) method="GET"; opt_data='' ;; esac
    continue

  else
    die "HTTP ${resp_code} ${resp_msg}"
  fi
done
