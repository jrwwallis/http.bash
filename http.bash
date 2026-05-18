#!/bin/bash
# http.bash — minimal HTTP/HTTPS client using bash built-ins.
# Flags follow curl conventions; run --help for usage.
# Requires bash 4.1+ (named coproc and dynamic FD allocation for HTTPS).
# macOS ships bash 3.2; install a newer bash via Homebrew if needed.
# External deps (intentional exceptions to the bash-only rule):
#   openssl — TLS (HTTPS) and base64 for -u auth
#   cat     — binary-safe body transfer (bash read drops null bytes)

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] ||
   [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 1 ]]; then
  printf 'http.bash: requires bash 4.1+, got %s\n' "${BASH_VERSION}" >&2
  exit 1
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
    'Minimal HTTP/HTTPS client (bash built-ins + openssl for HTTPS).' \
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
  local raw="$1"
  local re='^((https?)://)?([A-Za-z0-9._~%-]+)(:([0-9]+))?(/[^#]*)?(#.*)?$'
  if [[ "$raw" =~ $re ]]; then
    url_scheme="${BASH_REMATCH[2]:-http}"
    url_host="${BASH_REMATCH[3]}"
    url_port="${BASH_REMATCH[5]}"
    url_path="${BASH_REMATCH[6]:-/}"
  else
    die "Malformed URL: ${raw}"
  fi
  [[ -z "${url_host}" ]] && die "No host in URL: ${raw}"
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
      local dir="${url_path%/*}"
      printf '%s://%s%s%s/%s' "${url_scheme}" "${url_host}" "$(port_suffix)" "${dir%/}" "${location}" ;;
  esac
}

# -- Connection management --
open_connection() {
  if [[ "${url_scheme}" == "https" ]]; then
    command -v openssl &>/dev/null || die "openssl is required for HTTPS"
    # Run openssl s_client as a coproc to get separate read/write FDs.
    # Duplicate the read end immediately: bash auto-closes TLS[0] when
    # openssl exits, but the dup'd FD persists so we can drain the buffer.
    coproc TLS { exec openssl s_client -quiet \
      -connect "${url_host}:${url_port}" \
      -servername "${url_host}" 2>/dev/null; }
    local _rd
    exec {_rd}<&"${TLS[0]}"
    conn_read_fd="${_rd}"
    conn_write_fd="${TLS[1]}"
    # shellcheck disable=SC2153  # TLS_PID is set by coproc, not a typo
    tls_pid="${TLS_PID}"
    conn_is_tls=1
  else
    exec 3<>"/dev/tcp/${url_host}/${url_port}" \
      || die "Could not connect to ${url_host}:${url_port}"
    conn_read_fd=3
    conn_write_fd=3
    conn_is_tls=''
  fi
}

close_connection() {
  if [[ -n "${conn_is_tls}" && -n "${tls_pid}" ]]; then
    # Command groups scope the 2>/dev/null so it doesn't permanently
    # redirect the shell's stderr (bare "exec N>&- 2>/dev/null" would).
    { eval "exec ${conn_write_fd}>&-"; } 2>/dev/null || true
    wait "${tls_pid}" 2>/dev/null || true
    { eval "exec ${conn_read_fd}<&-"; } 2>/dev/null || true
    tls_pid=''
  elif [[ "${conn_read_fd}" == "3" ]]; then
    { exec 3>&-; } 2>/dev/null || true
  fi
  conn_read_fd=''
  conn_write_fd=''
  conn_is_tls=''
}

trap close_connection EXIT

# -- Request --
send_request() {
  local meth="$1"
  # HTTP/1.0 avoids chunked transfer encoding; identity avoids compression.
  vlog "> ${meth} ${url_path} HTTP/1.0"
  printf '%s %s HTTP/1.0\r\n' "${meth}" "${url_path}" >&"${conn_write_fd}"

  local host_hdr
  host_hdr="${url_host}$(port_suffix)"
  printf 'Host: %s\r\n' "${host_hdr}" >&"${conn_write_fd}"
  vlog "> Host: ${host_hdr}"

  printf 'Accept-Encoding: identity\r\n' >&"${conn_write_fd}"
  vlog '> Accept-Encoding: identity'

  local ua="${opt_agent:-http.bash/1.0}"
  printf 'User-Agent: %s\r\n' "${ua}" >&"${conn_write_fd}"
  vlog "> User-Agent: ${ua}"

  local h
  for h in "${opt_headers[@]+"${opt_headers[@]}"}"; do
    printf '%s\r\n' "${h}" >&"${conn_write_fd}"
    vlog "> ${h}"
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
    # ${#var} counts characters; LC_ALL=C in a subshell makes bash count bytes.
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

  local raw
  if ! IFS= read -r "${timeout_flag[@]}" -u "${conn_read_fd}" raw; then
    [[ -n "${opt_connect_timeout}" ]] \
      && die "Timed out waiting for response from ${url_host}"
    die "Connection closed before status line received"
  fi
  local line="${raw%$'\r'}"
  vlog "< ${line}"
  [[ -n "${opt_head}" ]] && printf '%s\n' "${line}"

  local re='^HTTP/([0-9.]+) +([0-9]+) *(.*)$'
  if [[ "${line}" =~ ${re} ]]; then
    resp_code="${BASH_REMATCH[2]}"
    resp_msg="${BASH_REMATCH[3]}"
  else
    die "Malformed HTTP status line: ${line}"
  fi
}

read_response_headers() {
  resp_location=''
  local dump_fd=''
  if [[ -n "${opt_dump_headers}" ]]; then
    exec {dump_fd}>"${opt_dump_headers}" \
      || die "Cannot open ${opt_dump_headers} for writing"
  fi

  local raw line
  local re='^([A-Za-z0-9-]+): *(.*)$'
  while IFS= read -r -u "${conn_read_fd}" raw; do
    line="${raw%$'\r'}"
    [[ -z "${line}" ]] && break
    vlog "< ${line}"
    [[ -n "${dump_fd}" ]] && printf '%s\n' "${line}" >&"${dump_fd}"
    [[ -n "${opt_head}" ]] && printf '%s\n' "${line}"
    if [[ "${line}" =~ ${re} ]]; then
      local lname="${BASH_REMATCH[1],,}"
      [[ "${lname}" == "location" ]] && resp_location="${BASH_REMATCH[2]}"
    fi
  done

  [[ -n "${dump_fd}" ]] && exec {dump_fd}>&-
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
    # cat for binary-safe transfer (bash read drops null bytes).
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
