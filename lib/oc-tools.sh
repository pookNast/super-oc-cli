#!/usr/bin/env bash
# oc-tools.sh — Scoped MCP tool registry for OpenClaude
#
# Manages MCP tool registration with lifetime tokens, staleness detection,
# and output bounding. Inspired by OpenCode's packages/core/src/tool/registry.ts
#
# Usage: source this file, then call oct_init
#
# Dependencies: jq, uuidgen (or sha256sum fallback)
# Logs: /tmp/oc-tools.log
# State: ~/.openclaude/sessions/<session_id>/tool_output/

# ── Source guard ───────────────────────────────────────────────────────────────
[[ -n "${_OCT_LOADED:-}" ]] && return 0
_OCT_LOADED=1

# ── Constants ──────────────────────────────────────────────────────────────────
_OCT_LOG="/tmp/oc-tools.log"
_OCT_BASE_DIR="${HOME}/.openclaude"
_OCT_SESSIONS_DIR="${_OCT_BASE_DIR}/sessions"
_OCT_DEFAULT_MAX_LINES=500
_OCT_DEFAULT_MAX_CHARS=50000
_OCT_STALE_SECONDS=3600  # 1 hour

# Known MCP servers: name → port
declare -A _OCT_KNOWN_SERVERS=(
  ["homelab-mcp"]="3101"
  ["warden-mcp"]="3005"
)

# ── Registry: associative arrays keyed by tool_name ───────────────────────────
# Each key maps to a pipe-delimited record:
#   server|token|registered_at|last_called|call_count|status
declare -A _OCT_REGISTRY=()
# Reverse map: server → space-separated list of tool names
declare -A _OCT_SERVER_TOOLS=()

# ── Internal session state ─────────────────────────────────────────────────────
_OCT_SESSION_ID="${_OC_SESSION_ID:-}"

# ── Logging ───────────────────────────────────────────────────────────────────
_oct_log() {
  local level="$1"; shift
  printf '[%s] [OCT:%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$level" "$*" >> "$_OCT_LOG"
}
_oct_info()  { _oct_log "INFO"  "$@"; }
_oct_warn()  { _oct_log "WARN"  "$@"; }
_oct_error() { _oct_log "ERROR" "$@"; }
_oct_debug() { _oct_log "DEBUG" "$@"; }

# ── Token generation ──────────────────────────────────────────────────────────
_oct_gen_token() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr -d '-' | head -c 16
  else
    date +%s%N | sha256sum | head -c 16
  fi
}

# ── Registry read/write helpers ───────────────────────────────────────────────
# Record format: server|token|registered_at|last_called|call_count|status
_oct_record_get() {
  local tool="$1" field="$2"
  local record="${_OCT_REGISTRY[$tool]:-}"
  [[ -z "$record" ]] && return 1
  case "$field" in
    server)        echo "${record%%|*}" ;;
    token)         echo "$(echo "$record" | cut -d'|' -f2)" ;;
    registered_at) echo "$(echo "$record" | cut -d'|' -f3)" ;;
    last_called)   echo "$(echo "$record" | cut -d'|' -f4)" ;;
    call_count)    echo "$(echo "$record" | cut -d'|' -f5)" ;;
    status)        echo "$(echo "$record" | cut -d'|' -f6)" ;;
  esac
}

_oct_record_set_field() {
  local tool="$1" field="$2" value="$3"
  local record="${_OCT_REGISTRY[$tool]:-}"
  [[ -z "$record" ]] && return 1
  local server token registered_at last_called call_count status
  IFS='|' read -r server token registered_at last_called call_count status <<< "$record"
  case "$field" in
    server)        server="$value" ;;
    token)         token="$value" ;;
    registered_at) registered_at="$value" ;;
    last_called)   last_called="$value" ;;
    call_count)    call_count="$value" ;;
    status)        status="$value" ;;
  esac
  _OCT_REGISTRY["$tool"]="${server}|${token}|${registered_at}|${last_called}|${call_count}|${status}"
}

# ── 1. oct_init ───────────────────────────────────────────────────────────────
# Initialize registry, scan for running MCP servers, auto-register their tools.
oct_init() {
  _oct_info "Initializing OCT tool registry"
  mkdir -p "$_OCT_SESSIONS_DIR"

  # Infer session ID if not set
  if [[ -z "$_OCT_SESSION_ID" ]]; then
    _OCT_SESSION_ID="session_$(date +%s)"
    _oct_info "No session ID found; generated: $_OCT_SESSION_ID"
  fi

  local session_output_dir="${_OCT_SESSIONS_DIR}/${_OCT_SESSION_ID}/tool_output"
  mkdir -p "$session_output_dir"

  # Scan known MCP servers
  local server port total=0
  for server in "${!_OCT_KNOWN_SERVERS[@]}"; do
    port="${_OCT_KNOWN_SERVERS[$server]}"
    if _oct_server_reachable "$server" "$port"; then
      local count
      count=$(oct_register_server "$server" "$port")
      _oct_info "Auto-registered $count tools from $server:$port"
      (( total += count ))
    else
      _oct_warn "MCP server $server:$port not reachable — skipped"
    fi
  done

  # Also scan ~/.mcp.json if present
  local mcp_config="${HOME}/.mcp.json"
  if [[ -f "$mcp_config" ]]; then
    _oct_scan_mcp_json "$mcp_config"
  fi

  _oct_info "Registry init complete. Total tools registered: $total"
}

# Check if an MCP server is reachable
_oct_server_reachable() {
  local server="$1" port="$2"
  curl -sf --max-time 2 "http://localhost:${port}/health" &>/dev/null \
    || curl -sf --max-time 2 "http://localhost:${port}/" &>/dev/null
}

# Scan ~/.mcp.json for additional servers
_oct_scan_mcp_json() {
  local config="$1"
  if ! command -v jq &>/dev/null; then
    _oct_warn "jq not found; cannot parse ~/.mcp.json"
    return
  fi
  local servers
  servers=$(jq -r 'to_entries[] | "\(.key) \(.value.port // empty)"' "$config" 2>/dev/null)
  while IFS=' ' read -r srv prt; do
    [[ -z "$srv" || -z "$prt" ]] && continue
    if [[ -z "${_OCT_KNOWN_SERVERS[$srv]+_}" ]] && _oct_server_reachable "$srv" "$prt"; then
      local count
      count=$(oct_register_server "$srv" "$prt")
      _oct_info "~/.mcp.json: auto-registered $count tools from $srv:$prt"
    fi
  done <<< "$servers"
}

# ── 2. oct_register ───────────────────────────────────────────────────────────
# Register a single tool. Returns the lifetime token via stdout.
oct_register() {
  local server_name="$1" tool_name="$2"
  if [[ -z "$server_name" || -z "$tool_name" ]]; then
    _oct_error "oct_register: requires <server_name> <tool_name>"
    return 1
  fi

  # If already active, return existing token
  if [[ -n "${_OCT_REGISTRY[$tool_name]+_}" ]]; then
    local status
    status=$(_oct_record_get "$tool_name" status)
    if [[ "$status" == "active" ]]; then
      _oct_debug "Tool $tool_name already active; returning existing token"
      _oct_record_get "$tool_name" token
      return 0
    fi
  fi

  local token registered_at
  token=$(_oct_gen_token)
  registered_at=$(date '+%Y-%m-%dT%H:%M:%S')

  _OCT_REGISTRY["$tool_name"]="${server_name}|${token}|${registered_at}|null|0|active"

  # Update server→tools reverse map
  local existing="${_OCT_SERVER_TOOLS[$server_name]:-}"
  if [[ -z "$existing" ]]; then
    _OCT_SERVER_TOOLS["$server_name"]="$tool_name"
  else
    # Only add if not already present
    [[ " $existing " != *" $tool_name "* ]] && _OCT_SERVER_TOOLS["$server_name"]="${existing} ${tool_name}"
  fi

  _oct_info "Registered tool: $tool_name (server=$server_name, token=${token})"
  echo "$token"
}

# ── 3. oct_register_server ────────────────────────────────────────────────────
# Bulk-register all tools from an MCP server. Returns count registered.
oct_register_server() {
  local server_name="$1" port="$2"
  if [[ -z "$server_name" || -z "$port" ]]; then
    _oct_error "oct_register_server: requires <server_name> <port>"
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    _oct_error "oct_register_server: jq is required"
    return 1
  fi

  # Probe MCP tool list endpoint (MCP protocol: POST /tools/list or GET /tools)
  local tools_json
  tools_json=$(curl -sf --max-time 5 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    "http://localhost:${port}" 2>/dev/null)

  # Fallback: try GET /tools
  if [[ -z "$tools_json" ]]; then
    tools_json=$(curl -sf --max-time 5 "http://localhost:${port}/tools" 2>/dev/null)
  fi

  if [[ -z "$tools_json" ]]; then
    _oct_warn "oct_register_server: no tool list response from $server_name:$port"
    echo "0"
    return 0
  fi

  # Parse tool names — handle both MCP jsonrpc format and plain array
  local tool_names
  tool_names=$(echo "$tools_json" | jq -r '
    if .result.tools then .result.tools[].name
    elif .tools then .tools[].name
    elif type == "array" then .[].name
    else empty
    end' 2>/dev/null)

  local count=0
  while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    oct_register "$server_name" "$tool" >/dev/null
    (( count++ ))
  done <<< "$tool_names"

  _oct_info "Registered $count tools from $server_name:$port"
  echo "$count"
}

# ── 4. oct_deregister ─────────────────────────────────────────────────────────
# Mark a tool as deregistered. Keeps record for audit. Invalidates token.
oct_deregister() {
  local tool_name="$1"
  if [[ -z "$tool_name" ]]; then
    _oct_error "oct_deregister: requires <tool_name>"
    return 1
  fi
  if [[ -z "${_OCT_REGISTRY[$tool_name]+_}" ]]; then
    _oct_warn "oct_deregister: tool $tool_name not found in registry"
    return 1
  fi

  local old_token
  old_token=$(_oct_record_get "$tool_name" token)
  _oct_record_set_field "$tool_name" token "INVALIDATED_${old_token}"
  _oct_record_set_field "$tool_name" status "deregistered"
  _oct_info "Deregistered tool: $tool_name (token invalidated)"
}

# ── 5. oct_deregister_server ──────────────────────────────────────────────────
# Deregister all tools from a server (e.g., on disconnect).
oct_deregister_server() {
  local server_name="$1"
  if [[ -z "$server_name" ]]; then
    _oct_error "oct_deregister_server: requires <server_name>"
    return 1
  fi

  local tools="${_OCT_SERVER_TOOLS[$server_name]:-}"
  if [[ -z "$tools" ]]; then
    _oct_warn "oct_deregister_server: no tools found for server $server_name"
    return 0
  fi

  local count=0
  for tool in $tools; do
    oct_deregister "$tool"
    (( count++ ))
  done

  unset '_OCT_SERVER_TOOLS[$server_name]'
  _oct_info "Deregistered $count tools from server: $server_name"
  echo "$count"
}

# ── 6. oct_check ──────────────────────────────────────────────────────────────
# Check if tool is active and not stale. 0=valid, 1=stale/deregistered.
oct_check() {
  local tool_name="$1"
  if [[ -z "${_OCT_REGISTRY[$tool_name]+_}" ]]; then
    _oct_warn "oct_check: tool $tool_name not in registry"
    return 1
  fi

  local status
  status=$(_oct_record_get "$tool_name" status)

  if [[ "$status" == "deregistered" ]]; then
    _oct_warn "oct_check: tool $tool_name is deregistered"
    return 1
  fi

  if [[ "$status" == "stale" ]]; then
    _oct_warn "oct_check: tool $tool_name is stale"
    return 1
  fi

  # Check staleness by last_called time
  local last_called
  last_called=$(_oct_record_get "$tool_name" last_called)
  if [[ "$last_called" != "null" && -n "$last_called" ]]; then
    local last_epoch now_epoch age
    last_epoch=$(date -d "$last_called" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    age=$(( now_epoch - last_epoch ))
    if (( age > _OCT_STALE_SECONDS )); then
      _oct_warn "oct_check: tool $tool_name is stale (inactive for ${age}s)"
      _oct_record_set_field "$tool_name" status "stale"
      return 1
    fi
  fi

  return 0
}

# ── 7. oct_check_token ────────────────────────────────────────────────────────
# Verify token matches current registration. 0=valid, 1=invalid.
oct_check_token() {
  local tool_name="$1" token="$2"
  if [[ -z "$tool_name" || -z "$token" ]]; then
    _oct_error "oct_check_token: requires <tool_name> <token>"
    return 1
  fi

  if [[ -z "${_OCT_REGISTRY[$tool_name]+_}" ]]; then
    _oct_warn "oct_check_token: tool $tool_name not in registry — stale call detected"
    return 1
  fi

  local current_token
  current_token=$(_oct_record_get "$tool_name" token)

  if [[ "$current_token" != "$token" ]]; then
    _oct_warn "oct_check_token: token mismatch for $tool_name — stale call detected (expected=${current_token:0:8}..., got=${token:0:8}...)"
    return 1
  fi

  return 0
}

# ── 8. oct_call ───────────────────────────────────────────────────────────────
# Execute a tool call with registration check, permission check, output bounding.
oct_call() {
  local tool_name="$1" args_json="${2:-{}}"

  # Registration check
  if ! oct_check "$tool_name"; then
    _oct_error "oct_call: tool $tool_name is not active"
    return 1
  fi

  # Permission check via ocp_check if available
  if declare -f ocp_check &>/dev/null; then
    if ! ocp_check "$tool_name" "$args_json"; then
      _oct_error "oct_call: permission denied for tool $tool_name"
      return 1
    fi
  fi

  # Update call metadata
  local now call_count
  now=$(date '+%Y-%m-%dT%H:%M:%S')
  call_count=$(_oct_record_get "$tool_name" call_count)
  (( call_count++ ))
  _oct_record_set_field "$tool_name" last_called "$now"
  _oct_record_set_field "$tool_name" call_count "$call_count"

  _oct_info "oct_call: executing $tool_name (call #${call_count}, args=${args_json:0:120})"

  # Determine server and port for the call
  local server_name port
  server_name=$(_oct_record_get "$tool_name" server)
  port="${_OCT_KNOWN_SERVERS[$server_name]:-}"

  local raw_output exit_code=0
  if [[ -n "$port" ]]; then
    local payload
    payload=$(jq -n \
      --arg method "tools/call" \
      --arg tool "$tool_name" \
      --argjson args "$args_json" \
      '{"jsonrpc":"2.0","id":1,"method":$method,"params":{"name":$tool,"arguments":$args}}')

    raw_output=$(curl -sf --max-time 30 \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "http://localhost:${port}" 2>&1) || exit_code=$?
  else
    _oct_warn "oct_call: no port known for server $server_name; cannot dispatch"
    raw_output="ERROR: no port configured for server $server_name"
    exit_code=1
  fi

  # Bound output
  oct_bound_output "$raw_output" "$_OCT_DEFAULT_MAX_LINES" "$_OCT_DEFAULT_MAX_CHARS" "$tool_name"

  return $exit_code
}

# ── 9. oct_reconnect ──────────────────────────────────────────────────────────
# Handle MCP server reconnect: deregister old tools, re-probe, re-register.
oct_reconnect() {
  local server_name="$1" port="$2"
  if [[ -z "$server_name" || -z "$port" ]]; then
    _oct_error "oct_reconnect: requires <server_name> <port>"
    return 1
  fi

  _oct_info "Reconnect event for server: $server_name:$port"

  # Deregister all old tools
  oct_deregister_server "$server_name" >/dev/null

  # Update known server port (in case it changed)
  _OCT_KNOWN_SERVERS["$server_name"]="$port"

  # Re-probe and register
  local count
  count=$(oct_register_server "$server_name" "$port")
  _oct_info "Reconnect complete: $count tools re-registered for $server_name"
  echo "$count"
}

# ── 10. oct_bound_output ─────────────────────────────────────────────────────
# Bound tool output. Writes full output to file if truncated.
# Usage: oct_bound_output <output_text> <max_lines> <max_chars> [tool_name]
oct_bound_output() {
  local output="$1"
  local max_lines="${2:-$_OCT_DEFAULT_MAX_LINES}"
  local max_chars="${3:-$_OCT_DEFAULT_MAX_CHARS}"
  local tool_name="${4:-unknown}"

  local line_count char_count
  line_count=$(echo "$output" | wc -l)
  char_count=${#output}

  if (( line_count <= max_lines && char_count <= max_chars )); then
    echo "$output"
    return 0
  fi

  # Output exceeds limits — write full output to file
  local session_id="${_OCT_SESSION_ID:-default}"
  local out_dir="${_OCT_SESSIONS_DIR}/${session_id}/tool_output"
  mkdir -p "$out_dir"

  local timestamp full_path
  timestamp=$(date '+%Y%m%dT%H%M%S')
  full_path="${out_dir}/${tool_name}_${timestamp}.out"
  echo "$output" > "$full_path"

  # Truncate by whichever limit hits first
  local truncated
  truncated=$(echo "$output" | head -n "$max_lines")
  truncated="${truncated:0:$max_chars}"

  printf '%s\n' "$truncated"
  printf '\n[OCT] Output truncated (%d lines, %d chars). Full output: %s\n' \
    "$line_count" "$char_count" "$full_path"
}

# ── 11. oct_list ─────────────────────────────────────────────────────────────
# Print all registered tools in table format.
oct_list() {
  printf '%-32s %-20s %-14s %6s %s\n' "TOOL" "SERVER" "STATUS" "CALLS" "TOKEN_PREFIX"
  printf '%-32s %-20s %-14s %6s %s\n' "----" "------" "------" "-----" "------------"

  local tool
  for tool in $(echo "${!_OCT_REGISTRY[@]}" | tr ' ' '\n' | sort); do
    local server token status call_count
    server=$(_oct_record_get "$tool" server)
    token=$(_oct_record_get "$tool" token)
    status=$(_oct_record_get "$tool" status)
    call_count=$(_oct_record_get "$tool" call_count)
    local token_prefix="${token:0:8}..."
    printf '%-32s %-20s %-14s %6s %s\n' "$tool" "$server" "$status" "$call_count" "$token_prefix"
  done
}

# ── 12. oct_health ───────────────────────────────────────────────────────────
# Check health of all registered MCP servers. Returns count healthy/unhealthy.
oct_health() {
  local healthy=0 unhealthy=0

  # Build unique server set from registry
  declare -A _seen_servers=()
  local tool
  for tool in "${!_OCT_REGISTRY[@]}"; do
    local server
    server=$(_oct_record_get "$tool" server)
    _seen_servers["$server"]=1
  done

  # Also include known servers even if no tools registered yet
  for server in "${!_OCT_KNOWN_SERVERS[@]}"; do
    _seen_servers["$server"]=1
  done

  printf '%-20s %-8s %s\n' "SERVER" "PORT" "STATUS"
  printf '%-20s %-8s %s\n' "------" "----" "------"

  local server
  for server in $(echo "${!_seen_servers[@]}" | tr ' ' '\n' | sort); do
    local port="${_OCT_KNOWN_SERVERS[$server]:-unknown}"
    if [[ "$port" != "unknown" ]] && _oct_server_reachable "$server" "$port"; then
      printf '%-20s %-8s %s\n' "$server" "$port" "HEALTHY"
      (( healthy++ ))
    else
      printf '%-20s %-8s %s\n' "$server" "$port" "UNHEALTHY"
      (( unhealthy++ ))
    fi
  done

  echo ""
  echo "Healthy: $healthy  Unhealthy: $unhealthy"
  return $(( unhealthy > 0 ? 1 : 0 ))
}

# ── 13. oct_status ───────────────────────────────────────────────────────────
# Print registry state summary.
oct_status() {
  local total=0 active=0 stale=0 deregistered=0

  local tool
  for tool in "${!_OCT_REGISTRY[@]}"; do
    (( total++ ))
    local status
    status=$(_oct_record_get "$tool" status)
    case "$status" in
      active)        (( active++ )) ;;
      stale)         (( stale++ )) ;;
      deregistered)  (( deregistered++ )) ;;
    esac
  done

  echo "=== OCT Registry Status ==="
  printf '  Session ID:    %s\n' "${_OCT_SESSION_ID:-<not set>}"
  printf '  Total tools:   %d\n' "$total"
  printf '  Active:        %d\n' "$active"
  printf '  Stale:         %d\n' "$stale"
  printf '  Deregistered:  %d\n' "$deregistered"
  echo ""
  echo "=== Server Health ==="
  oct_health
}

# ── 14. oct_cleanup ──────────────────────────────────────────────────────────
# Remove deregistered tools older than 1 hour from registry.
oct_cleanup() {
  local now_epoch removed=0

  now_epoch=$(date +%s)

  local tool
  for tool in "${!_OCT_REGISTRY[@]}"; do
    local status
    status=$(_oct_record_get "$tool" status)
    [[ "$status" != "deregistered" ]] && continue

    local registered_at
    registered_at=$(_oct_record_get "$tool" registered_at)

    local reg_epoch age
    reg_epoch=$(date -d "$registered_at" +%s 2>/dev/null || echo "0")
    age=$(( now_epoch - reg_epoch ))

    if (( age > _OCT_STALE_SECONDS )); then
      # Remove from server reverse map
      local server
      server=$(_oct_record_get "$tool" server)
      if [[ -n "${_OCT_SERVER_TOOLS[$server]+_}" ]]; then
        local new_list=""
        for t in ${_OCT_SERVER_TOOLS[$server]}; do
          [[ "$t" != "$tool" ]] && new_list="${new_list} ${t}"
        done
        _OCT_SERVER_TOOLS["$server"]="${new_list# }"
      fi

      unset '_OCT_REGISTRY[$tool]'
      (( removed++ ))
      _oct_info "Cleanup: removed stale deregistered tool: $tool (age=${age}s)"
    fi
  done

  echo "Cleanup complete. Removed $removed deregistered tools."
}
