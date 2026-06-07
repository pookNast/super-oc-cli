#!/usr/bin/env bash
# oc-routes.sh — Route-based provider abstraction for OpenClaude
#
# Inspired by OpenCode's Route<Body, Prepared> pattern.
# Provides model→route resolution, auth wiring, env export, health checks, and fallback chains.
#
# Usage: source this file, then call oc_route_init before other functions.
#
# Public API:
#   oc_route_init                        — load/validate routes.json (auto-creates default)
#   oc_route_resolve <model>             — find route name that serves this model (or alias)
#   oc_route_switch <model>              — full hot-swap: health check + env export
#   oc_route_with_fallback <model>       — switch with fallback_chain fallback
#   oc_route_list                        — print all routes and their models
#   oc_route_status                      — print current active route + model
#
# Internal helpers (also usable directly):
#   oc_route_resolve_alias <alias>       — canonical model name from alias
#   oc_route_endpoint <route>            — base URL for route
#   oc_route_auth <route>                — resolved auth token
#   oc_route_headers <route>             — headers as JSON string
#   oc_route_health_check <route>        — returns 0=healthy, 1=unhealthy
#   oc_route_export <route> <model>      — export env vars for openclaude

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

_OC_ROUTES_CONFIG="${HOME}/.openclaude/routes.json"
_OC_ROUTES_LOG="/tmp/oc-routes.log"
_OC_ROUTES_LOADED=0
_OC_CURRENT_ROUTE=""
_OC_CURRENT_MODEL=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_ocr_log() {
    local level="$1"; shift
    echo "$(date '+%Y-%m-%dT%H:%M:%S') [${level}] $*" >> "$_OC_ROUTES_LOG"
}

_oc_info()  { _ocr_log INFO  "$@"; }
_oc_warn()  { _ocr_log WARN  "$@"; echo "[oc-routes] WARN: $*" >&2; }
_oc_error() { _ocr_log ERROR "$@"; echo "[oc-routes] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Default config bootstrap
# ---------------------------------------------------------------------------

_oc_write_default_config() {
    local config_dir
    config_dir="$(dirname "$_OC_ROUTES_CONFIG")"
    mkdir -p "$config_dir"
    cat > "$_OC_ROUTES_CONFIG" <<'EOF'
{
  "routes": {
    "ollama-local": {
      "provider": "openai-compatible",
      "endpoint": "http://127.0.0.1:11434/v1",
      "auth": {"type": "static", "value": "ollama"},
      "headers": {},
      "models": ["qwopus3.6-27b-v2", "devstral-small-2:24b", "qwen3-coder:latest", "glm-flash", "gemma4-26b-a4b"]
    },
    "hivemind-gateway": {
      "provider": "openai-compatible",
      "endpoint": "http://127.0.0.1:8400/v1",
      "auth": {"type": "static", "value": "ollama"},
      "headers": {"X-HiveMind-Consumer": "openclaude"},
      "models": ["*"],
      "health": "http://127.0.0.1:8400/health"
    },
    "anthropic-api": {
      "provider": "anthropic",
      "endpoint": "https://api.anthropic.com",
      "auth": {"type": "env", "var": "ANTHROPIC_API_KEY"},
      "headers": {},
      "models": ["claude-sonnet-4-20250514", "claude-opus-4-20250514"]
    },
    "openai-api": {
      "provider": "openai",
      "endpoint": "https://api.openai.com/v1",
      "auth": {"type": "env", "var": "OPENAI_API_KEY"},
      "headers": {},
      "models": ["gpt-4o", "gpt-4o-mini"]
    }
  },
  "aliases": {
    "qwopus":   "qwopus3.6-27b-v2",
    "devstral": "devstral-small-2:24b",
    "fast":     "qwen3-coder:latest",
    "glm":      "glm-flash",
    "gemma4":   "gemma4-26b-a4b",
    "sonnet":   "claude-sonnet-4-20250514",
    "opus":     "claude-opus-4-20250514"
  },
  "fallback_chain": ["hivemind-gateway", "ollama-local"],
  "default_route": "hivemind-gateway"
}
EOF
    _oc_info "Created default routes config at $_OC_ROUTES_CONFIG"
}

# ---------------------------------------------------------------------------
# oc_route_init — load and validate routes.json
# ---------------------------------------------------------------------------

oc_route_init() {
    if [[ ! -f "$_OC_ROUTES_CONFIG" ]]; then
        _oc_warn "routes.json not found — creating default at $_OC_ROUTES_CONFIG"
        _oc_write_default_config
    fi

    if ! jq empty "$_OC_ROUTES_CONFIG" 2>/dev/null; then
        _oc_error "routes.json is invalid JSON: $_OC_ROUTES_CONFIG"
        return 1
    fi

    local route_count
    route_count=$(jq '.routes | length' "$_OC_ROUTES_CONFIG" 2>/dev/null)
    if [[ -z "$route_count" || "$route_count" -eq 0 ]]; then
        _oc_error "routes.json has no routes defined"
        return 1
    fi

    _OC_ROUTES_LOADED=1
    _oc_info "Loaded routes.json: $route_count routes"
    return 0
}

# Guard: auto-init if not already loaded
_oc_ensure_init() {
    if [[ "$_OC_ROUTES_LOADED" -ne 1 ]]; then
        oc_route_init || return 1
    fi
}

# ---------------------------------------------------------------------------
# oc_route_resolve_alias <alias> — canonical model name
# ---------------------------------------------------------------------------

oc_route_resolve_alias() {
    local alias="$1"
    _oc_ensure_init || return 1

    local canonical
    canonical=$(jq -r --arg a "$alias" '.aliases[$a] // empty' "$_OC_ROUTES_CONFIG" 2>/dev/null)
    if [[ -n "$canonical" ]]; then
        echo "$canonical"
    else
        # Not an alias — return as-is (may be a canonical model name already)
        echo "$alias"
    fi
}

# ---------------------------------------------------------------------------
# oc_route_resolve <model_or_alias> — returns route name that serves the model
# ---------------------------------------------------------------------------

oc_route_resolve() {
    local input="$1"
    _oc_ensure_init || return 1

    local model
    model=$(oc_route_resolve_alias "$input")

    # Check each route: does its models array contain the model or "*"?
    local route
    while IFS= read -r route; do
        local models_json
        models_json=$(jq -r --arg r "$route" '.routes[$r].models' "$_OC_ROUTES_CONFIG" 2>/dev/null)

        # Wildcard match
        if echo "$models_json" | jq -e 'contains(["*"])' &>/dev/null; then
            echo "$route"
            return 0
        fi

        # Exact model match
        if echo "$models_json" | jq -e --arg m "$model" 'contains([$m])' &>/dev/null; then
            echo "$route"
            return 0
        fi
    done < <(jq -r '.routes | keys[]' "$_OC_ROUTES_CONFIG" 2>/dev/null)

    # Fallback to default_route
    local default_route
    default_route=$(jq -r '.default_route // empty' "$_OC_ROUTES_CONFIG" 2>/dev/null)
    if [[ -n "$default_route" ]]; then
        _oc_warn "No explicit route for model '$model', using default: $default_route"
        echo "$default_route"
        return 0
    fi

    _oc_error "Cannot resolve route for model: $model"
    return 1
}

# ---------------------------------------------------------------------------
# oc_route_endpoint <route_name> — return base URL
# ---------------------------------------------------------------------------

oc_route_endpoint() {
    local route="$1"
    _oc_ensure_init || return 1
    jq -r --arg r "$route" '.routes[$r].endpoint // empty' "$_OC_ROUTES_CONFIG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# oc_route_auth <route_name> — resolved auth token
# ---------------------------------------------------------------------------

oc_route_auth() {
    local route="$1"
    _oc_ensure_init || return 1

    local auth_type auth_value auth_var
    auth_type=$(jq -r --arg r "$route" '.routes[$r].auth.type // "static"' "$_OC_ROUTES_CONFIG" 2>/dev/null)

    case "$auth_type" in
        static)
            auth_value=$(jq -r --arg r "$route" '.routes[$r].auth.value // ""' "$_OC_ROUTES_CONFIG" 2>/dev/null)
            echo "$auth_value"
            ;;
        env)
            auth_var=$(jq -r --arg r "$route" '.routes[$r].auth.var // ""' "$_OC_ROUTES_CONFIG" 2>/dev/null)
            if [[ -z "$auth_var" ]]; then
                _oc_error "Route '$route' has auth.type=env but no auth.var"
                return 1
            fi
            local resolved="${!auth_var}"
            if [[ -z "$resolved" ]]; then
                _oc_warn "Route '$route' auth env var '$auth_var' is unset or empty"
            fi
            echo "$resolved"
            ;;
        *)
            _oc_error "Unknown auth type '$auth_type' for route '$route'"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# oc_route_headers <route_name> — headers as JSON object string
# ---------------------------------------------------------------------------

oc_route_headers() {
    local route="$1"
    _oc_ensure_init || return 1
    jq -c --arg r "$route" '.routes[$r].headers // {}' "$_OC_ROUTES_CONFIG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# oc_route_health_check <route_name> — 0=healthy, 1=unhealthy
# ---------------------------------------------------------------------------

oc_route_health_check() {
    local route="$1"
    _oc_ensure_init || return 1

    local health_url
    health_url=$(jq -r --arg r "$route" '.routes[$r].health // empty' "$_OC_ROUTES_CONFIG" 2>/dev/null)

    if [[ -z "$health_url" ]]; then
        # No health endpoint configured — probe the base endpoint with a HEAD
        local endpoint
        endpoint=$(oc_route_endpoint "$route")
        if [[ -z "$endpoint" ]]; then
            _oc_warn "Route '$route' has no endpoint"
            return 1
        fi
        if curl -sf --max-time 3 --head "$endpoint" &>/dev/null; then
            _oc_info "Health probe (HEAD $endpoint): ok"
            return 0
        else
            _oc_warn "Health probe (HEAD $endpoint): failed"
            return 1
        fi
    fi

    if curl -sf --max-time 5 "$health_url" &>/dev/null; then
        _oc_info "Health check $health_url: ok"
        return 0
    else
        _oc_warn "Health check $health_url: failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# _oc_ollama_ensure_model <model> — check/pull Ollama model if needed
# ---------------------------------------------------------------------------

_oc_ollama_ensure_model() {
    local model="$1"
    local endpoint="${2:-http://127.0.0.1:11434}"

    # Get currently loaded model
    local running_model
    running_model=$(curl -sf --max-time 5 "${endpoint}/v1/models" 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['data'][0]['id'])" 2>/dev/null || echo "")

    if [[ "$running_model" == "$model" ]]; then
        _oc_info "Ollama model already loaded: $model"
        return 0
    fi

    _oc_info "Ollama model mismatch: running='$running_model' want='$model' — attempting pull/load"

    # Check if model exists locally
    local exists
    exists=$(curl -sf --max-time 5 "${endpoint}/api/tags" 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);names=[m['name'] for m in d.get('models',[])];print('yes' if any('${model}' in n for n in names) else 'no')" 2>/dev/null || echo "no")

    if [[ "$exists" == "no" ]]; then
        _oc_warn "Model '$model' not found locally — pulling (this may take a while)"
        curl -sf -X POST "${endpoint}/api/pull" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${model}\"}" &>/dev/null
    fi

    # Warm up the model with a dummy generate to ensure it's loaded
    curl -sf --max-time 60 -X POST "${endpoint}/api/generate" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${model}\", \"prompt\": \"hi\", \"stream\": false}" &>/dev/null

    _oc_info "Ollama model load requested: $model"
    return 0
}

# ---------------------------------------------------------------------------
# oc_route_export <route_name> <model> — export env vars for openclaude
# ---------------------------------------------------------------------------

oc_route_export() {
    local route="$1"
    local model="$2"
    _oc_ensure_init || return 1

    local provider endpoint auth headers

    provider=$(jq -r --arg r "$route" '.routes[$r].provider // "openai-compatible"' "$_OC_ROUTES_CONFIG" 2>/dev/null)
    endpoint=$(oc_route_endpoint "$route")
    auth=$(oc_route_auth "$route")
    headers=$(oc_route_headers "$route")

    case "$provider" in
        anthropic)
            export ANTHROPIC_API_KEY="$auth"
            unset OPENAI_BASE_URL
            unset OPENAI_API_KEY
            export CLAUDE_CODE_USE_OPENAI=0
            ;;
        openai | openai-compatible)
            export OPENAI_BASE_URL="$endpoint"
            export OPENAI_API_KEY="$auth"
            export CLAUDE_CODE_USE_OPENAI=1
            unset ANTHROPIC_API_KEY
            ;;
        *)
            _oc_error "Unknown provider '$provider' for route '$route'"
            return 1
            ;;
    esac

    export OPENAI_MODEL="$model"
    export OPENAI_EXTRA_HEADERS="$headers"

    _OC_CURRENT_ROUTE="$route"
    _OC_CURRENT_MODEL="$model"

    _oc_info "Exported env for route=$route model=$model provider=$provider endpoint=$endpoint"
    return 0
}

# ---------------------------------------------------------------------------
# oc_route_switch <model_or_alias> — resolve route, health check, export env
# ---------------------------------------------------------------------------

oc_route_switch() {
    local input="$1"
    _oc_ensure_init || return 1

    local model route provider

    model=$(oc_route_resolve_alias "$input")
    route=$(oc_route_resolve "$model") || return 1
    provider=$(jq -r --arg r "$route" '.routes[$r].provider // "openai-compatible"' "$_OC_ROUTES_CONFIG" 2>/dev/null)

    _oc_info "Switching to model='$model' via route='$route' provider='$provider'"

    # Health check
    if ! oc_route_health_check "$route"; then
        _oc_error "Route '$route' failed health check — switch aborted"
        return 1
    fi

    # For local Ollama, ensure model is loaded
    if [[ "$provider" == "openai-compatible" ]]; then
        local endpoint
        endpoint=$(oc_route_endpoint "$route")
        if echo "$endpoint" | grep -q "127.0.0.1:11434\|localhost:11434"; then
            _oc_ollama_ensure_model "$model" "http://127.0.0.1:11434"
        fi
    fi

    oc_route_export "$route" "$model" || return 1

    echo "[oc-routes] Active: route=$route model=$model"
    return 0
}

# ---------------------------------------------------------------------------
# oc_route_with_fallback <model_or_alias> — try fallback_chain in order
# ---------------------------------------------------------------------------

oc_route_with_fallback() {
    local input="$1"
    _oc_ensure_init || return 1

    local model
    model=$(oc_route_resolve_alias "$input")

    # Collect fallback chain
    local -a chain
    mapfile -t chain < <(jq -r '.fallback_chain[]' "$_OC_ROUTES_CONFIG" 2>/dev/null)

    if [[ "${#chain[@]}" -eq 0 ]]; then
        _oc_warn "No fallback_chain defined — falling back to direct switch"
        oc_route_switch "$input"
        return $?
    fi

    for route in "${chain[@]}"; do
        _oc_info "Fallback chain: trying route='$route' for model='$model'"

        if ! oc_route_health_check "$route"; then
            _oc_warn "Fallback chain: route '$route' unhealthy, skipping"
            continue
        fi

        # Check if route can serve this model (wildcard or explicit)
        local models_json
        models_json=$(jq -r --arg r "$route" '.routes[$r].models' "$_OC_ROUTES_CONFIG" 2>/dev/null)
        local can_serve=0
        if echo "$models_json" | jq -e 'contains(["*"])' &>/dev/null; then
            can_serve=1
        elif echo "$models_json" | jq -e --arg m "$model" 'contains([$m])' &>/dev/null; then
            can_serve=1
        fi

        if [[ "$can_serve" -eq 1 ]]; then
            oc_route_export "$route" "$model" && {
                echo "[oc-routes] Fallback active: route=$route model=$model"
                return 0
            }
        else
            _oc_warn "Fallback chain: route '$route' does not serve model '$model', skipping"
        fi
    done

    _oc_error "All fallback routes exhausted for model '$model'"
    return 1
}

# ---------------------------------------------------------------------------
# oc_route_list — print all routes and their models
# ---------------------------------------------------------------------------

oc_route_list() {
    _oc_ensure_init || return 1

    echo "=== OpenClaude Routes ==="
    while IFS= read -r route; do
        local provider endpoint models
        provider=$(jq -r --arg r "$route" '.routes[$r].provider' "$_OC_ROUTES_CONFIG")
        endpoint=$(jq -r --arg r "$route" '.routes[$r].endpoint' "$_OC_ROUTES_CONFIG")
        models=$(jq -r --arg r "$route" '.routes[$r].models | join(", ")' "$_OC_ROUTES_CONFIG")
        printf "  %-22s  %-20s  %s\n    models: %s\n" \
            "$route" "$provider" "$endpoint" "$models"
    done < <(jq -r '.routes | keys[]' "$_OC_ROUTES_CONFIG" 2>/dev/null)

    echo ""
    echo "=== Aliases ==="
    jq -r '.aliases | to_entries[] | "  \(.key) → \(.value)"' "$_OC_ROUTES_CONFIG" 2>/dev/null
    echo ""
    echo "=== Fallback Chain ==="
    jq -r '.fallback_chain | join(" → ")' "$_OC_ROUTES_CONFIG" 2>/dev/null | xargs echo " "
    echo "  default_route: $(jq -r '.default_route' "$_OC_ROUTES_CONFIG" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# oc_route_status — print current active route + model
# ---------------------------------------------------------------------------

oc_route_status() {
    if [[ -z "$_OC_CURRENT_ROUTE" ]]; then
        echo "[oc-routes] No active route (call oc_route_switch or oc_route_export first)"
    else
        echo "[oc-routes] Active route : $_OC_CURRENT_ROUTE"
        echo "[oc-routes] Active model : $_OC_CURRENT_MODEL"
    fi

    # Also reflect current env vars if set
    local base_url model use_openai
    base_url="${OPENAI_BASE_URL:-<unset>}"
    model="${OPENAI_MODEL:-<unset>}"
    use_openai="${CLAUDE_CODE_USE_OPENAI:-<unset>}"
    echo "[oc-routes] OPENAI_BASE_URL        : $base_url"
    echo "[oc-routes] OPENAI_MODEL           : $model"
    echo "[oc-routes] CLAUDE_CODE_USE_OPENAI : $use_openai"
    if [[ -n "${OPENAI_EXTRA_HEADERS:-}" ]]; then
        echo "[oc-routes] OPENAI_EXTRA_HEADERS   : $OPENAI_EXTRA_HEADERS"
    fi
}
