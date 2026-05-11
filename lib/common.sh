#!/usr/bin/env bash
# lib/common.sh – shared helpers used by install.sh and start-sandbox.sh.
#
# Source this file (do not execute it directly):
#   source "${SCRIPT_DIR}/lib/common.sh"

# Guard against being sourced more than once.
[[ -n "${_LIB_COMMON_LOADED:-}" ]] && return 0
_LIB_COMMON_LOADED=1

# ── logging helpers ───────────────────────────────────────────────────────────
log()  { echo "▶  $*"; }
info() { echo "   $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠  $*" >&2; }

# ── dependency check ──────────────────────────────────────────────────────────
# Adds /snap/bin to PATH when a command is installed via Snap and the current
# shell PATH does not include that directory.
ensure_cmd_on_path() {
    local cmd="$1"
    local snap_bin_dir="${SNAP_BIN_DIR:-/snap/bin}"
    if command -v "${cmd}" &>/dev/null; then
        return 0
    fi

    if [[ -x "${snap_bin_dir}/${cmd}" ]]; then
        if [[ ":${PATH}:" != *":${snap_bin_dir}:"* ]]; then
            PATH="${snap_bin_dir}:${PATH}"
        fi
        export PATH
        return 0
    fi

    return 1
}

# Exits with a warning message when the named command is not on PATH.
require_cmd() {
    ensure_cmd_on_path "$1" || { warn "Required command not found: $1"; exit 1; }
}
