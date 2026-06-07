#!/usr/bin/env bash
# oc-permissions.sh — Multi-effect permission ruleset engine for OpenClaude
# Replaces basic oc_agent_check_permission from oc-agents.sh
# Source only — not executable directly

[[ -n "${_OCP_LOADED:-}" ]] && return 0
readonly _OCP_LOADED=1

# ---------------------------------------------------------------------------
# Internal constants
# ---------------------------------------------------------------------------
readonly _OCP_PERMISSIONS_FILE="${HOME}/.openclaude/permissions.json"
readonly _OCP_SESSIONS_DIR="${HOME}/.openclaude/sessions"
readonly _OCP_AUDIT_LOG="/tmp/oc-permissions-audit.jsonl"
readonly _OCP_LOG_FILE="/tmp/oc-permissions.log"
readonly _OCP_WARDEN_PORT=3005

# Runtime state (associative arrays require bash 4+)
declare -A _OCP_RULESETS=()        # agent_id -> JSON rules array (string)
declare    _OCP_DEFAULT_EFFECT="deny"
declare    _OCP_AUDIT_ENABLED=true
declare -A _OCP_DYNAMIC_RULES=()   # agent_id -> JSON rules array (dynamic additions)
declare    _OCP_SESSION_ID=""
declare    _OCP_INITIALIZED=false

# ---------------------------------------------------------------------------
# Internal logging
# ---------------------------------------------------------------------------
_ocp_log() {
    local level="$1"; shift
    printf '[%s] OCP %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >> "$_OCP_LOG_FILE"
}
_ocp_info()  { _ocp_log INFO  "$*"; }
_ocp_warn()  { _ocp_log WARN  "$*"; }
_ocp_error() { _ocp_log ERROR "$*"; }

# ---------------------------------------------------------------------------
# 1. ocp_init — load permissions.json, create default if missing
# ---------------------------------------------------------------------------
ocp_init() {
    local session_id="${1:-}"
    _OCP_SESSION_ID="${session_id:-$(date +%s%N | sha256sum | head -c 12)}"

    mkdir -p "${HOME}/.openclaude" "$_OCP_SESSIONS_DIR/${_OCP_SESSION_ID}"

    # Create default permissions.json if missing
    if [[ ! -f "$_OCP_PERMISSIONS_FILE" ]]; then
        _ocp_warn "permissions.json not found — creating default"
        cat > "$_OCP_PERMISSIONS_FILE" <<'EOF'
{
  "rulesets": {
    "explorer": {
      "rules": [
        {"action": "read/*",    "effect": "allow"},
        {"action": "grep/*",    "effect": "allow"},
        {"action": "glob/*",    "effect": "allow"},
        {"action": "bash.read", "effect": "allow"},
        {"action": "write/*",   "effect": "deny"},
        {"action": "edit/*",    "effect": "deny"},
        {"action": "bash.write","effect": "deny"}
      ]
    },
    "planner": {
      "rules": [
        {"action": "read/*",    "effect": "allow"},
        {"action": "grep/*",    "effect": "allow"},
        {"action": "glob/*",    "effect": "allow"},
        {"action": "bash.read", "effect": "allow"},
        {"action": "task/*",    "effect": "allow"},
        {"action": "write/*",   "effect": "deny"},
        {"action": "edit/*",    "effect": "deny"}
      ]
    },
    "builder": {
      "rules": [
        {"action": "*", "effect": "allow"}
      ]
    },
    "reviewer": {
      "rules": [
        {"action": "read/*",    "effect": "allow"},
        {"action": "grep/*",    "effect": "allow"},
        {"action": "glob/*",    "effect": "allow"},
        {"action": "bash/*",    "effect": "allow"},
        {"action": "task/*",    "effect": "allow"},
        {"action": "write/*",   "effect": "deny"},
        {"action": "edit/*",    "effect": "deny"}
      ]
    }
  },
  "default_effect": "deny",
  "audit_log": true
}
EOF
    fi

    # Validate structure
    if ! jq -e '.rulesets' "$_OCP_PERMISSIONS_FILE" &>/dev/null; then
        _ocp_error "permissions.json is invalid — missing .rulesets key"
        return 1
    fi

    # Load global config
    _OCP_DEFAULT_EFFECT=$(jq -r '.default_effect // "deny"' "$_OCP_PERMISSIONS_FILE")
    _OCP_AUDIT_ENABLED=$(jq -r '.audit_log // true' "$_OCP_PERMISSIONS_FILE")

    # Load rulesets into associative array
    local agents
    agents=$(jq -r '.rulesets | keys[]' "$_OCP_PERMISSIONS_FILE" 2>/dev/null)
    while IFS= read -r agent; do
        _OCP_RULESETS["$agent"]=$(jq -c ".rulesets[\"${agent}\"].rules" "$_OCP_PERMISSIONS_FILE")
    done <<< "$agents"

    # Load agent-profile allow/deny arrays from ~/.openclaude/agents/*.json
    local profile_dir="${HOME}/.openclaude/agents"
    if [[ -d "$profile_dir" ]]; then
        for profile in "$profile_dir"/*.json; do
            [[ -f "$profile" ]] || continue
            local aid
            aid=$(jq -r '.id // empty' "$profile" 2>/dev/null)
            [[ -z "$aid" ]] && continue
            # Merge profile permissions into ruleset if not already defined
            if [[ -z "${_OCP_RULESETS[$aid]:-}" ]]; then
                local allow_rules deny_rules combined
                allow_rules=$(jq -c '[.permissions.allow[]? | {"action": ., "effect": "allow"}]' "$profile" 2>/dev/null || echo "[]")
                deny_rules=$(jq -c  '[.permissions.deny[]?  | {"action": ., "effect": "deny"}]'  "$profile" 2>/dev/null || echo "[]")
                combined=$(jq -n --argjson a "$allow_rules" --argjson d "$deny_rules" '$a + $d')
                _OCP_RULESETS["$aid"]="$combined"
            fi
        done
    fi

    # Load any existing dynamic rules for this session
    local dyn_file="$_OCP_SESSIONS_DIR/${_OCP_SESSION_ID}/dynamic_permissions.json"
    if [[ -f "$dyn_file" ]]; then
        local agents_dyn
        agents_dyn=$(jq -r 'keys[]' "$dyn_file" 2>/dev/null)
        while IFS= read -r agent; do
            _OCP_DYNAMIC_RULES["$agent"]=$(jq -c ".[\"${agent}\"]" "$dyn_file")
        done <<< "$agents_dyn"
    fi

    _OCP_INITIALIZED=true
    _ocp_info "Initialized. session=$_OCP_SESSION_ID rulesets=${#_OCP_RULESETS[@]} default=$_OCP_DEFAULT_EFFECT"
    return 0
}

# ---------------------------------------------------------------------------
# 5. ocp_wildcard_match <action> <pattern>
#    Returns 0 (match) or 1 (no match)
# ---------------------------------------------------------------------------
ocp_wildcard_match() {
    local action="$1"
    local pattern="$2"

    # Exact match
    [[ "$action" == "$pattern" ]] && return 0

    # "*" matches everything
    [[ "$pattern" == "*" ]] && return 0

    # Handle double-star same as single star (recursive implied)
    pattern="${pattern//\*\*/*}"

    # Suffix wildcard: "*.write" matches "bash.write", "file.write"
    if [[ "$pattern" == \*.* ]]; then
        local suffix="${pattern#*.}"
        [[ "$action" == *".$suffix" ]] && return 0
        return 1
    fi

    # Prefix wildcard with separator: "read/*" matches "read/file", "read/dir/sub"
    if [[ "$pattern" == */* && "$pattern" == *\* ]]; then
        local prefix="${pattern%/*}"
        [[ "$action" == "${prefix}/"* || "$action" == "$prefix" ]] && return 0
        return 1
    fi

    # Dot-namespace wildcard: "bash/*" matches "bash.read", "bash.write"
    if [[ "$pattern" == *.\* ]]; then
        local ns="${pattern%.*}"
        [[ "$action" == "${ns}."* ]] && return 0
        return 1
    fi

    # Plain suffix star without separator: "bash*" matches "bash.read"
    if [[ "$pattern" == *\* ]]; then
        local pfx="${pattern%\*}"
        [[ "$action" == "${pfx}"* ]] && return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# 3. ocp_evaluate <agent_id> <action>
#    Prints effect string: allow | deny | ask | once | always | reject
# ---------------------------------------------------------------------------
ocp_evaluate() {
    local agent_id="$1"
    local action="$2"

    [[ "$_OCP_INITIALIZED" != true ]] && ocp_init

    # Collect matching rules from ruleset + dynamic rules
    local rules="[]"
    local base_rules="${_OCP_RULESETS[$agent_id]:-}"
    local dyn_rules="${_OCP_DYNAMIC_RULES[$agent_id]:-[]}"

    if [[ -n "$base_rules" ]]; then
        rules=$(jq -n --argjson b "$base_rules" --argjson d "$dyn_rules" '$b + $d')
    elif [[ "$dyn_rules" != "[]" ]]; then
        rules="$dyn_rules"
    fi

    local matched_deny=false
    local matched_allow=false
    local matched_effect="$_OCP_DEFAULT_EFFECT"
    local matched_pattern=""
    local deny_pattern=""

    local rule_count
    rule_count=$(jq 'length' <<< "$rules" 2>/dev/null || echo 0)

    for (( i=0; i<rule_count; i++ )); do
        local rule_action rule_effect
        rule_action=$(jq -r ".[$i].action" <<< "$rules")
        rule_effect=$(jq -r ".[$i].effect" <<< "$rules")

        if ocp_wildcard_match "$action" "$rule_action"; then
            case "$rule_effect" in
                deny|reject)
                    matched_deny=true
                    deny_pattern="$rule_action"
                    matched_effect="$rule_effect"
                    ;;
                allow|once|always)
                    matched_allow=true
                    [[ -z "$matched_pattern" ]] && matched_pattern="$rule_action"
                    [[ "$matched_effect" == "$_OCP_DEFAULT_EFFECT" ]] && matched_effect="$rule_effect"
                    ;;
                ask)
                    matched_allow=true
                    matched_effect="ask"
                    [[ -z "$matched_pattern" ]] && matched_pattern="$rule_action"
                    ;;
            esac
        fi
    done

    # Deny overrides all allow matches
    local final_effect
    local final_pattern
    if $matched_deny; then
        final_effect="deny"
        final_pattern="$deny_pattern"
        # "reject" is a deny variant that also triggers rejection log
        [[ "$matched_effect" == "reject" ]] && final_effect="reject"
    elif $matched_allow; then
        final_effect="$matched_effect"
        final_pattern="$matched_pattern"
    else
        final_effect="$_OCP_DEFAULT_EFFECT"
        final_pattern="(default)"
    fi

    # Handle special effects
    case "$final_effect" in
        always)
            # Promote to persistent allow rule
            ocp_grant "$agent_id" "$action" "allow"
            final_effect="allow"
            ;;
        once)
            # Return allow but flag as one-time (no caching)
            final_effect="allow"
            ;;
        reject)
            _ocp_warn "REJECTED agent=$agent_id action=$action"
            final_effect="deny"
            ;;
    esac

    # Audit log — determine source by checking if action came from dynamic rules
    local source="ruleset"
    if [[ -n "${_OCP_DYNAMIC_RULES[$agent_id]:-}" ]]; then
        # Check dynamic rules JSON array for exact action match (not substring)
        if echo "${_OCP_DYNAMIC_RULES[$agent_id]}" \
            | jq -e --arg a "$action" 'map(select(.action == $a)) | length > 0' &>/dev/null; then
            source="dynamic"
        fi
    fi
    ocp_audit_log "$agent_id" "$action" "$final_effect" "$source" "$final_pattern"

    printf '%s\n' "$final_effect"
}

# ---------------------------------------------------------------------------
# 4. ocp_check <agent_id> <action>
#    Returns 0 (allowed) or 1 (denied)
# ---------------------------------------------------------------------------
ocp_check() {
    local agent_id="$1"
    local action="$2"
    local effect
    effect=$(ocp_evaluate "$agent_id" "$action")
    case "$effect" in
        allow|ask|once) return 0 ;;
        *)              return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 6. ocp_grant <agent_id> <action> <effect>
#    Add dynamic rule at runtime
# ---------------------------------------------------------------------------
ocp_grant() {
    local agent_id="$1"
    local action="$2"
    local effect="${3:-allow}"

    local existing="${_OCP_DYNAMIC_RULES[$agent_id]:-[]}"
    local updated
    updated=$(jq -n \
        --argjson rules "$existing" \
        --arg act "$action" \
        --arg eff "$effect" \
        '$rules + [{"action": $act, "effect": $eff}]')
    _OCP_DYNAMIC_RULES["$agent_id"]="$updated"

    # Persist to session file
    local dyn_file="$_OCP_SESSIONS_DIR/${_OCP_SESSION_ID}/dynamic_permissions.json"
    local current_file="{}"
    [[ -f "$dyn_file" ]] && current_file=$(cat "$dyn_file")
    jq -n \
        --argjson base "$current_file" \
        --arg agent "$agent_id" \
        --argjson rules "$updated" \
        '$base + {($agent): $rules}' > "$dyn_file"

    _ocp_info "GRANT agent=$agent_id action=$action effect=$effect"
}

# ---------------------------------------------------------------------------
# 7. ocp_revoke <agent_id> <action>
#    Remove a dynamic rule
# ---------------------------------------------------------------------------
ocp_revoke() {
    local agent_id="$1"
    local action="$2"

    local existing="${_OCP_DYNAMIC_RULES[$agent_id]:-[]}"
    local updated
    updated=$(echo "$existing" | jq --arg act "$action" \
        '[.[] | select(.action != $act)]')
    _OCP_DYNAMIC_RULES["$agent_id"]="$updated"

    local dyn_file="$_OCP_SESSIONS_DIR/${_OCP_SESSION_ID}/dynamic_permissions.json"
    if [[ -f "$dyn_file" ]]; then
        local current_file
        current_file=$(cat "$dyn_file")
        jq -n \
            --argjson base "$current_file" \
            --arg agent "$agent_id" \
            --argjson rules "$updated" \
            '$base + {($agent): $rules}' > "$dyn_file"
    fi

    _ocp_info "REVOKE agent=$agent_id action=$action"
}

# ---------------------------------------------------------------------------
# 8. ocp_audit_log <agent_id> <action> <effect> <source> [rule_pattern]
# ---------------------------------------------------------------------------
ocp_audit_log() {
    local agent_id="$1"
    local action="$2"
    local effect="$3"
    local source="${4:-unknown}"
    local rule_pattern="${5:-(none)}"

    [[ "$_OCP_AUDIT_ENABLED" != "true" ]] && return 0

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"timestamp":"%s","agent":"%s","action":"%s","effect":"%s","source":"%s","rule_pattern":"%s"}\n' \
        "$ts" "$agent_id" "$action" "$effect" "$source" "$rule_pattern" \
        >> "$_OCP_AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# 9. ocp_warden_check <agent_id> <action>
#    Route through warden-mcp on port 3005 if available
# ---------------------------------------------------------------------------
ocp_warden_check() {
    local agent_id="$1"
    local action="$2"

    # Probe warden availability (fast timeout)
    if curl -sf --max-time 1 "http://localhost:${_OCP_WARDEN_PORT}/health" &>/dev/null; then
        local payload
        payload=$(jq -n --arg a "$agent_id" --arg act "$action" \
            '{"agent_id": $a, "action": $act}')
        local response
        response=$(curl -sf --max-time 3 \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "http://localhost:${_OCP_WARDEN_PORT}/check" 2>/dev/null)

        if [[ -n "$response" ]]; then
            local warden_effect
            warden_effect=$(jq -r '.effect // empty' <<< "$response" 2>/dev/null)
            if [[ -n "$warden_effect" ]]; then
                _ocp_info "WARDEN agent=$agent_id action=$action effect=$warden_effect"
                ocp_audit_log "$agent_id" "$action" "$warden_effect" "warden"
                printf '%s\n' "$warden_effect"
                return 0
            fi
        fi
        _ocp_warn "Warden returned invalid response — falling back to local"
    fi

    # Fallback to local evaluation
    ocp_evaluate "$agent_id" "$action"
}

# ---------------------------------------------------------------------------
# 10. ocp_list_rules <agent_id>
#     Print all rules in table format
# ---------------------------------------------------------------------------
ocp_list_rules() {
    local agent_id="$1"

    printf '%-40s %-10s %-10s\n' "ACTION" "EFFECT" "SOURCE"
    printf '%s\n' "$(printf '%.0s-' {1..62})"

    local base_rules="${_OCP_RULESETS[$agent_id]:-[]}"
    local rule_count
    rule_count=$(jq 'length' <<< "$base_rules" 2>/dev/null || echo 0)

    for (( i=0; i<rule_count; i++ )); do
        local ra re
        ra=$(jq -r ".[$i].action" <<< "$base_rules")
        re=$(jq -r ".[$i].effect" <<< "$base_rules")
        printf '%-40s %-10s %-10s\n' "$ra" "$re" "ruleset"
    done

    local dyn_rules="${_OCP_DYNAMIC_RULES[$agent_id]:-[]}"
    local dyn_count
    dyn_count=$(jq 'length' <<< "$dyn_rules" 2>/dev/null || echo 0)

    for (( i=0; i<dyn_count; i++ )); do
        local da de
        da=$(jq -r ".[$i].action" <<< "$dyn_rules")
        de=$(jq -r ".[$i].effect" <<< "$dyn_rules")
        printf '%-40s %-10s %-10s\n' "$da" "$de" "dynamic"
    done

    if [[ $rule_count -eq 0 && $dyn_count -eq 0 ]]; then
        printf '(no rules found for agent: %s)\n' "$agent_id"
    fi
}

# ---------------------------------------------------------------------------
# 11. ocp_status — print permission system state
# ---------------------------------------------------------------------------
ocp_status() {
    local audit_size=0
    [[ -f "$_OCP_AUDIT_LOG" ]] && audit_size=$(wc -l < "$_OCP_AUDIT_LOG")

    local dyn_total=0
    for agent in "${!_OCP_DYNAMIC_RULES[@]}"; do
        local cnt
        cnt=$(jq 'length' <<< "${_OCP_DYNAMIC_RULES[$agent]}" 2>/dev/null || echo 0)
        (( dyn_total += cnt ))
    done

    printf '=== OCP Permission System Status ===\n'
    printf 'Initialized  : %s\n' "$_OCP_INITIALIZED"
    printf 'Session ID   : %s\n' "$_OCP_SESSION_ID"
    printf 'Permissions  : %s\n' "$_OCP_PERMISSIONS_FILE"
    printf 'Default effect: %s\n' "$_OCP_DEFAULT_EFFECT"
    printf 'Audit enabled: %s\n' "$_OCP_AUDIT_ENABLED"
    printf '\nLoaded rulesets (%d):\n' "${#_OCP_RULESETS[@]}"
    for agent in "${!_OCP_RULESETS[@]}"; do
        local cnt
        cnt=$(jq 'length' <<< "${_OCP_RULESETS[$agent]}" 2>/dev/null || echo '?')
        printf '  %-20s %s rules\n' "$agent" "$cnt"
    done

    printf '\nDynamic rules: %d total across %d agents\n' "$dyn_total" "${#_OCP_DYNAMIC_RULES[@]}"
    printf 'Audit log    : %s (%d entries)\n' "$_OCP_AUDIT_LOG" "$audit_size"
}
