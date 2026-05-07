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
# Exits with a warning message when the named command is not on PATH.
require_cmd() {
    command -v "$1" &>/dev/null || { warn "Required command not found: $1"; exit 1; }
}
