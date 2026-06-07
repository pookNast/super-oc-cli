#!/usr/bin/env bash
# oc-install.sh — Install super-oc-cli to ~/.super-oc/
# Usage: bash oc-install.sh [--prefix ~/.local/bin]
set -euo pipefail

INSTALL_PREFIX="${HOME}/.local/bin"
OC_HOME="${SUPER_OC_HOME:-$HOME/.super-oc}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --prefix) shift; INSTALL_PREFIX="${1:-$INSTALL_PREFIX}"; shift ;;
        --prefix=*) INSTALL_PREFIX="${arg#--prefix=}" ;;
        --help|-h)
            echo "Usage: bash oc-install.sh [--prefix ~/.local/bin]"
            echo "  Installs super-oc-cli to ~/.super-oc/"
            echo "  Symlinks oc-start to --prefix dir (default: ~/.local/bin)"
            exit 0
            ;;
    esac
done

# ── Check deps ───────────────────────────────────────────────────────────────
echo "[1/5] Checking dependencies..."
MISSING=()
command -v bash &>/dev/null || MISSING+=("bash")
command -v jq &>/dev/null || MISSING+=("jq")
command -v tmux &>/dev/null || MISSING+=("tmux")
command -v curl &>/dev/null || MISSING+=("curl")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "FATAL: Missing required tools: ${MISSING[*]}"
    echo "Install them first, then re-run this script."
    exit 1
fi

# Optional deps
command -v ollama &>/dev/null || echo "  [warn] ollama not found — you'll need it for local models"
command -v openclaude &>/dev/null || echo "  [warn] openclaude not found — install from https://github.com/Gitlawb/openclaude"

echo "  [ok] bash $(bash --version | head -1 | grep -oP '\d+\.\d+\.\d+')"
echo "  [ok] jq $(jq --version 2>/dev/null)"
echo "  [ok] tmux $(tmux -V 2>/dev/null)"

# ── Create directory structure ───────────────────────────────────────────────
echo "[2/5] Creating $OC_HOME/..."
mkdir -p "$OC_HOME"/{lib,config,sessions,agents}
mkdir -p "$INSTALL_PREFIX"

# ── Copy libs (always overwrite — code, not config) ─────────────────────────
echo "[3/5] Installing libraries..."
cp -f "$SCRIPT_DIR"/lib/oc-*.sh "$OC_HOME/lib/"
chmod +x "$OC_HOME/lib/"oc-*.sh
echo "  Installed $(ls "$OC_HOME/lib/"oc-*.sh | wc -l) libraries"

# ── Copy configs (no-clobber — don't overwrite user customizations) ─────────
echo "[4/5] Installing default configs..."
for f in "$SCRIPT_DIR"/config/*.json; do
    [[ "$(basename "$f")" == "config.json.example" ]] && continue
    dest="$OC_HOME/config/$(basename "$f")"
    if [[ ! -f "$dest" ]]; then
        cp "$f" "$dest"
        echo "  + $(basename "$f")"
    else
        echo "  ~ $(basename "$f") (exists, skipped)"
    fi
done

# Copy agent profiles
if [[ -d "$SCRIPT_DIR/config/agents" ]]; then
    for f in "$SCRIPT_DIR"/config/agents/*.json; do
        dest="$OC_HOME/agents/$(basename "$f")"
        if [[ ! -f "$dest" ]]; then
            cp "$f" "$dest"
            echo "  + agents/$(basename "$f")"
        else
            echo "  ~ agents/$(basename "$f") (exists, skipped)"
        fi
    done
fi

# Create config.json from example if not present
if [[ ! -f "$OC_HOME/config.json" ]]; then
    cp "$SCRIPT_DIR/config/config.json.example" "$OC_HOME/config.json"
    echo "  + config.json (from example — edit to customize)"
else
    echo "  ~ config.json (exists, skipped)"
fi

# ── Detect hardware + tune config ───────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    GPU_NAME=$(echo "$GPU_INFO" | cut -d',' -f1 | xargs)
    VRAM_MB=$(echo "$GPU_INFO" | cut -d',' -f2 | xargs)
    echo "  [gpu] $GPU_NAME — ${VRAM_MB}MB VRAM"

    # Auto-tune based on VRAM
    if [[ -n "$VRAM_MB" ]] && (( VRAM_MB > 20000 )); then
        echo "  [tune] High VRAM detected — setting aggressive tuning"
        # Update config with better defaults (only if still at defaults)
        jq --argjson heap 8192 --argjson semi 128 --argjson threads 16 --argjson conc 8 \
            '.node_max_old_space = (if .node_max_old_space == 4096 then $heap else .node_max_old_space end) |
             .node_semi_space = (if .node_semi_space == 64 then $semi else .node_semi_space end) |
             .uv_threadpool_size = (if .uv_threadpool_size == 4 then $threads else .uv_threadpool_size end) |
             .max_tool_concurrency = (if .max_tool_concurrency == 4 then $conc else .max_tool_concurrency end)' \
            "$OC_HOME/config.json" > "$OC_HOME/config.json.tmp" && \
            mv "$OC_HOME/config.json.tmp" "$OC_HOME/config.json"
    fi
else
    echo "  [cpu] No GPU detected — using conservative defaults"
fi

# ── Symlink oc-start ─────────────────────────────────────────────────────────
echo "[5/5] Linking oc-start → $INSTALL_PREFIX/oc-start"
cp -f "$SCRIPT_DIR/bin/oc-start" "$OC_HOME/oc-start"
chmod +x "$OC_HOME/oc-start"
ln -sf "$OC_HOME/oc-start" "$INSTALL_PREFIX/oc-start"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== super-oc-cli installed ==="
echo "  Home:    $OC_HOME"
echo "  Config:  $OC_HOME/config.json"
echo "  Binary:  $INSTALL_PREFIX/oc-start"
echo ""
echo "Next steps:"
echo "  1. Edit $OC_HOME/config.json (set model_default, etc.)"
echo "  2. Ensure $INSTALL_PREFIX is in your PATH"
echo "  3. Run: oc-start"
