#!/usr/bin/env bash
# oc-compaction.sh — Auto-compaction library for OpenClaude
# Part of the multi-lib system: oc-engine.sh, oc-epochs.sh, oc-compaction.sh
# Source guard
[[ -n "${_OC_COMPACTION_LOADED:-}" ]] && return 0
readonly _OC_COMPACTION_LOADED=1

# ---------------------------------------------------------------------------
# Internal configuration
# ---------------------------------------------------------------------------
_OCC_LOG_FILE="/tmp/oc-compaction.log"
_OCC_SESSIONS_BASE="${HOME}/.openclaude/sessions"
_OCC_DEFAULT_CONTEXT_WINDOW=262144
_OCC_DEFAULT_OVERFLOW_THRESHOLD="0.8"
_OCC_DEFAULT_KEEP_RATIO="0.3"

# ---------------------------------------------------------------------------
# Internal logging helpers
# ---------------------------------------------------------------------------
_occ_log() {
    local level="$1"; shift
    echo "$(date -Iseconds) [${level}] [oc-compaction] $*" >> "${_OCC_LOG_FILE}"
}
_occ_info()  { _occ_log INFO  "$@"; }
_occ_warn()  { _occ_log WARN  "$@"; }
_occ_error() { _occ_log ERROR "$@"; }
_occ_debug() { [[ -n "${OC_DEBUG:-}" ]] && _occ_log DEBUG "$@" || true; }

# ---------------------------------------------------------------------------
# Internal config loader
# ---------------------------------------------------------------------------
_occ_config() {
    local session_id="$1"
    local key="$2"
    local default="$3"
    local pipeline_json="${_OCC_SESSIONS_BASE}/${session_id}/pipeline.json"
    if [[ -f "${pipeline_json}" ]]; then
        local val
        val=$(jq -r --arg k "${key}" '.[$k] // empty' "${pipeline_json}" 2>/dev/null)
        if [[ -n "${val}" && "${val}" != "null" ]]; then
            echo "${val}"
            return
        fi
    fi
    echo "${default}"
}

_occ_context_window() {
    local session_id="$1"
    _occ_config "${session_id}" "context_window" "${_OCC_DEFAULT_CONTEXT_WINDOW}"
}

_occ_overflow_threshold() {
    local session_id="$1"
    _occ_config "${session_id}" "overflow_threshold" "${_OCC_DEFAULT_OVERFLOW_THRESHOLD}"
}

_occ_keep_ratio() {
    local session_id="$1"
    _occ_config "${session_id}" "keep_ratio" "${_OCC_DEFAULT_KEEP_RATIO}"
}

_occ_session_dir() {
    echo "${_OCC_SESSIONS_BASE}/${1}"
}

# ---------------------------------------------------------------------------
# 1. Token counting
# ---------------------------------------------------------------------------
oc_compact_count_tokens() {
    local session_id="$1"
    if [[ -z "${session_id}" ]]; then
        _occ_error "oc_compact_count_tokens: session_id required"
        echo 0; return 1
    fi

    local session_dir
    session_dir=$(_occ_session_dir "${session_id}")
    local token_count_file="${session_dir}/token_count"

    # Authoritative file wins if present and non-empty
    if [[ -f "${token_count_file}" ]]; then
        local stored
        stored=$(cat "${token_count_file}" 2>/dev/null | tr -d '[:space:]')
        if [[ "${stored}" =~ ^[0-9]+$ && "${stored}" -gt 0 ]]; then
            _occ_debug "count_tokens: using authoritative token_count=${stored} for session=${session_id}"
            echo "${stored}"
            return 0
        fi
    fi

    # Estimate: sum char lengths of all step output files, divide by 4
    local total_chars=0
    if [[ -d "${session_dir}" ]]; then
        while IFS= read -r -d '' outfile; do
            local sz
            sz=$(wc -c < "${outfile}" 2>/dev/null || echo 0)
            total_chars=$(( total_chars + sz ))
        done < <(find "${session_dir}" -maxdepth 1 -name 'step_*.out' -print0 2>/dev/null)
    fi

    local estimated=$(( total_chars / 4 ))
    _occ_debug "count_tokens: estimated=${estimated} (chars=${total_chars}) for session=${session_id}"

    # Persist estimate
    mkdir -p "${session_dir}"
    echo "${estimated}" > "${token_count_file}"

    echo "${estimated}"
}

# ---------------------------------------------------------------------------
# 2. Per-turn logging
# ---------------------------------------------------------------------------
oc_compact_log_turn() {
    local session_id="$1"
    local step="$2"
    local input_tokens="${3:-0}"
    local output_tokens="${4:-0}"
    local cache_tokens="${5:-0}"

    if [[ -z "${session_id}" || -z "${step}" ]]; then
        _occ_error "oc_compact_log_turn: session_id and step required"
        return 1
    fi

    local session_dir
    session_dir=$(_occ_session_dir "${session_id}")
    mkdir -p "${session_dir}"

    local total=$(( input_tokens + output_tokens + cache_tokens ))
    local token_log="${session_dir}/token_log.jsonl"

    # Read current cumulative (last entry in log)
    local cumulative=0
    if [[ -f "${token_log}" ]]; then
        local last_cum
        last_cum=$(tail -1 "${token_log}" 2>/dev/null | jq -r '.cumulative // 0' 2>/dev/null)
        cumulative=$(( ${last_cum:-0} + total ))
    else
        cumulative="${total}"
    fi

    local ts
    ts=$(date -Iseconds)

    jq -cn \
        --argjson step "${step}" \
        --argjson input "${input_tokens}" \
        --argjson output "${output_tokens}" \
        --argjson cache "${cache_tokens}" \
        --argjson total "${total}" \
        --argjson cumulative "${cumulative}" \
        --arg timestamp "${ts}" \
        '{step: $step, input: $input, output: $output, cache: $cache, total: $total, cumulative: $cumulative, timestamp: $timestamp}' \
        >> "${token_log}"

    # Keep token_count in sync with cumulative
    echo "${cumulative}" > "${session_dir}/token_count"

    _occ_debug "log_turn: session=${session_id} step=${step} total=${total} cumulative=${cumulative}"
}

# ---------------------------------------------------------------------------
# 3. Threshold check
# ---------------------------------------------------------------------------
oc_compact_check() {
    local session_id="$1"
    if [[ -z "${session_id}" ]]; then
        _occ_error "oc_compact_check: session_id required"
        return 1
    fi

    local context_window
    context_window=$(_occ_context_window "${session_id}")
    local overflow_threshold
    overflow_threshold=$(_occ_overflow_threshold "${session_id}")

    local current_tokens
    current_tokens=$(oc_compact_count_tokens "${session_id}")

    # Compute utilization percentage (integer math via awk)
    local utilization_pct
    utilization_pct=$(awk "BEGIN { printf \"%.1f\", (${current_tokens} / ${context_window}) * 100 }")

    local threshold_tokens
    threshold_tokens=$(awk "BEGIN { printf \"%d\", ${context_window} * ${overflow_threshold} }")

    echo "utilization=${utilization_pct}% (${current_tokens}/${context_window} tokens, threshold=${threshold_tokens})"

    if (( current_tokens >= threshold_tokens )); then
        _occ_info "check: COMPACTION NEEDED session=${session_id} utilization=${utilization_pct}%"
        return 0   # 0 = compaction needed
    else
        _occ_debug "check: OK session=${session_id} utilization=${utilization_pct}%"
        return 1   # 1 = OK, no compaction needed
    fi
}

# ---------------------------------------------------------------------------
# Internal: shared compaction logic
# ---------------------------------------------------------------------------
_occ_do_compaction() {
    local session_id="$1"
    local trigger="${2:-auto}"  # "auto" or "manual"

    local session_dir
    session_dir=$(_occ_session_dir "${session_id}")
    mkdir -p "${session_dir}/archive"

    local context_window
    context_window=$(_occ_context_window "${session_id}")
    local keep_ratio
    keep_ratio=$(_occ_keep_ratio "${session_id}")

    local before_tokens
    before_tokens=$(oc_compact_count_tokens "${session_id}")

    # Keep last keep_ratio * context_window worth of chars (~4 chars/token)
    local keep_tokens
    keep_tokens=$(awk "BEGIN { printf \"%d\", ${context_window} * ${keep_ratio} }")
    local keep_chars=$(( keep_tokens * 4 ))

    _occ_info "compaction: session=${session_id} trigger=${trigger} before_tokens=${before_tokens} keep_tokens=${keep_tokens}"

    # Gather all step output files sorted by name (step_0001.out, etc.)
    local -a all_steps=()
    while IFS= read -r -d '' f; do
        all_steps+=("$f")
    done < <(find "${session_dir}" -maxdepth 1 -name 'step_*.out' -print0 2>/dev/null | sort -z)

    local n_steps="${#all_steps[@]}"
    if (( n_steps == 0 )); then
        _occ_warn "compaction: no step files found for session=${session_id}"
        return 0
    fi

    # Walk from newest backwards, accumulate chars until keep_chars exceeded
    local accumulated=0
    local keep_from_index=${n_steps}  # index of first step to keep (0-based)
    for (( i = n_steps - 1; i >= 0; i-- )); do
        local sz
        sz=$(wc -c < "${all_steps[$i]}" 2>/dev/null || echo 0)
        accumulated=$(( accumulated + sz ))
        if (( accumulated >= keep_chars )); then
            keep_from_index=$i
            break
        fi
        keep_from_index=$i
    done
    # If all fit within keep_chars, nothing to archive
    if (( keep_from_index == 0 )); then
        _occ_info "compaction: nothing to archive (all content fits within keep ratio)"
        return 0
    fi

    # Archive steps before keep_from_index
    local archived_steps=0
    local summary_file="${session_dir}/compaction_summary.md"
    {
        echo "# Compaction Summary"
        echo "- Session: ${session_id}"
        echo "- Trigger: ${trigger}"
        echo "- Timestamp: $(date -Iseconds)"
        echo "- Archived steps: 0 through $(( keep_from_index - 1 ))"
        echo ""
        echo "## Archived Step Excerpts"
    } > "${summary_file}"

    for (( i = 0; i < keep_from_index; i++ )); do
        local f="${all_steps[$i]}"
        local basename
        basename=$(basename "${f}")
        mv "${f}" "${session_dir}/archive/${basename}"
        archived_steps=$(( archived_steps + 1 ))

        # Append first 3 and last 3 lines to summary
        {
            echo ""
            echo "### ${basename}"
            echo "\`\`\`"
            head -3 "${session_dir}/archive/${basename}" 2>/dev/null || true
            echo "..."
            tail -3 "${session_dir}/archive/${basename}" 2>/dev/null || true
            echo "\`\`\`"
        } >> "${summary_file}"
    done

    _occ_info "compaction: archived ${archived_steps} step files for session=${session_id}"

    # Reset token count — re-estimate from remaining steps
    rm -f "${session_dir}/token_count"
    local after_tokens
    after_tokens=$(oc_compact_count_tokens "${session_id}")

    # Determine compaction_id (next sequential)
    local compaction_log="${session_dir}/compaction_log.jsonl"
    local compaction_id=1
    if [[ -f "${compaction_log}" ]]; then
        local last_id
        last_id=$(tail -1 "${compaction_log}" 2>/dev/null | jq -r '.compaction_id // 0' 2>/dev/null)
        compaction_id=$(( ${last_id:-0} + 1 ))
    fi

    local ts
    ts=$(date -Iseconds)

    jq -cn \
        --argjson compaction_id "${compaction_id}" \
        --arg trigger "${trigger}" \
        --argjson before_tokens "${before_tokens}" \
        --argjson after_tokens "${after_tokens}" \
        --argjson archived_steps "${archived_steps}" \
        --arg timestamp "${ts}" \
        '{compaction_id: $compaction_id, trigger: $trigger, before_tokens: $before_tokens, after_tokens: $after_tokens, archived_steps: $archived_steps, timestamp: $timestamp}' \
        >> "${compaction_log}"

    # Start new epoch if oc-epochs.sh is loaded
    if declare -f oc_epoch_start &>/dev/null; then
        oc_epoch_start "${session_id}"
        _occ_info "compaction: new epoch started for session=${session_id}"
    fi

    _occ_info "compaction: DONE session=${session_id} before=${before_tokens} after=${after_tokens} archived=${archived_steps}"
    echo "Compaction complete: ${before_tokens} → ${after_tokens} tokens (${archived_steps} steps archived)"
}

# ---------------------------------------------------------------------------
# 4. Keep-last-N strategy execute
# ---------------------------------------------------------------------------
oc_compact_execute() {
    local session_id="$1"
    if [[ -z "${session_id}" ]]; then
        _occ_error "oc_compact_execute: session_id required"
        return 1
    fi
    _occ_do_compaction "${session_id}" "auto"
}

# ---------------------------------------------------------------------------
# 5. Manual trigger
# ---------------------------------------------------------------------------
oc_compact_now() {
    local session_id="$1"
    if [[ -z "${session_id}" ]]; then
        _occ_error "oc_compact_now: session_id required"
        return 1
    fi
    _occ_info "manual compaction triggered for session=${session_id}"
    _occ_do_compaction "${session_id}" "manual"
}

# ---------------------------------------------------------------------------
# 6. Compaction history
# ---------------------------------------------------------------------------
oc_compact_history() {
    local session_id="$1"
    if [[ -z "${session_id}" ]]; then
        _occ_error "oc_compact_history: session_id required"
        return 1
    fi

    local compaction_log
    compaction_log="${_OCC_SESSIONS_BASE}/${session_id}/compaction_log.jsonl"

    if [[ ! -f "${compaction_log}" ]]; then
        echo "No compaction history for session: ${session_id}"
        return 0
    fi

    echo "=== Compaction History: ${session_id} ==="
    while IFS= read -r line; do
        echo "${line}" | jq -r '"[#\(.compaction_id)] \(.trigger) @ \(.timestamp)  before=\(.before_tokens) after=\(.after_tokens) archived_steps=\(.archived_steps)"' 2>/dev/null || echo "${line}"
    done < "${compaction_log}"
}

# ---------------------------------------------------------------------------
# 7. Buffer headroom
# ---------------------------------------------------------------------------
oc_compact_headroom() {
    local session_id="$1"
    if [[ -z "${session_id}" ]]; then
        _occ_error "oc_compact_headroom: session_id required"
        return 1
    fi

    local context_window
    context_window=$(_occ_context_window "${session_id}")
    local overflow_threshold
    overflow_threshold=$(_occ_overflow_threshold "${session_id}")

    local current_tokens
    current_tokens=$(oc_compact_count_tokens "${session_id}")

    local threshold_tokens
    threshold_tokens=$(awk "BEGIN { printf \"%d\", ${context_window} * ${overflow_threshold} }")

    local headroom=$(( threshold_tokens - current_tokens ))
    if (( headroom < 0 )); then
        headroom=0
    fi

    _occ_debug "headroom: session=${session_id} headroom=${headroom} threshold=${threshold_tokens} current=${current_tokens}"
    echo "${headroom}"
}

# ---------------------------------------------------------------------------
# 8. Stats / status
# ---------------------------------------------------------------------------
oc_compact_status() {
    local session_id="$1"
    if [[ -z "${session_id}" ]]; then
        _occ_error "oc_compact_status: session_id required"
        return 1
    fi

    local session_dir
    session_dir=$(_occ_session_dir "${session_id}")

    local context_window
    context_window=$(_occ_context_window "${session_id}")
    local overflow_threshold
    overflow_threshold=$(_occ_overflow_threshold "${session_id}")

    local current_tokens
    current_tokens=$(oc_compact_count_tokens "${session_id}")

    local utilization_pct
    utilization_pct=$(awk "BEGIN { printf \"%.1f\", (${current_tokens} / ${context_window}) * 100 }")

    local threshold_tokens
    threshold_tokens=$(awk "BEGIN { printf \"%d\", ${context_window} * ${overflow_threshold} }")

    local headroom=$(( threshold_tokens - current_tokens ))
    if (( headroom < 0 )); then headroom=0; fi

    # Last compaction timestamp + total count
    local last_compaction="(none)"
    local total_compactions=0
    local compaction_log="${session_dir}/compaction_log.jsonl"
    if [[ -f "${compaction_log}" ]]; then
        total_compactions=$(wc -l < "${compaction_log}" 2>/dev/null || echo 0)
        last_compaction=$(tail -1 "${compaction_log}" 2>/dev/null | jq -r '.timestamp // "(unknown)"' 2>/dev/null || echo "(unknown)")
    fi

    cat <<EOF
=== Compaction Status: ${session_id} ===
  Tokens:           ${current_tokens} / ${context_window}
  Utilization:      ${utilization_pct}%
  Compact at:       ${threshold_tokens} tokens (${overflow_threshold} threshold)
  Headroom:         ${headroom} tokens
  Last compaction:  ${last_compaction}
  Total compactions: ${total_compactions}
EOF
}
