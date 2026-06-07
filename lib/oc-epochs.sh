#!/usr/bin/env bash
# oc-epochs.sh — Context Epoch management for OpenClaude
# Sourceable only. Part of the OpenClaude multi-lib system.
# Depends on: oc-engine.sh (session state), jq, sha256sum

# Source guard
[[ -n "${_OC_EPOCHS_LOADED:-}" ]] && return 0
readonly _OC_EPOCHS_LOADED=1

# ---------------------------------------------------------------------------
# Internal constants / state
# ---------------------------------------------------------------------------
_OCE_LOG_FILE="/tmp/oc-epochs.log"
_OCE_SESSION_DIR_BASE="${HOME}/.openclaude/sessions"
_OCE_CURRENT_SESSION_ID=""   # set by oc_epoch_init
_OCE_CURRENT_EPOCH_ID=0      # in-memory cache

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

_oce_log() {
    local level="$1"; shift
    echo "[$(date -Iseconds)] [oc-epochs] [$level] $*" >> "$_OCE_LOG_FILE"
}

_oce_info()  { _oce_log INFO  "$@"; }
_oce_warn()  { _oce_log WARN  "$@"; }
_oce_error() { _oce_log ERROR "$@"; }
_oce_debug() { _oce_log DEBUG "$@"; }

# Return the session directory for the current (or given) session
_oce_session_dir() {
    local sid="${1:-$_OCE_CURRENT_SESSION_ID}"
    echo "${_OCE_SESSION_DIR_BASE}/${sid}"
}

# Compute sha256 checksum of a string value
_oce_checksum_str() {
    echo -n "$1" | sha256sum | awk '{print "sha256:" $1}'
}

# Compute sha256 checksum of a file (returns empty string if file missing)
_oce_checksum_file() {
    if [[ -f "$1" ]]; then
        sha256sum "$1" | awk '{print "sha256:" $1}'
    else
        echo "sha256:missing"
    fi
}

# ISO-8601 timestamp
_oce_now() {
    date -Iseconds
}

# ---------------------------------------------------------------------------
# Source checksums (pipeline_config / user_instructions)
# ---------------------------------------------------------------------------

# Source file paths — override by setting before sourcing if needed
_OCE_PIPELINE_CONFIG="${_OCE_PIPELINE_CONFIG:-${HOME}/.openclaude/pipeline.conf}"
_OCE_USER_INSTRUCTIONS="${_OCE_USER_INSTRUCTIONS:-${HOME}/.openclaude/user_instructions.md}"

_oce_sources_checksums() {
    local agent_system="$1"
    local agent_checksum
    local pipeline_checksum
    local user_checksum

    agent_checksum="$(_oce_checksum_str "$agent_system")"
    pipeline_checksum="$(_oce_checksum_file "$_OCE_PIPELINE_CONFIG")"
    user_checksum="$(_oce_checksum_file "$_OCE_USER_INSTRUCTIONS")"

    jq -n \
        --arg a "$agent_checksum" \
        --arg p "$pipeline_checksum" \
        --arg u "$user_checksum" \
        '{"agent_system": $a, "pipeline_config": $p, "user_instructions": $u}'
}

# ---------------------------------------------------------------------------
# 2. oc_epoch_init <session_id>
# ---------------------------------------------------------------------------
oc_epoch_init() {
    local session_id="$1"
    if [[ -z "$session_id" ]]; then
        _oce_error "oc_epoch_init: session_id required"
        return 1
    fi

    _OCE_CURRENT_SESSION_ID="$session_id"
    local dir
    dir="$(_oce_session_dir "$session_id")"
    mkdir -p "$dir"

    local epoch_file="${dir}/epoch.json"

    if [[ -f "$epoch_file" ]]; then
        local existing_id existing_status
        existing_id="$(jq -r '.epoch_id' "$epoch_file" 2>/dev/null)"
        existing_status="$(jq -r '.status' "$epoch_file" 2>/dev/null)"
        _OCE_CURRENT_EPOCH_ID="${existing_id:-0}"
        _oce_info "oc_epoch_init: restored epoch ${_OCE_CURRENT_EPOCH_ID} (status=${existing_status}) for session ${session_id}"
    else
        # Write an empty/stub epoch so the file always exists
        jq -n \
            --argjson id 0 \
            --arg status "uninitialized" \
            '{epoch_id: $id, status: $status}' > "$epoch_file"
        _OCE_CURRENT_EPOCH_ID=0
        _oce_info "oc_epoch_init: created fresh epoch file for session ${session_id}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# 3. oc_epoch_start <agent_id> <model> <system_prompt>
# ---------------------------------------------------------------------------
oc_epoch_start() {
    local agent_id="$1"
    local model="$2"
    local system_prompt="$3"

    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_start: call oc_epoch_init first"
        return 1
    fi

    local dir
    dir="$(_oce_session_dir)"
    local epoch_file="${dir}/epoch.json"
    local now
    now="$(_oce_now)"

    # --- Archive previous epoch if active ---
    if [[ -f "$epoch_file" ]]; then
        local prev_status prev_id
        prev_status="$(jq -r '.status // "uninitialized"' "$epoch_file" 2>/dev/null)"
        prev_id="$(jq -r '.epoch_id // 0' "$epoch_file" 2>/dev/null)"

        if [[ "$prev_status" == "active" ]]; then
            local archived_file="${dir}/epoch_${prev_id}.json"
            jq --arg ended "$now" --arg status "completed" \
                '.ended_at = $ended | .status = $status' \
                "$epoch_file" > "$archived_file"
            _oce_info "oc_epoch_start: archived epoch ${prev_id} → ${archived_file}"
        fi
    fi

    # --- Increment epoch_id ---
    local new_id=$(( _OCE_CURRENT_EPOCH_ID + 1 ))
    _OCE_CURRENT_EPOCH_ID=$new_id

    # --- Compute checksums ---
    local sources_json
    sources_json="$(_oce_sources_checksums "$system_prompt")"
    local baseline_checksum
    baseline_checksum="$(_oce_checksum_str "$system_prompt")"

    # --- Write new epoch ---
    jq -n \
        --argjson epoch_id "$new_id" \
        --arg agent_id "$agent_id" \
        --arg model "$model" \
        --arg baseline_text "$system_prompt" \
        --arg baseline_checksum "$baseline_checksum" \
        --argjson sources "$sources_json" \
        --arg started_at "$now" \
        '{
            epoch_id: $epoch_id,
            agent_id: $agent_id,
            model: $model,
            baseline_text: $baseline_text,
            baseline_checksum: $baseline_checksum,
            sources: $sources,
            started_at: $started_at,
            ended_at: null,
            status: "active"
        }' > "$epoch_file"

    # --- Append to journal ---
    oc_epoch_record "epoch_start" "agent=${agent_id} model=${model} epoch_id=${new_id}"

    _oce_info "oc_epoch_start: new epoch ${new_id} for agent=${agent_id} model=${model}"
    return 0
}

# ---------------------------------------------------------------------------
# 4. oc_epoch_current
# ---------------------------------------------------------------------------
oc_epoch_current() {
    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_current: not initialized"
        return 1
    fi
    local epoch_file
    epoch_file="$(_oce_session_dir)/epoch.json"
    if [[ ! -f "$epoch_file" ]]; then
        _oce_error "oc_epoch_current: epoch.json not found"
        return 1
    fi
    cat "$epoch_file"
}

# ---------------------------------------------------------------------------
# 5. oc_epoch_check_sources
# Return 0 = unchanged, 1 = changed. Prints changed source names.
# ---------------------------------------------------------------------------
oc_epoch_check_sources() {
    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_check_sources: not initialized"
        return 1
    fi

    local epoch_file
    epoch_file="$(_oce_session_dir)/epoch.json"
    if [[ ! -f "$epoch_file" ]]; then
        _oce_error "oc_epoch_check_sources: epoch.json not found"
        return 1
    fi

    local current_system
    current_system="$(jq -r '.baseline_text // ""' "$epoch_file")"

    local stored_agent stored_pipeline stored_user
    stored_agent="$(jq -r '.sources.agent_system // ""' "$epoch_file")"
    stored_pipeline="$(jq -r '.sources.pipeline_config // ""' "$epoch_file")"
    stored_user="$(jq -r '.sources.user_instructions // ""' "$epoch_file")"

    local live_agent live_pipeline live_user
    live_agent="$(_oce_checksum_str "$current_system")"
    live_pipeline="$(_oce_checksum_file "$_OCE_PIPELINE_CONFIG")"
    live_user="$(_oce_checksum_file "$_OCE_USER_INSTRUCTIONS")"

    local changed=0
    local changed_sources=()

    [[ "$live_agent"    != "$stored_agent"    ]] && { changed_sources+=("agent_system");      changed=1; }
    [[ "$live_pipeline" != "$stored_pipeline" ]] && { changed_sources+=("pipeline_config");   changed=1; }
    [[ "$live_user"     != "$stored_user"     ]] && { changed_sources+=("user_instructions"); changed=1; }

    if [[ $changed -eq 1 ]]; then
        printf '%s\n' "${changed_sources[@]}"
    fi

    return $changed
}

# ---------------------------------------------------------------------------
# 6. oc_epoch_refresh
# ---------------------------------------------------------------------------
oc_epoch_refresh() {
    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_refresh: not initialized"
        return 1
    fi

    local dir
    dir="$(_oce_session_dir)"
    local epoch_file="${dir}/epoch.json"
    local updates_file="${dir}/mid_turn_updates.jsonl"

    # Capture changed sources
    local changed_sources_output
    changed_sources_output="$(oc_epoch_check_sources)"
    local check_rc=$?

    if [[ $check_rc -eq 0 ]]; then
        _oce_debug "oc_epoch_refresh: no source changes detected"
        return 0
    fi

    # Build JSON array of changed sources
    local epoch_id
    epoch_id="$(jq -r '.epoch_id' "$epoch_file" 2>/dev/null)"
    local now
    now="$(_oce_now)"

    local sources_array
    sources_array="$(printf '%s\n' "$changed_sources_output" | jq -R . | jq -s .)"

    jq -n \
        --arg type "system_update" \
        --argjson epoch_id "$epoch_id" \
        --argjson changed_sources "$sources_array" \
        --arg timestamp "$now" \
        '{type: $type, epoch_id: $epoch_id, changed_sources: $changed_sources, timestamp: $timestamp}' \
        >> "$updates_file"

    _oce_info "oc_epoch_refresh: mid-turn update written for epoch ${epoch_id}, changed=${changed_sources_output//$'\n'/, }"

    # Record in journal
    oc_epoch_record "source_changed" "sources=${changed_sources_output//$'\n'/, }"

    return 1  # sources changed
}

# ---------------------------------------------------------------------------
# 7. oc_epoch_fence
# ---------------------------------------------------------------------------
oc_epoch_fence() {
    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_fence: not initialized"
        return 1
    fi

    local lock_file
    lock_file="$(_oce_session_dir)/epoch.lock"

    if [[ -f "$lock_file" ]]; then
        local lock_pid
        lock_pid="$(cat "$lock_file" 2>/dev/null)"
        _oce_warn "oc_epoch_fence: already locked by PID ${lock_pid}"
        return 1
    fi

    echo "$$" > "$lock_file"
    _oce_debug "oc_epoch_fence: lock acquired by PID $$"
    return 0
}

# ---------------------------------------------------------------------------
# 8. oc_epoch_unfence
# ---------------------------------------------------------------------------
oc_epoch_unfence() {
    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_unfence: not initialized"
        return 1
    fi

    local lock_file
    lock_file="$(_oce_session_dir)/epoch.lock"

    if [[ ! -f "$lock_file" ]]; then
        _oce_warn "oc_epoch_unfence: no lock file present"
        return 0
    fi

    local lock_pid
    lock_pid="$(cat "$lock_file" 2>/dev/null)"

    if [[ "$lock_pid" != "$$" ]]; then
        _oce_warn "oc_epoch_unfence: lock owned by PID ${lock_pid}, not $$; refusing to remove"
        return 1
    fi

    rm -f "$lock_file"
    _oce_debug "oc_epoch_unfence: lock released by PID $$"
    return 0
}

# ---------------------------------------------------------------------------
# 9. oc_epoch_record <event_type> <details>
# ---------------------------------------------------------------------------
oc_epoch_record() {
    local event_type="$1"
    local details="$2"

    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_record: not initialized"
        return 1
    fi

    local dir
    dir="$(_oce_session_dir)"
    local journal_file="${dir}/epoch_journal.jsonl"
    local epoch_file="${dir}/epoch.json"
    local now
    now="$(_oce_now)"

    local epoch_id agent_id
    if [[ -f "$epoch_file" ]]; then
        epoch_id="$(jq -r '.epoch_id // 0' "$epoch_file")"
        agent_id="$(jq -r '.agent_id // "unknown"' "$epoch_file")"
    else
        epoch_id="$_OCE_CURRENT_EPOCH_ID"
        agent_id="unknown"
    fi

    jq -n \
        --argjson epoch_id "$epoch_id" \
        --arg event "$event_type" \
        --arg agent_id "$agent_id" \
        --arg timestamp "$now" \
        --arg details "$details" \
        '{epoch_id: $epoch_id, event: $event, agent_id: $agent_id, timestamp: $timestamp, details: $details}' \
        >> "$journal_file"

    _oce_debug "oc_epoch_record: ${event_type} → ${journal_file}"
    return 0
}

# ---------------------------------------------------------------------------
# 10. oc_epoch_history
# ---------------------------------------------------------------------------
oc_epoch_history() {
    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_history: not initialized"
        return 1
    fi

    local journal_file
    journal_file="$(_oce_session_dir)/epoch_journal.jsonl"

    if [[ ! -f "$journal_file" ]]; then
        echo "(no epoch journal found for session ${_OCE_CURRENT_SESSION_ID})"
        return 0
    fi

    echo "=== Epoch Journal: session=${_OCE_CURRENT_SESSION_ID} ==="
    while IFS= read -r line; do
        local epoch_id event agent_id timestamp details
        epoch_id="$(echo "$line"  | jq -r '.epoch_id')"
        event="$(echo "$line"     | jq -r '.event')"
        agent_id="$(echo "$line"  | jq -r '.agent_id')"
        timestamp="$(echo "$line" | jq -r '.timestamp')"
        details="$(echo "$line"   | jq -r '.details')"
        printf "  [epoch=%-3s] [%s] %-20s agent=%-15s %s\n" \
            "$epoch_id" "$timestamp" "$event" "$agent_id" "$details"
    done < "$journal_file"
}

# ---------------------------------------------------------------------------
# 11. oc_epoch_status
# ---------------------------------------------------------------------------
oc_epoch_status() {
    if [[ -z "$_OCE_CURRENT_SESSION_ID" ]]; then
        _oce_error "oc_epoch_status: not initialized"
        return 1
    fi

    local epoch_file
    epoch_file="$(_oce_session_dir)/epoch.json"

    if [[ ! -f "$epoch_file" ]]; then
        echo "(epoch not started for session ${_OCE_CURRENT_SESSION_ID})"
        return 1
    fi

    local epoch_id agent_id model checksum started_at status now age_secs
    epoch_id="$(jq -r  '.epoch_id'           "$epoch_file")"
    agent_id="$(jq -r  '.agent_id'           "$epoch_file")"
    model="$(jq -r     '.model'              "$epoch_file")"
    checksum="$(jq -r  '.baseline_checksum'  "$epoch_file")"
    started_at="$(jq -r '.started_at'        "$epoch_file")"
    status="$(jq -r    '.status'             "$epoch_file")"
    now="$(date +%s)"

    # Age calculation (requires GNU date)
    local started_epoch
    started_epoch="$(date -d "$started_at" +%s 2>/dev/null || echo "$now")"
    age_secs=$(( now - started_epoch ))

    echo "=== Epoch Status ==="
    printf "  session   : %s\n" "$_OCE_CURRENT_SESSION_ID"
    printf "  epoch_id  : %s\n" "$epoch_id"
    printf "  agent     : %s\n" "$agent_id"
    printf "  model     : %s\n" "$model"
    printf "  status    : %s\n" "$status"
    printf "  started   : %s\n" "$started_at"
    printf "  age       : %ss\n" "$age_secs"
    printf "  checksum  : %s\n" "$checksum"

    # Lock status
    local lock_file
    lock_file="$(_oce_session_dir)/epoch.lock"
    if [[ -f "$lock_file" ]]; then
        printf "  fence     : LOCKED (PID %s)\n" "$(cat "$lock_file")"
    else
        printf "  fence     : unlocked\n"
    fi
}
