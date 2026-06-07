#!/usr/bin/env bash
# oc-cost.sh — Cost + capacity tracking library for OpenClaude
# Source-only: do not execute directly.
# Naming: internal vars _OCCO_*, public functions occ_*

# Source guard
[[ -n "${_OCCO_SOURCED:-}" ]] && return 0
_OCCO_SOURCED=1

# ─── Internal state ──────────────────────────────────────────────────────────
_OCCO_COSTS_FILE="${HOME}/.openclaude/costs.json"
_OCCO_SESSIONS_DIR="${HOME}/.openclaude/sessions"
_OCCO_LOG_FILE="/tmp/oc-cost.log"
_OCCO_SESSION_ID=""
_OCCO_STATE_FILE=""
_OCCO_SESSION_START_EPOCH=0

# ─── Logger ──────────────────────────────────────────────────────────────────
_occo_log() {
    local level="$1"; shift
    printf '[%s] [oc-cost] [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$level" "$*" >> "$_OCCO_LOG_FILE"
}
_occo_info()  { _occo_log INFO  "$@"; }
_occo_warn()  { _occo_log WARN  "$@"; }
_occo_error() { _occo_log ERROR "$@"; }
_occo_debug() { _occo_log DEBUG "$@"; }

# ─── Internal helpers ─────────────────────────────────────────────────────────

# Ensure jq is available
_occo_require_jq() {
    if ! command -v jq &>/dev/null; then
        _occo_error "jq is required but not installed"
        echo "ERROR: jq is required for oc-cost.sh" >&2
        return 1
    fi
}

# Return costs.json value for a model field; empty string if not found
_occo_model_field() {
    local model="$1" field="$2"
    jq -r --arg m "$model" --arg f "$field" \
        '.models[$m][$f] // empty' "$_OCCO_COSTS_FILE" 2>/dev/null
}

# Return epoch seconds (portable)
_occo_now_epoch() {
    date '+%s'
}

# Format seconds as Xh Ym Zs
_occo_format_duration() {
    local secs="$1"
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    if (( h > 0 )); then
        printf '%dh %dm %ds' "$h" "$m" "$s"
    elif (( m > 0 )); then
        printf '%dm %ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

# Format integer with thousands separators
_occo_fmt_int() {
    printf '%d' "${1:-0}" | sed ':a;s/\B[0-9]\{3\}\b/,&/;ta'
}

# Write current state file atomically (via tmp + mv)
_occo_write_state() {
    local tmp="${_OCCO_STATE_FILE}.tmp.$$"
    printf '%s' "$1" > "$tmp" && mv "$tmp" "$_OCCO_STATE_FILE"
}

# ─── Public API ───────────────────────────────────────────────────────────────

# 1. occ_init [session_id]
occ_init() {
    _occo_require_jq || return 1

    local session_id="${1:-$(date '+%Y%m%d-%H%M%S')-$$}"
    _OCCO_SESSION_ID="$session_id"
    _OCCO_SESSION_START_EPOCH="$(_occo_now_epoch)"

    local session_dir="${_OCCO_SESSIONS_DIR}/${session_id}"
    mkdir -p "$session_dir"
    _OCCO_STATE_FILE="${session_dir}/cost_state.json"

    if [[ ! -f "$_OCCO_STATE_FILE" ]]; then
        local started_at
        started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        local init_state
        init_state=$(jq -n \
            --arg sid "$session_id" \
            --arg ts  "$started_at" \
            '{
                session_id:        $sid,
                started_at:        $ts,
                models_used:       {},
                total_input_tokens:  0,
                total_output_tokens: 0,
                total_cache_tokens:  0,
                total_cost_usd:    0.0,
                vram_peak_gb:      0.0,
                turns:             []
            }')
        _occo_write_state "$init_state"
        _occo_info "Session initialized: $session_id at $started_at"
    else
        _occo_info "Session resumed: $session_id"
        # Restore start epoch from state
        local stored_ts
        stored_ts=$(jq -r '.started_at' "$_OCCO_STATE_FILE")
        _OCCO_SESSION_START_EPOCH=$(date -d "$stored_ts" '+%s' 2>/dev/null || _occo_now_epoch)
    fi

    export _OCCO_SESSION_ID _OCCO_STATE_FILE _OCCO_SESSION_START_EPOCH
}

# 2. occ_record_turn <model> <input_tokens> <output_tokens> [cache_tokens]
occ_record_turn() {
    _occo_require_jq || return 1
    [[ -z "$_OCCO_STATE_FILE" ]] && { echo "ERROR: occ_init not called" >&2; return 1; }

    local model="$1"
    local input_tokens="${2:-0}"
    local output_tokens="${3:-0}"
    local cache_tokens="${4:-0}"

    local in_rate out_rate cache_rate
    in_rate="$(_occo_model_field "$model" input_cost_per_1k)"
    out_rate="$(_occo_model_field "$model" output_cost_per_1k)"
    cache_rate="$(_occo_model_field "$model" cache_read_cost_per_1k)"

    # Default to 0.0 if model not found
    in_rate="${in_rate:-0.0}"
    out_rate="${out_rate:-0.0}"
    cache_rate="${cache_rate:-0.0}"

    local turn_cost
    turn_cost=$(awk -v i="$input_tokens" -v o="$output_tokens" -v c="$cache_tokens" \
                    -v ir="$in_rate" -v or_="$out_rate" -v cr="$cache_rate" \
                'BEGIN { printf "%.10f", (i * ir + o * or_ + c * cr) / 1000 }')

    local turn_ts
    turn_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local current_state
    current_state=$(cat "$_OCCO_STATE_FILE")

    local new_state
    new_state=$(printf '%s' "$current_state" | jq \
        --arg model "$model" \
        --argjson it "$input_tokens" \
        --argjson ot "$output_tokens" \
        --argjson ct "$cache_tokens" \
        --argjson cost "$turn_cost" \
        --arg ts "$turn_ts" \
        '
        .total_input_tokens  += $it |
        .total_output_tokens += $ot |
        .total_cache_tokens  += $ct |
        .total_cost_usd      += $cost |
        .models_used[$model] = (.models_used[$model] // 0) + 1 |
        .turns += [{
            model:         $model,
            timestamp:     $ts,
            input_tokens:  $it,
            output_tokens: $ot,
            cache_tokens:  $ct,
            cost_usd:      $cost
        }]
        ')

    _occo_write_state "$new_state"
    _occo_info "Recorded turn: model=$model in=$input_tokens out=$output_tokens cache=$cache_tokens cost=$turn_cost"
}

# 3. occ_estimate_cost <model> <input_tokens> <output_tokens>
occ_estimate_cost() {
    _occo_require_jq || return 1

    local model="$1"
    local input_tokens="${2:-0}"
    local output_tokens="${3:-0}"

    local in_rate out_rate
    in_rate="$(_occo_model_field "$model" input_cost_per_1k)"
    out_rate="$(_occo_model_field "$model" output_cost_per_1k)"
    in_rate="${in_rate:-0.0}"
    out_rate="${out_rate:-0.0}"

    local cost
    cost=$(awk -v i="$input_tokens" -v o="$output_tokens" \
               -v ir="$in_rate" -v or_="$out_rate" \
           'BEGIN { printf "%.4f", (i * ir + o * or_) / 1000 }')

    local in_k out_k
    in_k=$(awk -v n="$input_tokens"  'BEGIN { printf "%.1fK", n/1000 }')
    out_k=$(awk -v n="$output_tokens" 'BEGIN { printf "%.1fK", n/1000 }')

    printf '$%s (%s in + %s out @ %s)\n' "$cost" "$in_k" "$out_k" "$model"
}

# 4. occ_vram_poll
occ_vram_poll() {
    _occo_require_jq || return 1

    local api_response
    api_response=$(curl -sf --max-time 3 http://127.0.0.1:11434/api/ps 2>/dev/null)

    if [[ -z "$api_response" ]]; then
        _occo_warn "Ollama /api/ps unreachable or empty"
        echo "0.0"
        return 0
    fi

    local total_bytes
    total_bytes=$(printf '%s' "$api_response" | \
        jq '[.models[]?.size_vram // 0] | add // 0' 2>/dev/null)
    total_bytes="${total_bytes:-0}"

    local total_gb
    total_gb=$(awk -v b="$total_bytes" 'BEGIN { printf "%.2f", b / (1024^3) }')

    # Update peak in state if session active
    if [[ -n "$_OCCO_STATE_FILE" && -f "$_OCCO_STATE_FILE" ]]; then
        local current_peak
        current_peak=$(jq -r '.vram_peak_gb' "$_OCCO_STATE_FILE")
        local is_new_peak
        is_new_peak=$(awk -v cur="$total_gb" -v peak="$current_peak" \
                      'BEGIN { print (cur > peak) ? "1" : "0" }')
        if [[ "$is_new_peak" == "1" ]]; then
            local updated
            updated=$(jq --argjson gb "$total_gb" '.vram_peak_gb = $gb' "$_OCCO_STATE_FILE")
            _occo_write_state "$updated"
            _occo_debug "New VRAM peak: ${total_gb} GB"
        fi
    fi

    echo "$total_gb"
}

# 5. occ_session_cost — print current session cost summary
occ_session_cost() {
    _occo_require_jq || return 1
    [[ -z "$_OCCO_STATE_FILE" || ! -f "$_OCCO_STATE_FILE" ]] && \
        { echo "No active session." >&2; return 1; }

    local state
    state=$(cat "$_OCCO_STATE_FILE")

    local now_epoch
    now_epoch="$(_occo_now_epoch)"
    local elapsed=$(( now_epoch - _OCCO_SESSION_START_EPOCH ))
    local duration
    duration="$(_occo_format_duration "$elapsed")"

    local turns
    turns=$(printf '%s' "$state" | jq '.turns | length')

    local models_str
    models_str=$(printf '%s' "$state" | jq -r \
        '.models_used | to_entries | map(.key + " (" + (.value|tostring) + ")") | join(", ")')

    local total_in total_out total_cache total_cost vram_peak
    total_in=$(printf '%s' "$state"    | jq '.total_input_tokens')
    total_out=$(printf '%s' "$state"   | jq '.total_output_tokens')
    total_cache=$(printf '%s' "$state" | jq '.total_cache_tokens')
    total_cost=$(printf '%s' "$state"  | jq '.total_cost_usd')
    vram_peak=$(printf '%s' "$state"   | jq '.vram_peak_gb')

    local vram_cap
    vram_cap=$(jq -r '.vram_capacity_gb' "$_OCCO_COSTS_FILE" 2>/dev/null || echo "24")

    local fmt_cost
    fmt_cost=$(awk -v c="$total_cost" 'BEGIN { printf "%.4f", c }')

    printf '\n'
    printf 'Session Cost Summary\n'
    printf '\xe2\x94\x80%.0s' {1..21}; printf '\n'
    printf 'Duration:     %s\n'     "$duration"
    printf 'Turns:        %s\n'     "$turns"
    printf 'Models:       %s\n'     "${models_str:-(none)}"
    printf 'Tokens:       %s in / %s out / %s cache\n' \
        "$(_occo_fmt_int "$total_in")" \
        "$(_occo_fmt_int "$total_out")" \
        "$(_occo_fmt_int "$total_cache")"
    printf 'Cost:         $%s\n'    "$fmt_cost"
    printf 'VRAM Peak:    %s GB / %s GB\n' "$vram_peak" "$vram_cap"
    printf '\n'
}

# 6. occ_model_cost <model>
occ_model_cost() {
    _occo_require_jq || return 1

    local model="$1"
    if [[ -z "$model" ]]; then
        echo "Usage: occ_model_cost <model>" >&2
        return 1
    fi

    local exists
    exists=$(jq -r --arg m "$model" 'if .models[$m] then "yes" else "no" end' "$_OCCO_COSTS_FILE")
    if [[ "$exists" == "no" ]]; then
        echo "Model '$model' not found in costs.json" >&2
        return 1
    fi

    local provider in_rate out_rate cache_rate ctx notes
    provider=$(_occo_model_field "$model" provider)
    in_rate=$(_occo_model_field "$model" input_cost_per_1k)
    out_rate=$(_occo_model_field "$model" output_cost_per_1k)
    cache_rate=$(_occo_model_field "$model" cache_read_cost_per_1k)
    ctx=$(_occo_model_field "$model" context_window)
    notes=$(_occo_model_field "$model" notes)

    printf '\nModel: %s\n' "$model"
    printf '  Provider:       %s\n'   "$provider"
    printf '  Input/1K:       $%s\n'  "$in_rate"
    printf '  Output/1K:      $%s\n'  "$out_rate"
    printf '  Cache read/1K:  $%s\n'  "$cache_rate"
    printf '  Context window: %s tokens\n' "$(_occo_fmt_int "$ctx")"
    printf '  Notes:          %s\n\n' "$notes"
}

# 7. occ_cost_command — /cost command handler
occ_cost_command() {
    occ_session_cost

    _occo_require_jq || return 1
    [[ -z "$_OCCO_STATE_FILE" || ! -f "$_OCCO_STATE_FILE" ]] && return 1

    local state
    state=$(cat "$_OCCO_STATE_FILE")

    local model_count
    model_count=$(printf '%s' "$state" | jq '.models_used | length')
    if (( model_count == 0 )); then
        return 0
    fi

    printf 'Per-Model Breakdown\n'
    printf '\xe2\x94\x80%.0s' {1..21}; printf '\n'

    # Per-model stats from turns array
    printf '%s' "$state" | jq -r '
        .turns
        | group_by(.model)[]
        | {
            model:  .[0].model,
            turns:  length,
            in:     (map(.input_tokens)  | add),
            out:    (map(.output_tokens) | add),
            cache:  (map(.cache_tokens)  | add),
            cost:   (map(.cost_usd)      | add)
          }
        | "\(.model)\t\(.turns) turns\t\(.in)in/\(.out)out\t$\(.cost | . * 10000 | round / 10000)"
    ' | while IFS=$'\t' read -r mdl trns toks cost; do
        printf '  %-32s  %-10s  %-22s  %s\n' "$mdl" "$trns" "$toks" "$cost"
    done

    printf '\n'
}

# 8. occ_session_summary — called on exit
occ_session_summary() {
    [[ -z "$_OCCO_STATE_FILE" || ! -f "$_OCCO_STATE_FILE" ]] && return 0

    local summary_file
    summary_file="${_OCCO_STATE_FILE%cost_state.json}cost_summary.txt"

    {
        occ_session_cost
        printf 'Session ID: %s\n' "$_OCCO_SESSION_ID"
        printf 'State file: %s\n' "$_OCCO_STATE_FILE"
    } | tee "$summary_file"

    _occo_info "Session summary written to $summary_file"
}

# 9. occ_compare_models <input_tokens> <output_tokens>
occ_compare_models() {
    _occo_require_jq || return 1

    local input_tokens="${1:-1000}"
    local output_tokens="${2:-500}"

    printf '\nModel Cost Comparison  (%s in + %s out tokens)\n' \
        "$(_occo_fmt_int "$input_tokens")" "$(_occo_fmt_int "$output_tokens")"
    printf '\xe2\x94\x80%.0s' {1..55}; printf '\n'
    printf '  %-32s  %-10s  %s\n' "Model" "Provider" "Estimated Cost"
    printf '\xe2\x94\x80%.0s' {1..55}; printf '\n'

    # Build comparison rows via jq + awk
    jq -r --argjson it "$input_tokens" --argjson ot "$output_tokens" '
        .models | to_entries[]
        | .key as $m
        | .value
        | {
            model:    $m,
            provider: .provider,
            cost: (($it * .input_cost_per_1k + $ot * .output_cost_per_1k) / 1000)
          }
        | "\(.cost)\t\(.model)\t\(.provider)"
    ' "$_OCCO_COSTS_FILE" \
    | sort -n \
    | while IFS=$'\t' read -r cost mdl prov; do
        local fmt_cost
        fmt_cost=$(awk -v c="$cost" 'BEGIN { printf "%.6f", c }')
        printf '  %-32s  %-10s  $%s\n' "$mdl" "$prov" "$fmt_cost"
    done

    printf '\n'
}

# 10. occ_status — print cost tracking state
occ_status() {
    printf '\n'
    if [[ -z "$_OCCO_SESSION_ID" ]]; then
        printf 'Cost Tracking: no active session (call occ_init)\n\n'
        return 0
    fi

    _occo_require_jq || return 1

    printf 'Cost Tracking Status\n'
    printf '\xe2\x94\x80%.0s' {1..21}; printf '\n'
    printf 'Session:      %s\n' "$_OCCO_SESSION_ID"

    if [[ -f "$_OCCO_STATE_FILE" ]]; then
        local total_cost turns vram_peak
        total_cost=$(jq '.total_cost_usd'  "$_OCCO_STATE_FILE")
        turns=$(jq      '.turns | length'  "$_OCCO_STATE_FILE")
        vram_peak=$(jq  '.vram_peak_gb'    "$_OCCO_STATE_FILE")

        local vram_cap
        vram_cap=$(jq -r '.vram_capacity_gb' "$_OCCO_COSTS_FILE" 2>/dev/null || echo "24")

        local current_vram
        current_vram=$(occ_vram_poll 2>/dev/null || echo "0.0")

        local fmt_cost
        fmt_cost=$(awk -v c="$total_cost" 'BEGIN { printf "%.4f", c }')

        local now_epoch elapsed
        now_epoch="$(_occo_now_epoch)"
        elapsed=$(( now_epoch - _OCCO_SESSION_START_EPOCH ))

        printf 'Duration:     %s\n' "$(_occo_format_duration "$elapsed")"
        printf 'Turns:        %s\n' "$turns"
        printf 'Total cost:   $%s\n' "$fmt_cost"
        printf 'VRAM now:     %s GB / %s GB (peak: %s GB)\n' \
            "$current_vram" "$vram_cap" "$vram_peak"
    else
        printf 'State file missing: %s\n' "$_OCCO_STATE_FILE"
    fi

    printf '\n'
}
