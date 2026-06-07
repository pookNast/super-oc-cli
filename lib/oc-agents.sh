#!/usr/bin/env bash
# oc-agents.sh — Agent profile management library for OpenClaude
#
# Manages agent profiles stored as JSON in ~/.openclaude/agents/.
# Provides registry init, profile loading, permission checking, @mention resolution,
# agent handoff, budget tracking, and CLI arg parsing.
#
# Usage: source this file, then call oc_agent_init to build the registry.
#
# Dependencies: jq
# Logs: /tmp/oc-agents.log
#
# Public API:
#   oc_agent_init                        — scan agents dir, build registry
#   oc_agent_load <agent_id>             — load profile into module vars
#   oc_agent_list                        — print table of registered agents
#   oc_agent_select <agent_id>           — load + switch model + export system prompt
#   oc_agent_check_permission <action>   — 0=allowed, 1=denied
#   oc_agent_resolve_mention <text>      — return agent_id from @mention in text
#   oc_agent_handoff <from> <to>         — log + select new agent + journal event
#   oc_agent_check_budget                — 0=budget remaining, 1=exhausted
#   oc_agent_status                      — print current agent state
#   oc_agent_from_cli <args...>          — parse --agent <name> from CLI args

# ── Source guard ────────────────────────────────────────────────────────────────
[[ -n "${_OC_AGENTS_LOADED:-}" ]] && return 0
readonly _OC_AGENTS_LOADED=1

# ── Constants ───────────────────────────────────────────────────────────────────
_OCA_LOG_FILE="/tmp/oc-agents.log"
_OCA_AGENTS_DIR="${HOME}/.openclaude/agents"
_OCA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Internal registry (associative arrays) ──────────────────────────────────────
declare -A _OCA_REGISTRY_MODE=()
declare -A _OCA_REGISTRY_MODEL=()
declare -A _OCA_REGISTRY_DESCRIPTION=()
declare -A _OCA_REGISTRY_SYSTEM=()
declare -A _OCA_REGISTRY_STEPS=()
declare -A _OCA_REGISTRY_ALLOW=()
declare -A _OCA_REGISTRY_DENY=()
declare -a _OCA_REGISTRY_IDS=()

# ── Current agent state ──────────────────────────────────────────────────────────
_OCA_CURRENT_ID=""
_OCA_CURRENT_MODE=""
_OCA_CURRENT_MODEL=""
_OCA_CURRENT_SYSTEM=""
_OCA_CURRENT_STEPS=0
_OCA_CURRENT_DESCRIPTION=""
declare -a _OCA_CURRENT_ALLOW=()
declare -a _OCA_CURRENT_DENY=()

# ── Logging ─────────────────────────────────────────────────────────────────────
_oca_log() {
    local level="$1"; shift
    printf '[%s] [OCA] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$level" "$*" \
        >> "${_OCA_LOG_FILE}"
}
_oca_info()  { _oca_log "INFO"  "$@"; }
_oca_warn()  { _oca_log "WARN"  "$@"; }
_oca_error() { _oca_log "ERROR" "$@"; }

# ── Internal helpers ─────────────────────────────────────────────────────────────

# Parse a JSON array field from a file into a bash array (newline-separated values)
_oca_json_array() {
    local file="$1" field="$2"
    jq -r "${field}[]? // empty" "$file" 2>/dev/null
}

# Check if a single action matches a permission pattern (supports * and prefix/*)
_oca_match_pattern() {
    local action="$1" pattern="$2"
    if [[ "$pattern" == "*" ]]; then
        return 0
    fi
    if [[ "$pattern" == *"/*" ]]; then
        local prefix="${pattern%/*}"
        if [[ "$action" == "${prefix}/"* || "$action" == "${prefix}" ]]; then
            return 0
        fi
    fi
    if [[ "$action" == "$pattern" ]]; then
        return 0
    fi
    return 1
}

# ── 1. oc_agent_init ─────────────────────────────────────────────────────────────
# Scan ~/.openclaude/agents/ for JSON files, build in-memory registry.
oc_agent_init() {
    _OCA_REGISTRY_IDS=()

    if [[ ! -d "$_OCA_AGENTS_DIR" ]]; then
        _oca_warn "Agents directory not found: $_OCA_AGENTS_DIR"
        return 1
    fi

    local count=0
    for json_file in "${_OCA_AGENTS_DIR}"/*.json; do
        [[ -f "$json_file" ]] || continue

        local id
        id="$(jq -r '.id // empty' "$json_file" 2>/dev/null)"
        [[ -z "$id" ]] && { _oca_warn "Skipping $json_file — missing .id field"; continue; }

        _OCA_REGISTRY_MODE["$id"]="$(jq -r '.mode // "primary"' "$json_file")"
        _OCA_REGISTRY_MODEL["$id"]="$(jq -r '.model // ""' "$json_file")"
        _OCA_REGISTRY_DESCRIPTION["$id"]="$(jq -r '.description // ""' "$json_file")"
        _OCA_REGISTRY_SYSTEM["$id"]="$(jq -r '.system // ""' "$json_file")"
        _OCA_REGISTRY_STEPS["$id"]="$(jq -r '.steps // 10' "$json_file")"
        _OCA_REGISTRY_ALLOW["$id"]="$(jq -r '[.permissions.allow[]? // empty] | join("\n")' "$json_file" 2>/dev/null)"
        _OCA_REGISTRY_DENY["$id"]="$(jq -r '[.permissions.deny[]? // empty] | join("\n")' "$json_file" 2>/dev/null)"

        _OCA_REGISTRY_IDS+=("$id")
        (( count++ ))
        _oca_info "Registered agent: $id (model=${_OCA_REGISTRY_MODEL[$id]}, mode=${_OCA_REGISTRY_MODE[$id]})"
    done

    _oca_info "oc_agent_init complete — $count agent(s) loaded"
    return 0
}

# ── 2. oc_agent_load <agent_id> ──────────────────────────────────────────────────
# Load a specific agent into module-level vars. Returns 1 if not found.
oc_agent_load() {
    local agent_id="$1"

    if [[ -z "${_OCA_REGISTRY_MODEL[$agent_id]+_}" ]]; then
        _oca_error "Agent not found in registry: $agent_id"
        return 1
    fi

    _OCA_CURRENT_ID="$agent_id"
    _OCA_CURRENT_MODE="${_OCA_REGISTRY_MODE[$agent_id]}"
    _OCA_CURRENT_MODEL="${_OCA_REGISTRY_MODEL[$agent_id]}"
    _OCA_CURRENT_SYSTEM="${_OCA_REGISTRY_SYSTEM[$agent_id]}"
    _OCA_CURRENT_STEPS="${_OCA_REGISTRY_STEPS[$agent_id]}"
    _OCA_CURRENT_DESCRIPTION="${_OCA_REGISTRY_DESCRIPTION[$agent_id]}"

    # Parse permission arrays
    _OCA_CURRENT_ALLOW=()
    while IFS= read -r perm; do
        [[ -n "$perm" ]] && _OCA_CURRENT_ALLOW+=("$perm")
    done <<< "${_OCA_REGISTRY_ALLOW[$agent_id]}"

    _OCA_CURRENT_DENY=()
    while IFS= read -r perm; do
        [[ -n "$perm" ]] && _OCA_CURRENT_DENY+=("$perm")
    done <<< "${_OCA_REGISTRY_DENY[$agent_id]}"

    _oca_info "Loaded agent: $agent_id (model=$_OCA_CURRENT_MODEL, steps=$_OCA_CURRENT_STEPS)"
    return 0
}

# ── 3. oc_agent_list ─────────────────────────────────────────────────────────────
# Print all registered agents in table format.
oc_agent_list() {
    if [[ ${#_OCA_REGISTRY_IDS[@]} -eq 0 ]]; then
        echo "No agents registered. Run oc_agent_init first."
        return 1
    fi

    printf '%-16s %-10s %-36s %-6s\n' "ID" "MODE" "MODEL" "STEPS"
    printf '%-16s %-10s %-36s %-6s\n' "────────────────" "──────────" "────────────────────────────────────" "──────"
    local id
    for id in "${_OCA_REGISTRY_IDS[@]}"; do
        local tag=""
        [[ "${_OCA_REGISTRY_MODE[$id]}" == "primary" ]] && tag=" [P]" || tag=" [S]"
        printf '%-16s %-10s %-36s %-6s\n' \
            "${id}${tag}" \
            "${_OCA_REGISTRY_MODE[$id]}" \
            "${_OCA_REGISTRY_MODEL[$id]}" \
            "${_OCA_REGISTRY_STEPS[$id]}"
    done
    echo ""
    echo "Legend: [P]=primary  [S]=subagent"
}

# ── 4. oc_agent_select <agent_id> ────────────────────────────────────────────────
# Load agent, switch model via oc-routes, export system prompt, log transition.
oc_agent_select() {
    local agent_id="$1"
    local prev_id="${_OCA_CURRENT_ID:-none}"

    oc_agent_load "$agent_id" || return 1

    # Source oc-routes if not already loaded
    if ! declare -f oc_route_switch &>/dev/null; then
        local routes_lib="${_OCA_LIB_DIR}/oc-routes.sh"
        if [[ -f "$routes_lib" ]]; then
            # shellcheck source=/dev/null
            source "$routes_lib"
            _oca_info "Sourced oc-routes.sh"
        else
            _oca_warn "oc-routes.sh not found at $routes_lib — skipping model switch"
        fi
    fi

    # Switch model route
    if declare -f oc_route_switch &>/dev/null; then
        if oc_route_switch "$_OCA_CURRENT_MODEL"; then
            _oca_info "Route switched to model: $_OCA_CURRENT_MODEL"
        else
            _oca_warn "oc_route_switch failed for model: $_OCA_CURRENT_MODEL (continuing)"
        fi
    fi

    # Export system prompt
    export OC_AGENT_SYSTEM_PROMPT="${_OCA_CURRENT_SYSTEM}"

    _oca_info "Agent selected: $prev_id → $agent_id (model=$_OCA_CURRENT_MODEL)"
    return 0
}

# ── 5. oc_agent_check_permission <action> ────────────────────────────────────────
# Returns 0=allowed, 1=denied. Deny list is checked first.
oc_agent_check_permission() {
    local action="$1"

    if [[ -z "$_OCA_CURRENT_ID" ]]; then
        _oca_warn "oc_agent_check_permission called with no agent loaded"
        return 1
    fi

    # Check deny list first (deny overrides allow)
    local perm
    for perm in "${_OCA_CURRENT_DENY[@]}"; do
        if _oca_match_pattern "$action" "$perm"; then
            _oca_info "Permission DENIED: $action matches deny pattern '$perm'"
            return 1
        fi
    done

    # Check allow list
    for perm in "${_OCA_CURRENT_ALLOW[@]}"; do
        if _oca_match_pattern "$action" "$perm"; then
            _oca_info "Permission ALLOWED: $action matches allow pattern '$perm'"
            return 0
        fi
    done

    # Default deny if nothing matched
    _oca_info "Permission DENIED (no matching allow): $action"
    return 1
}

# ── 6. oc_agent_resolve_mention <prompt_text> ────────────────────────────────────
# Scan prompt for @agent_name patterns. Return first matching agent_id, or empty.
oc_agent_resolve_mention() {
    local prompt_text="$1"

    local id
    for id in "${_OCA_REGISTRY_IDS[@]}"; do
        # Match @id as a whole word (not followed by alphanumeric/_)
        if [[ "$prompt_text" =~ @${id}([^a-zA-Z0-9_]|$) ]]; then
            printf '%s\n' "$id"
            return 0
        fi
    done

    # Return empty string — no match
    printf ''
    return 0
}

# ── 7. oc_agent_handoff <from_agent> <to_agent> ──────────────────────────────────
# Log transition, call oc_agent_select, write handoff event to epoch journal.
oc_agent_handoff() {
    local from_agent="$1"
    local to_agent="$2"

    _oca_info "Handoff initiated: $from_agent → $to_agent"

    oc_agent_select "$to_agent" || {
        _oca_error "Handoff failed: could not select agent '$to_agent'"
        return 1
    }

    local event_payload
    event_payload="$(printf '{"event":"agent_handoff","from":"%s","to":"%s","ts":"%s"}' \
        "$from_agent" "$to_agent" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"

    # Write to epoch journal if oc_epoch_record is available
    if declare -f oc_epoch_record &>/dev/null; then
        oc_epoch_record "agent_handoff" "$event_payload"
        _oca_info "Handoff event recorded to epoch journal"
    else
        _oca_info "oc_epoch_record not available — handoff event: $event_payload"
    fi

    return 0
}

# ── 8. oc_agent_check_budget ─────────────────────────────────────────────────────
# Compare current agent's step budget against engine's _OC_CURRENT_STEP.
# Returns 0=budget remaining, 1=exhausted.
oc_agent_check_budget() {
    if [[ -z "$_OCA_CURRENT_ID" ]]; then
        _oca_warn "oc_agent_check_budget called with no agent loaded"
        return 1
    fi

    local current_step="${_OC_CURRENT_STEP:-0}"
    local budget="${_OCA_CURRENT_STEPS:-0}"

    if (( current_step < budget )); then
        _oca_info "Budget remaining: step $current_step / $budget for agent $_OCA_CURRENT_ID"
        return 0
    else
        _oca_warn "Budget exhausted: step $current_step >= $budget for agent $_OCA_CURRENT_ID"
        return 1
    fi
}

# ── 9. oc_agent_status ───────────────────────────────────────────────────────────
# Print current agent state summary.
oc_agent_status() {
    if [[ -z "$_OCA_CURRENT_ID" ]]; then
        echo "No agent currently loaded."
        return 1
    fi

    local current_step="${_OC_CURRENT_STEP:-0}"
    echo "────────────────────────────────────"
    echo "  Current Agent:  $_OCA_CURRENT_ID"
    echo "  Mode:           $_OCA_CURRENT_MODE"
    echo "  Model:          $_OCA_CURRENT_MODEL"
    echo "  Description:    $_OCA_CURRENT_DESCRIPTION"
    echo "  Step Budget:    $current_step / $_OCA_CURRENT_STEPS"
    echo "  System Prompt:  ${_OCA_CURRENT_SYSTEM:0:80}..."
    echo "  Allow:          ${_OCA_CURRENT_ALLOW[*]:-<none>}"
    echo "  Deny:           ${_OCA_CURRENT_DENY[*]:-<none>}"
    echo "  OC_AGENT_SYSTEM_PROMPT exported: $([[ -n "${OC_AGENT_SYSTEM_PROMPT:-}" ]] && echo yes || echo no)"
    echo "────────────────────────────────────"
}

# ── 10. oc_agent_from_cli <args...> ──────────────────────────────────────────────
# Parse --agent <name> from CLI args. Calls oc_agent_select if found.
oc_agent_from_cli() {
    local args=("$@")
    local i
    for (( i=0; i<${#args[@]}; i++ )); do
        if [[ "${args[$i]}" == "--agent" ]]; then
            local next=$(( i + 1 ))
            if [[ $next -lt ${#args[@]} ]]; then
                local agent_name="${args[$next]}"
                _oca_info "CLI --agent flag detected: $agent_name"
                oc_agent_select "$agent_name"
                return $?
            else
                _oca_error "--agent flag provided but no agent name followed"
                return 1
            fi
        fi
    done
    # No --agent flag found — not an error
    return 0
}
