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

# ── version helpers ────────────────────────────────────────────────────────────
# Normalizes versions like "v2.89.0-rc1" to "2.89.0".
normalize_semver() {
    local version="${1#v}"
    version="$(printf '%s' "${version}" | sed -E 's/[^0-9.].*$//')"
    if [[ "${version}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s' "${version}"
        return 0
    fi
    return 1
}

# Returns success when $1 >= $2 (semantic version style numeric compare).
version_gte() {
    local left right max_len i
    local -a left_parts=() right_parts=()
    left="$(normalize_semver "$1")" || return 1
    right="$(normalize_semver "$2")" || return 1

    IFS='.' read -r -a left_parts <<< "${left}"
    IFS='.' read -r -a right_parts <<< "${right}"

    max_len="${#left_parts[@]}"
    if (( ${#right_parts[@]} > max_len )); then
        max_len="${#right_parts[@]}"
    fi

    for (( i=0; i<max_len; i++ )); do
        local left_num="${left_parts[i]:-0}"
        local right_num="${right_parts[i]:-0}"
        if (( 10#${left_num} > 10#${right_num} )); then
            return 0
        fi
        if (( 10#${left_num} < 10#${right_num} )); then
            return 1
        fi
    done

    return 0
}

# ── dependency check ──────────────────────────────────────────────────────────
# Adds /snap/bin to PATH when a command is installed via Snap and the current
# shell PATH does not include that directory. This mutates/export PATH for the
# current shell so later command lookups can resolve the binary too.
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
