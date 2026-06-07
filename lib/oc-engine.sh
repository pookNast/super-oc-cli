#!/usr/bin/env bash
# oc-engine.sh — Bounded agentic step loop engine for OpenClaude
#
# Implements a multi-phase agent pipeline with step budgets, needsContinuation
# detection, overflow/compaction handling, and clean interruption support.
#
# Pipeline: Research (15 steps) → Plan (10) → Implement (30) → Verify (10)
#
# Usage: source this file from oc-start, then call:
#   oc_engine_init <session_id> [pipeline_config_path]
#   oc_engine_run
#
# Dependencies: jq, openclaude (in PATH), tmux (optional)
# Logs: /tmp/oc-engine.log
# State: ~/.openclaude/sessions/<session_id>/state.json

# ── Constants ──────────────────────────────────────────────────────────────────
OC_ENGINE_VERSION="1.0.0"
OC_LOG="/tmp/oc-engine.log"
OC_BASE_DIR="${HOME}/.openclaude"
OC_SESSIONS_DIR="${OC_BASE_DIR}/sessions"
OC_AGENTS_DIR="${OC_BASE_DIR}/agents"
OC_DEFAULT_PIPELINE="${OC_BASE_DIR}/pipeline.json"
OC_CONTINUATION_MARKER="__OC_CONTINUE__"
OC_MAX_RETRIES_DEFAULT=2
OC_OVERFLOW_THRESHOLD_DEFAULT="0.8"
OC_CONTEXT_WINDOW_DEFAULT=262144

# ── Internal state (module-level variables) ────────────────────────────────────
_OC_SESSION_ID=""
_OC_PIPELINE_CONFIG=""
_OC_STATE_FILE=""
_OC_CURRENT_PHASE_IDX=0
_OC_CURRENT_STEP=0
_OC_TOTAL_STEPS=0
_OC_PHASES_COMPLETED=()
_OC_STARTED_AT=""
_OC_INTERRUPTED=false
_OC_PHASE_NAME=""
_OC_PHASE_AGENT=""
_OC_PHASE_MAX_STEPS=0
_OC_MAX_RETRIES=2
_OC_OVERFLOW_THRESHOLD="0.8"
_OC_CONTEXT_WINDOW=262144

# ── Logging ────────────────────────────────────────────────────────────────────

_oc_log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local phase_ctx="${_OC_PHASE_NAME:-none}"
    local step_ctx="${_OC_CURRENT_STEP}/${_OC_PHASE_MAX_STEPS}"
    printf '[%s] [%s] [phase:%s step:%s] %s\n' \
        "$ts" "$level" "$phase_ctx" "$step_ctx" "$msg" >> "$OC_LOG"
    # Echo INFO/WARN/ERROR to stderr so callers see it
    if [[ "$level" != "DEBUG" ]]; then
        printf '[oc-engine] [%s] %s\n' "$level" "$msg" >&2
    fi
}

_oc_log_debug() { _oc_log "DEBUG" "$@"; }
_oc_log_info()  { _oc_log "INFO"  "$@"; }
_oc_log_warn()  { _oc_log "WARN"  "$@"; }
_oc_log_error() { _oc_log "ERROR" "$@"; }

# ── Interruption handling ──────────────────────────────────────────────────────

_oc_trap_interrupt() {
    _OC_INTERRUPTED=true
    _oc_log_warn "Interrupt signal received — initiating clean shutdown"
    oc_engine_interrupt
}

_oc_setup_traps() {
    trap '_oc_trap_interrupt' SIGINT SIGTERM
}

# ── State persistence ──────────────────────────────────────────────────────────

_oc_state_dir() {
    echo "${OC_SESSIONS_DIR}/${_OC_SESSION_ID}"
}

_oc_ensure_dirs() {
    mkdir -p "$(_oc_state_dir)" "$OC_AGENTS_DIR" 2>/dev/null
}

_oc_write_state() {
    [[ -z "$_OC_STATE_FILE" ]] && return 1
    local last_step_at
    last_step_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Build phases_completed JSON array
    local phases_json="[]"
    if [[ ${#_OC_PHASES_COMPLETED[@]} -gt 0 ]]; then
        phases_json="$(printf '%s\n' "${_OC_PHASES_COMPLETED[@]}" \
            | jq -R . | jq -s .)"
    fi

    jq -n \
        --arg session_id    "$_OC_SESSION_ID" \
        --arg current_phase "$_OC_PHASE_NAME" \
        --argjson current_step  "$_OC_CURRENT_STEP" \
        --argjson max_steps     "$_OC_PHASE_MAX_STEPS" \
        --argjson phase_idx     "$_OC_CURRENT_PHASE_IDX" \
        --argjson phases_completed "$phases_json" \
        --argjson total_steps   "$_OC_TOTAL_STEPS" \
        --arg started_at    "$_OC_STARTED_AT" \
        --arg last_step_at  "$last_step_at" \
        --arg version       "$OC_ENGINE_VERSION" \
        '{
            session_id:        $session_id,
            current_phase:     $current_phase,
            current_phase_idx: $phase_idx,
            current_step:      $current_step,
            max_steps:         $max_steps,
            phases_completed:  $phases_completed,
            total_steps:       $total_steps,
            started_at:        $started_at,
            last_step_at:      $last_step_at,
            engine_version:    $version
        }' > "$_OC_STATE_FILE"

    _oc_log_debug "State written to $_OC_STATE_FILE"
}

_oc_load_state() {
    [[ ! -f "$_OC_STATE_FILE" ]] && return 1
    _OC_CURRENT_PHASE_IDX=$(jq -r '.current_phase_idx // 0' "$_OC_STATE_FILE")
    _OC_CURRENT_STEP=$(jq -r '.current_step // 0' "$_OC_STATE_FILE")
    _OC_TOTAL_STEPS=$(jq -r '.total_steps // 0' "$_OC_STATE_FILE")
    _OC_STARTED_AT=$(jq -r '.started_at // ""' "$_OC_STATE_FILE")
    # Restore phases_completed array
    mapfile -t _OC_PHASES_COMPLETED < <(jq -r '.phases_completed[]? // empty' "$_OC_STATE_FILE")
    _oc_log_info "State restored from $_OC_STATE_FILE (phase_idx=$_OC_CURRENT_PHASE_IDX, step=$_OC_CURRENT_STEP)"
    return 0
}

# ── Pipeline / agent config helpers ───────────────────────────────────────────

_oc_load_pipeline() {
    local config_path="$1"
    if [[ ! -f "$config_path" ]]; then
        _oc_log_warn "Pipeline config not found at $config_path — writing default"
        _oc_write_default_pipeline "$config_path"
    fi
    _OC_PIPELINE_CONFIG="$config_path"

    # Load global settings
    _OC_MAX_RETRIES=$(jq -r '.max_retries // 2' "$config_path")
    _OC_OVERFLOW_THRESHOLD=$(jq -r '.overflow_threshold // 0.8' "$config_path")
    _OC_CONTEXT_WINDOW=$(jq -r '.context_window // 262144' "$config_path")
    _oc_log_debug "Pipeline loaded: retries=$_OC_MAX_RETRIES overflow_threshold=$_OC_OVERFLOW_THRESHOLD"
}

_oc_write_default_pipeline() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
{
  "phases": [
    {"name": "research",   "agent": "explorer", "steps": 15},
    {"name": "plan",       "agent": "planner",  "steps": 10},
    {"name": "implement",  "agent": "builder",  "steps": 30},
    {"name": "verify",     "agent": "reviewer", "steps": 10}
  ],
  "max_retries": 2,
  "overflow_threshold": 0.8,
  "context_window": 262144
}
EOF
    _oc_log_info "Default pipeline written to $path"
}

_oc_phase_count() {
    jq '.phases | length' "$_OC_PIPELINE_CONFIG"
}

_oc_load_phase() {
    local idx="$1"
    _OC_PHASE_NAME=$(jq -r ".phases[$idx].name  // \"unknown\"" "$_OC_PIPELINE_CONFIG")
    _OC_PHASE_AGENT=$(jq -r ".phases[$idx].agent // \"default\"" "$_OC_PIPELINE_CONFIG")
    _OC_PHASE_MAX_STEPS=$(jq -r ".phases[$idx].steps // 10" "$_OC_PIPELINE_CONFIG")
    _OC_CURRENT_STEP=0
    _oc_log_info "Phase loaded: [$idx] $_OC_PHASE_NAME agent=$_OC_PHASE_AGENT max_steps=$_OC_PHASE_MAX_STEPS"
}

_oc_load_agent_profile() {
    local agent_name="$1"
    local agent_file="${OC_AGENTS_DIR}/${agent_name}.json"
    if [[ -f "$agent_file" ]]; then
        _oc_log_debug "Agent profile loaded: $agent_file"
        echo "$agent_file"
    else
        _oc_log_warn "Agent profile not found: $agent_file — using defaults"
        echo ""
    fi
}

# ── Route / model switching ────────────────────────────────────────────────────

_oc_switch_model() {
    local agent_name="$1"
    local agent_file
    agent_file="$(_oc_load_agent_profile "$agent_name")"

    local model=""
    if [[ -n "$agent_file" ]]; then
        model=$(jq -r '.model // ""' "$agent_file" 2>/dev/null)
    fi

    # Source oc-routes if available
    local routes_lib
    routes_lib="$(dirname "${BASH_SOURCE[0]}")/oc-routes.sh"
    if [[ -f "$routes_lib" ]]; then
        # shellcheck source=/dev/null
        source "$routes_lib"
        if declare -f oc_route_model &>/dev/null; then
            oc_route_model "$agent_name" "$model"
            _oc_log_debug "Model routed via oc-routes.sh for agent=$agent_name"
            return 0
        fi
    fi

    # Fallback: export OC_MODEL for openclaude to pick up
    if [[ -n "$model" ]]; then
        export OC_MODEL="$model"
        _oc_log_info "OC_MODEL set to '$model' for agent $agent_name"
    fi
}

# ── Overflow / compaction detection ───────────────────────────────────────────

_oc_check_overflow() {
    local session_dir
    session_dir="$(_oc_state_dir)"
    local token_file="${session_dir}/token_count"

    # If openclaude writes a token count file, check it
    if [[ -f "$token_file" ]]; then
        local current_tokens
        current_tokens=$(cat "$token_file" 2>/dev/null || echo "0")
        local threshold
        threshold=$(awk "BEGIN { printf \"%d\", $_OC_CONTEXT_WINDOW * $_OC_OVERFLOW_THRESHOLD }")
        if (( current_tokens >= threshold )); then
            _oc_log_warn "Token overflow: $current_tokens >= $threshold — compaction needed"
            return 0  # overflow detected
        fi
    fi
    return 1  # no overflow
}

_oc_trigger_compaction() {
    _oc_log_info "Triggering context compaction via --resume --compact"
    export OC_COMPACT="1"
    # oc_engine_step will pass --resume when OC_COMPACT is set
}

# ── needsContinuation detection ───────────────────────────────────────────────

_oc_needs_continuation() {
    local exit_code="$1"
    local output_file="$2"

    # Non-zero exit: error, not continuation
    if (( exit_code != 0 )); then
        return 1
    fi

    # Check output for continuation marker
    if [[ -f "$output_file" ]] && grep -qF "$OC_CONTINUATION_MARKER" "$output_file"; then
        _oc_log_debug "Continuation marker found in output"
        return 0  # needs continuation
    fi

    # Check for pending tool call indicators
    if [[ -f "$output_file" ]] && grep -qE '"type"\s*:\s*"tool_use"' "$output_file"; then
        _oc_log_debug "Pending tool_use detected in output"
        return 0
    fi

    return 1  # phase complete (exit 0, no continuation)
}

# ── Core step execution ────────────────────────────────────────────────────────

oc_engine_step() {
    local session_dir
    session_dir="$(_oc_state_dir)"
    local output_file="${session_dir}/step_${_OC_CURRENT_PHASE_IDX}_${_OC_CURRENT_STEP}.out"
    local exit_code=0
    local retry=0

    _oc_log_info "Executing step $_OC_CURRENT_STEP (phase=$_OC_PHASE_NAME agent=$_OC_PHASE_AGENT)"

    # Build openclaude args
    local oc_args=()
    oc_args+=(--session-id "$_OC_SESSION_ID")
    oc_args+=(--agent "$_OC_PHASE_AGENT")
    [[ -n "${OC_MODEL:-}" ]] && oc_args+=(--model "$OC_MODEL")
    [[ "${OC_COMPACT:-}" == "1" ]] && oc_args+=(--resume --compact) && unset OC_COMPACT
    [[ -f "${session_dir}/context.json" ]] && oc_args+=(--context "${session_dir}/context.json")

    while (( retry <= _OC_MAX_RETRIES )); do
        if (( retry > 0 )); then
            _oc_log_warn "Retry $retry/$_OC_MAX_RETRIES for step $_OC_CURRENT_STEP"
        fi

        openclaude "${oc_args[@]}" > "$output_file" 2>&1
        exit_code=$?

        if (( exit_code == 0 )); then
            break
        fi

        _oc_log_error "openclaude exited $exit_code on step $_OC_CURRENT_STEP (retry=$retry)"
        (( retry++ ))
        [[ "$_OC_INTERRUPTED" == "true" ]] && break
    done

    if (( exit_code != 0 )); then
        _oc_log_error "Step $_OC_CURRENT_STEP failed after $retry retries — aborting phase"
        _oc_write_state
        return 2  # phase abort signal
    fi

    (( _OC_CURRENT_STEP++ ))
    (( _OC_TOTAL_STEPS++ ))
    _oc_write_state

    # Check for continuation
    if _oc_needs_continuation "$exit_code" "$output_file"; then
        _oc_log_debug "Step complete — continuation needed"
        return 0  # caller should continue
    fi

    _oc_log_info "Step complete — phase signals done"
    return 1  # caller should stop (phase complete)
}

# ── Phase execution loop ───────────────────────────────────────────────────────

oc_engine_run() {
    local total_phases
    total_phases=$(_oc_phase_count)

    while (( _OC_CURRENT_PHASE_IDX < total_phases )); do
        [[ "$_OC_INTERRUPTED" == "true" ]] && break

        _oc_load_phase "$_OC_CURRENT_PHASE_IDX"
        _oc_switch_model "$_OC_PHASE_AGENT"
        _oc_log_info "=== Phase start: $_OC_PHASE_NAME [budget: $_OC_PHASE_MAX_STEPS steps] ==="

        while (( _OC_CURRENT_STEP < _OC_PHASE_MAX_STEPS )); do
            [[ "$_OC_INTERRUPTED" == "true" ]] && break 2

            # Overflow check before each step
            if _oc_check_overflow; then
                _oc_trigger_compaction
            fi

            local step_rc=0
            oc_engine_step
            step_rc=$?

            if (( step_rc == 2 )); then
                _oc_log_error "Phase $_OC_PHASE_NAME aborted at step $_OC_CURRENT_STEP"
                return 1
            fi

            if (( step_rc == 1 )); then
                # Phase signaled completion
                _oc_log_info "Phase $_OC_PHASE_NAME complete (steps used: $_OC_CURRENT_STEP)"
                break
            fi
            # step_rc == 0: continue loop
        done

        if (( _OC_CURRENT_STEP >= _OC_PHASE_MAX_STEPS )); then
            _oc_log_warn "Phase $_OC_PHASE_NAME exhausted step budget ($_OC_PHASE_MAX_STEPS) — transitioning"
        fi

        _OC_PHASES_COMPLETED+=("$_OC_PHASE_NAME")
        (( _OC_CURRENT_PHASE_IDX++ ))
        _oc_write_state

        _oc_log_info "=== Phase complete: $_OC_PHASE_NAME | total_steps_so_far=$_OC_TOTAL_STEPS ==="
    done

    if [[ "$_OC_INTERRUPTED" != "true" ]]; then
        _oc_log_info "=== Pipeline complete. Total steps: $_OC_TOTAL_STEPS ==="
    fi
    return 0
}

# ── Public API ─────────────────────────────────────────────────────────────────

oc_engine_init() {
    local session_id="$1"
    local pipeline_config="${2:-$OC_DEFAULT_PIPELINE}"

    if [[ -z "$session_id" ]]; then
        _oc_log_error "oc_engine_init requires a session_id"
        return 1
    fi

    _OC_SESSION_ID="$session_id"
    _OC_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _OC_INTERRUPTED=false
    _OC_CURRENT_PHASE_IDX=0
    _OC_CURRENT_STEP=0
    _OC_TOTAL_STEPS=0
    _OC_PHASES_COMPLETED=()

    _oc_ensure_dirs
    _OC_STATE_FILE="$(_oc_state_dir)/state.json"

    _oc_load_pipeline "$pipeline_config"
    _oc_setup_traps

    # Resume from existing state if present
    if _oc_load_state; then
        _oc_log_info "Resumed session $session_id from saved state"
    else
        _oc_log_info "New session initialized: $session_id"
    fi

    _oc_write_state
    return 0
}

oc_engine_status() {
    if [[ -z "$_OC_SESSION_ID" ]]; then
        echo "[oc-engine] Not initialized." >&2
        return 1
    fi
    printf '[oc-engine] session=%s phase=%s step=%d/%d total=%d completed=(%s)\n' \
        "$_OC_SESSION_ID" \
        "$_OC_PHASE_NAME" \
        "$_OC_CURRENT_STEP" \
        "$_OC_PHASE_MAX_STEPS" \
        "$_OC_TOTAL_STEPS" \
        "$(IFS=,; echo "${_OC_PHASES_COMPLETED[*]}")"
}

oc_engine_interrupt() {
    _OC_INTERRUPTED=true
    _oc_log_warn "Engine interrupted — writing partial state"
    _oc_write_state
    _oc_log_info "Clean shutdown complete. State at: $_OC_STATE_FILE"
    # Do not call exit here — let caller decide
}

# ── Guard: no auto-execution ───────────────────────────────────────────────────
# This file is designed to be sourced only. Functions are exposed above.
# Auto-run guard: if executed directly, emit usage and exit non-zero.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "oc-engine.sh is a library — source it, don't execute directly." >&2
    echo "Usage: source oc-engine.sh && oc_engine_init <session_id> [pipeline_config]" >&2
    exit 1
fi
