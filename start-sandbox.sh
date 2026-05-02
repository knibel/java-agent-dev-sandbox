#!/usr/bin/env bash
# start-sandbox.sh
# ─────────────────────────────────────────────────────────────────────────────
# Launches a Java + GitHub Copilot CLI development sandbox inside Docker.
#
# What this script does
# ─────────────────────
# 1. Builds (or reuses) a Docker image based on the Dockerfile in this repo.
# 2. Detects host-side files and mounts them into the container:
#      ~/.copilot             → /root/.copilot:ro   (instructions + MCP config)
#      ~/.config/gh           → /root/.config/gh:ro (GitHub / Copilot auth)
#      ~/.local/share/gh/copilot
#                             → /root/.local/share/gh/copilot:ro
#                                                   (pre-downloaded CLI binary)
#      ~/.azure               → /root/.azure:ro     (Azure CLI tokens)
#      <workspace>            → /workspace:rw       (your project)
# 3. Parses ~/.copilot/mcp-config.json and mounts any local paths that MCP
#    server definitions reference (commands and arguments that are absolute
#    filesystem paths).
# 4. Drops you directly into the GitHub Copilot CLI.
#
# Usage
# ─────
#   ./start-sandbox.sh [options] [-- <copilot-cli-args>]
#
# Options
#   -w, --workspace <dir>   Directory to mount as /workspace (default: $PWD)
#   -i, --image <name>      Docker image name/tag            (default: java-copilot-sandbox)
#   --no-build              Skip image rebuild (use existing image)
#   --build-arg <ARG=VAL>   Pass extra build args to `docker build`
#   -h, --help              Show this help
#
# Anything after `--` is passed verbatim to the Copilot CLI inside the
# container.  If nothing is passed the CLI starts in interactive mode with
# --allow-all.
#
# Examples
#   # Basic interactive session
#   ./start-sandbox.sh
#
#   # Mount a specific project directory
#   ./start-sandbox.sh -w ~/projects/my-spring-app
#
#   # Override Java version at build time
#   ./start-sandbox.sh --build-arg JAVA_VERSION=21.0.5-tem
#
#   # Start Copilot in autopilot mode
#   ./start-sandbox.sh -- --autopilot -i "Add unit tests to every class"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults ─────────────────────────────────────────────────────────────────
IMAGE_NAME="java-copilot-sandbox"
WORKSPACE_DIR="$(pwd)"
SKIP_BUILD=false
EXTRA_BUILD_ARGS=()
COPILOT_CLI_ARGS=()   # args forwarded to the container (after --)

# ── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--workspace)
            WORKSPACE_DIR="$(realpath "$2")"
            shift 2 ;;
        -i|--image)
            IMAGE_NAME="$2"
            shift 2 ;;
        --no-build)
            SKIP_BUILD=true
            shift ;;
        --build-arg)
            EXTRA_BUILD_ARGS+=("--build-arg" "$2")
            shift 2 ;;
        -h|--help)
            sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        --)
            shift
            COPILOT_CLI_ARGS=("$@")
            break ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1 ;;
    esac
done

# ── helpers ───────────────────────────────────────────────────────────────────
log()  { echo "▶  $*"; }
info() { echo "   $*"; }
warn() { echo "⚠  $*" >&2; }

require_cmd() {
    command -v "$1" &>/dev/null || { warn "Required command not found: $1"; exit 1; }
}

require_cmd docker
command -v jq &>/dev/null || warn "jq not found – MCP config paths will not be auto-mounted"

# ── build image ───────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
    log "Building Docker image '${IMAGE_NAME}' …"
    docker build \
        "${EXTRA_BUILD_ARGS[@]}" \
        -t "${IMAGE_NAME}" \
        "${SCRIPT_DIR}"
    log "Image built successfully."
else
    log "Skipping build (--no-build)."
fi

# ── collect volume mounts ─────────────────────────────────────────────────────
declare -a MOUNTS=()

# helper: add a bind-mount only if the source exists, print what we're doing
add_mount() {
    local src="$1" dst="$2" opts="${3:-ro}"
    if [[ -e "$src" ]]; then
        info "Mounting  ${src}  →  ${dst}  (${opts})"
        MOUNTS+=("-v" "${src}:${dst}:${opts}")
    fi
}

# 1. ~/.copilot  ─  custom instructions AND ~/.copilot/mcp-config.json
add_mount "${HOME}/.copilot" "/root/.copilot" "ro"

# 2. Parse MCP config for local server paths so those binaries/scripts are
#    accessible inside the container.
MCP_CONFIG="${HOME}/.copilot/mcp-config.json"
if [[ -f "${MCP_CONFIG}" ]] && command -v jq &>/dev/null; then
    log "Scanning MCP config for local paths …"

    # Collect every string value under .mcpServers or .servers that starts with /
    # Covers both "command": "/abs/path" and "args": ["/abs/path", ...]
    while IFS= read -r raw_path; do
        [[ -z "$raw_path" ]] && continue

        # Normalise: if it's a file use its parent dir; if already a dir use it
        if [[ -f "$raw_path" ]]; then
            local_dir="$(dirname "$raw_path")"
        elif [[ -d "$raw_path" ]]; then
            local_dir="$raw_path"
        else
            # Path doesn't exist on this host – skip silently
            continue
        fi

        # Avoid duplicate mounts of the same directory
        already_mounted=false
        for m in "${MOUNTS[@]}"; do
            [[ "$m" == "${local_dir}:${local_dir}:ro" ]] && already_mounted=true && break
        done
        $already_mounted && continue

        info "MCP path  ${local_dir}  →  ${local_dir}  (ro)"
        MOUNTS+=("-v" "${local_dir}:${local_dir}:ro")
    done < <(jq -r '
        ( .mcpServers // .servers // {} ) |
        to_entries[].value |
        ( [.command // empty] + (.args // []) ) |
        .[] |
        select(type == "string" and startswith("/"))
    ' "${MCP_CONFIG}" 2>/dev/null || true)
fi

# 3. GitHub CLI config  ─  stores the Copilot auth token
add_mount "${HOME}/.config/gh" "/root/.config/gh" "ro"

# 4. Pre-downloaded Copilot CLI binary  ─  avoids re-download on every run.
#    Only useful when host OS is also Linux (same binary architecture).
if [[ "$(uname -s)" == "Linux" ]]; then
    add_mount "${HOME}/.local/share/gh/copilot" "/root/.local/share/gh/copilot" "ro"
fi

# 5. Azure CLI credentials (refresh token, MSAL cache, etc.)
add_mount "${HOME}/.azure" "/root/.azure" "ro"

# 6. Workspace directory (read-write so Copilot can edit files)
if [[ -d "${WORKSPACE_DIR}" ]]; then
    info "Workspace ${WORKSPACE_DIR}  →  /workspace  (rw)"
    MOUNTS+=("-v" "${WORKSPACE_DIR}:/workspace")
else
    warn "Workspace directory not found: ${WORKSPACE_DIR}; container will start without it."
fi

# ── run container ─────────────────────────────────────────────────────────────
log "Starting sandbox …"
echo ""

# -it           interactive + TTY so the Copilot REPL works
# --rm          clean up the container when it exits
# --name        give it a recognisable name (timestamped for uniqueness)
CONTAINER_NAME="${IMAGE_NAME}-$(date +%s)"

docker run \
    --interactive \
    --tty \
    --rm \
    --name "${CONTAINER_NAME}" \
    "${MOUNTS[@]}" \
    "${IMAGE_NAME}" \
    "${COPILOT_CLI_ARGS[@]+"${COPILOT_CLI_ARGS[@]}"}"
