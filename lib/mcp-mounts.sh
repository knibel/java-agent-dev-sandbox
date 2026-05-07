#!/usr/bin/env bash
# lib/mcp-mounts.sh – helpers for collecting Docker volume mounts from an
# MCP server configuration file (typically ~/.copilot/mcp-config.json).
#
# Source this file (do not execute it directly):
#   source "${SCRIPT_DIR}/lib/mcp-mounts.sh"
#
# Callers must declare `MOUNTS` as an array before sourcing this file:
#   declare -a MOUNTS=()
#
# After calling scan_mcp_paths the array will contain additional
#   "-v" "<host-path>:<host-path>:ro"
# pairs ready to be passed to `docker run`.

# Guard against being sourced more than once.
[[ -n "${_LIB_MCP_MOUNTS_LOADED:-}" ]] && return 0
_LIB_MCP_MOUNTS_LOADED=1

# add_mount <src> <dst> [<opts>]
# ───────────────────────────────
# Appends a Docker bind-mount entry to the MOUNTS array when <src> exists on
# the host.  <opts> defaults to "ro".  Callers should declare MOUNTS before
# sourcing this library.
add_mount() {
    local src="$1" dst="$2" opts="${3:-ro}"
    if [[ -e "$src" ]]; then
        echo "   Mounting  ${src}  →  ${dst}  (${opts})"
        MOUNTS+=("-v" "${src}:${dst}:${opts}")
    fi
}

# _resolve_mount_dir <path>
# ─────────────────────────
# Given an absolute path that exists on the host, returns the directory that
# should be bind-mounted into the container so that the path (and its
# siblings) are accessible at their original locations.
#
# For files inside a virtual-environment or node_modules tree, the project
# root (the parent of that special directory) is returned so the full
# interpreter and dependency tree is available inside the container.
#
# Exits non-zero and prints nothing for paths that don't exist.
_resolve_mount_dir() {
    local raw_path="$1"
    local local_dir check_dir dir_base

    if [[ -f "$raw_path" ]]; then
        local_dir="$(dirname "$raw_path")"
        check_dir="$local_dir"
        while [[ "$check_dir" != "/" && "$check_dir" != "$HOME" ]]; do
            dir_base="$(basename "$check_dir")"
            if [[ "$dir_base" == ".venv" || "$dir_base" == "venv" || \
                  "$dir_base" == "env"  || "$dir_base" == ".env" || \
                  "$dir_base" == "node_modules" ]]; then
                local_dir="$(dirname "$check_dir")"
                break
            fi
            check_dir="$(dirname "$check_dir")"
        done
    elif [[ -d "$raw_path" ]]; then
        local_dir="$raw_path"
    else
        return 1
    fi

    printf '%s' "$local_dir"
}

# scan_mcp_paths <mcp_config_file>
# ─────────────────────────────────
# Parses <mcp_config_file> with jq and adds a read-only bind-mount to MOUNTS
# for each unique local path referenced by an MCP server's "command" or
# "args" fields.  Requires jq to be on PATH; silently does nothing otherwise.
scan_mcp_paths() {
    local mcp_config="$1"

    if [[ ! -f "${mcp_config}" ]]; then
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        return 0
    fi

    echo "▶  Scanning MCP config for local paths …"

    local raw_path local_dir already_mounted m

    while IFS= read -r raw_path; do
        [[ -z "$raw_path" ]] && continue

        if ! local_dir="$(_resolve_mount_dir "$raw_path")"; then
            continue
        fi

        # Avoid duplicate mounts of the same directory.
        already_mounted=false
        for m in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do
            [[ "$m" == "${local_dir}:${local_dir}:ro" ]] && already_mounted=true && break
        done
        $already_mounted && continue

        echo "   MCP path  ${local_dir}  →  ${local_dir}  (ro)"
        MOUNTS+=("-v" "${local_dir}:${local_dir}:ro")
    done < <(jq -r '
        ( .mcpServers // .servers // {} ) |
        to_entries[].value |
        ( [.command // empty] + (.args // []) ) |
        .[] |
        select(type == "string" and startswith("/"))
    ' "${mcp_config}" 2>/dev/null || true)
}
