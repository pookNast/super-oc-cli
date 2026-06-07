#!/usr/bin/env bash
# oc-config.sh — Configuration loader for super-oc-cli
# Reads ~/.super-oc/config.json with jq, falls back to built-in defaults.

_OC_CFG_FILE="${SUPER_OC_HOME:-$HOME/.super-oc}/config.json"
_OC_CFG_CACHE=""

# ── Built-in defaults (used when config.json missing or field absent) ────────
_OC_CFG_DEFAULTS='{
  "home_dir": "~/.super-oc",
  "lib_dir": "~/.super-oc/lib",
  "work_dir": "~/.super-oc/workspace",
  "session_dir": "~/.super-oc/sessions",
  "config_dir": "~/.super-oc",
  "model_default": "qwen2.5:7b",
  "ollama_port": 11434,
  "gateway_port": 8400,
  "gateway_enabled": true,
  "extra_dirs": [],
  "extra_oc_flags": "",
  "skip_permissions": true,
  "mcp_enabled": true,
  "mcp_config": "~/.mcp.json",
  "mcp_servers": [],
  "model_scripts": {},
  "model_aliases": {
    "fast": "qwen2.5:7b"
  },
  "tmux_session": "oc",
  "max_output_tokens": 16384,
  "context_window": 262144,
  "auto_compact_threshold": 60,
  "node_max_old_space": 4096,
  "node_semi_space": 64,
  "uv_threadpool_size": 4,
  "max_tool_concurrency": 4,
  "openai_extra_headers": {}
}'

# ── Internal: expand ~ to $HOME ──────────────────────────────────────────────
_oc_cfg_expand() {
    local val="$1"
    echo "${val/#\~/$HOME}"
}

# ── Load config file into cache ─────────────────────────────────────────────
_oc_cfg_load() {
    local cfg_file
    cfg_file="$(_oc_cfg_expand "$_OC_CFG_FILE")"
    if [[ -f "$cfg_file" ]]; then
        _OC_CFG_CACHE=$(cat "$cfg_file")
    else
        _OC_CFG_CACHE=""
    fi
}

# ── Get a config value (dot-path, e.g. "model_default", "mcp_servers") ──────
# Returns: the value, or the built-in default if not set in user config
_oc_cfg_get() {
    local key="$1"
    local val

    # Load on first access
    [[ -z "$_OC_CFG_CACHE" ]] && _oc_cfg_load

    # Try user config first
    if [[ -n "$_OC_CFG_CACHE" ]]; then
        val=$(echo "$_OC_CFG_CACHE" | jq -r ".$key // empty" 2>/dev/null)
    fi

    # Fall back to defaults
    if [[ -z "$val" ]]; then
        val=$(echo "$_OC_CFG_DEFAULTS" | jq -r ".$key // empty" 2>/dev/null)
    fi

    # Expand ~ in path-like values
    case "$key" in
        *_dir|home_dir|mcp_config) val="$(_oc_cfg_expand "$val")" ;;
    esac

    echo "$val"
}

# ── Get a raw JSON value (for arrays/objects) ───────────────────────────────
_oc_cfg_get_json() {
    local key="$1"
    local val

    [[ -z "$_OC_CFG_CACHE" ]] && _oc_cfg_load

    if [[ -n "$_OC_CFG_CACHE" ]]; then
        val=$(echo "$_OC_CFG_CACHE" | jq ".$key // null" 2>/dev/null)
        [[ "$val" != "null" ]] && { echo "$val"; return; }
    fi

    echo "$_OC_CFG_DEFAULTS" | jq ".$key // null" 2>/dev/null
}

# ── Get a config value with explicit default ────────────────────────────────
_oc_cfg_get_or() {
    local key="$1"
    local fallback="$2"
    local val
    val=$(_oc_cfg_get "$key")
    [[ -z "$val" ]] && val="$fallback"
    echo "$val"
}

# ── Check if a boolean config is true ───────────────────────────────────────
_oc_cfg_is_true() {
    local key="$1"
    local val
    val=$(_oc_cfg_get "$key")
    [[ "$val" == "true" ]]
}

# ── Resolve the OC lib directory ────────────────────────────────────────────
_oc_cfg_lib_dir() {
    _oc_cfg_get "lib_dir"
}

# ── Resolve the working directory ───────────────────────────────────────────
_oc_cfg_work_dir() {
    _oc_cfg_get "work_dir"
}

# ── Get model start script for a given model ────────────────────────────────
_oc_cfg_model_script() {
    local model="$1"
    local script
    script=$(_oc_cfg_get_json "model_scripts" | jq -r ".\"$model\" // empty" 2>/dev/null)
    echo "$script"
}

# ── Resolve model alias ────────────────────────────────────────────────────
_oc_cfg_resolve_alias() {
    local alias="$1"
    local resolved
    resolved=$(_oc_cfg_get_json "model_aliases" | jq -r ".\"$alias\" // empty" 2>/dev/null)
    [[ -n "$resolved" ]] && echo "$resolved" || echo "$alias"
}

# ── Get extra dirs as newline-separated list ────────────────────────────────
_oc_cfg_extra_dirs() {
    _oc_cfg_get_json "extra_dirs" | jq -r '.[]' 2>/dev/null
}

# ── Get MCP servers as JSON array ───────────────────────────────────────────
_oc_cfg_mcp_servers() {
    _oc_cfg_get_json "mcp_servers"
}

# ── Detect hardware and return tuning JSON ──────────────────────────────────
_oc_detect_hardware() {
    local gpu_name="none" vram_mb=0 heap=4096 semi=64 threads=4 conc=4

    if command -v nvidia-smi &>/dev/null; then
        local gpu_info
        gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [[ -n "$gpu_info" ]]; then
            gpu_name=$(echo "$gpu_info" | cut -d',' -f1 | xargs)
            vram_mb=$(echo "$gpu_info" | cut -d',' -f2 | xargs)
            # Scale tuning by VRAM
            if (( vram_mb > 20000 )); then
                heap=8192; semi=128; threads=16; conc=8
            elif (( vram_mb > 10000 )); then
                heap=6144; semi=96; threads=8; conc=6
            elif (( vram_mb > 6000 )); then
                heap=4096; semi=64; threads=4; conc=4
            fi
        fi
    fi

    jq -n --arg gn "$gpu_name" --argjson vm "$vram_mb" \
        --argjson h "$heap" --argjson s "$semi" --argjson t "$threads" --argjson c "$conc" \
        '{gpu_name:$gn, vram_mb:$vm, node_max_old_space:$h, node_semi_space:$s, uv_threadpool_size:$t, max_tool_concurrency:$c}'
}

# ── Dump resolved config (for --dry-run / debug) ───────────────────────────
_oc_cfg_dump() {
    echo "=== super-oc-cli resolved config ==="
    echo "home_dir:       $(_oc_cfg_get home_dir)"
    echo "lib_dir:        $(_oc_cfg_get lib_dir)"
    echo "work_dir:       $(_oc_cfg_get work_dir)"
    echo "config_dir:     $(_oc_cfg_get config_dir)"
    echo "model_default:  $(_oc_cfg_get model_default)"
    echo "ollama_port:    $(_oc_cfg_get ollama_port)"
    echo "gateway_port:   $(_oc_cfg_get gateway_port)"
    echo "gateway_enabled:$(_oc_cfg_get gateway_enabled)"
    echo "mcp_enabled:    $(_oc_cfg_get mcp_enabled)"
    echo "mcp_config:     $(_oc_cfg_get mcp_config)"
    echo "mcp_servers:    $(_oc_cfg_get_json mcp_servers)"
    echo "extra_dirs:     $(_oc_cfg_get_json extra_dirs)"
    echo "tmux_session:   $(_oc_cfg_get tmux_session)"
    echo "max_output_tokens: $(_oc_cfg_get max_output_tokens)"
    echo "context_window: $(_oc_cfg_get context_window)"
    echo "node_max_old_space: $(_oc_cfg_get node_max_old_space)"
    echo "max_tool_concurrency: $(_oc_cfg_get max_tool_concurrency)"
    echo "==================================="
}
