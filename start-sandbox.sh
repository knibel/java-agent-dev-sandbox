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
#   --tmp                   Create a temporary directory in /tmp and mount it as /workspace
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
#   # Use a fresh temporary directory as workspace
#   ./start-sandbox.sh --tmp
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
USE_TMP_WORKSPACE=false
SKIP_BUILD=false
EXTRA_BUILD_ARGS=()
COPILOT_CLI_ARGS=()   # args forwarded to the container (after --)

# ── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--workspace)
            WORKSPACE_DIR="$(realpath "$2")"
            shift 2 ;;
        --tmp)
            USE_TMP_WORKSPACE=true
            shift ;;
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

# ── temporary workspace ───────────────────────────────────────────────────────
if [[ "$USE_TMP_WORKSPACE" == true ]]; then
    WORKSPACE_DIR="$(mktemp -d /tmp/sandbox-workspace-XXXXXX)"
    log "Created temporary workspace: ${WORKSPACE_DIR}"
fi

require_cmd docker
command -v jq &>/dev/null || warn "jq not found – MCP config paths will not be auto-mounted"

# ── resolve GitHub token ──────────────────────────────────────────────────────
# Read the host GitHub token so we can forward it into the container as GH_TOKEN.
# The Copilot CLI requires it for authentication, and entrypoint.sh uses it to
# install the agent binary on first run if it is not already cached.
GH_TOKEN_VALUE=""
if command -v gh &>/dev/null; then
    GH_TOKEN_VALUE="$(gh auth token 2>/dev/null || true)"
fi

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

# 1. ~/.copilot  ─  custom instructions AND ~/.copilot/mcp-config.json (read-only)
#    Only the session-state subdirectory is mounted read-write so the Copilot
#    CLI can persist session events (and --resume works across container
#    restarts) without being able to modify any config files on the host.
add_mount "${HOME}/.copilot" "/root/.copilot" "ro"
# 1a. ~/.copilot/session-state  ─  writable overlay for session persistence.
#     Created on the host if it does not yet exist so the mount always succeeds.
mkdir -p "${HOME}/.copilot/session-state"
add_mount "${HOME}/.copilot/session-state" "/root/.copilot/session-state" "rw"

# 2. Parse MCP config for local server paths so those binaries/scripts are
#    accessible inside the container.
MCP_CONFIG="${HOME}/.copilot/mcp-config.json"
if [[ -f "${MCP_CONFIG}" ]] && command -v jq &>/dev/null; then
    log "Scanning MCP config for local paths …"

    # Collect every string value under .mcpServers or .servers that starts with /
    # Covers both "command": "/abs/path" and "args": ["/abs/path", ...]
    while IFS= read -r raw_path; do
        [[ -z "$raw_path" ]] && continue

        # Normalise: if it's a file, find the best ancestor directory to mount.
        # For files inside a virtual-environment (.venv / venv / env / .env) or
        # node_modules, mount the project root (the parent of that directory)
        # so the interpreter and all dependencies are accessible at their
        # original absolute paths inside the container.
        # For ordinary files just use the immediate parent directory.
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

# 4. Copilot CLI agent binary cache
#    The Copilot agent binary is downloaded by `gh copilot version` inside the
#    container on the first run and placed in /root/.local/share/gh/copilot.
#    Bind-mounting a host-side directory read-write means the binary survives
#    container restarts (containers are started with --rm) so the download only
#    ever happens once.  A dedicated path is used so that Linux container
#    binaries are kept separate from any macOS binaries the host may have under
#    ~/.local/share/gh (important when running Docker Desktop on macOS).
COPILOT_BINARY_CACHE="${HOME}/.local/share/java-copilot-sandbox/copilot"
mkdir -p "${COPILOT_BINARY_CACHE}"
info "Copilot cache  ${COPILOT_BINARY_CACHE}  →  /root/.local/share/gh/copilot  (rw)"
MOUNTS+=("-v" "${COPILOT_BINARY_CACHE}:/root/.local/share/gh/copilot:rw")

# 5. Azure CLI credentials (refresh token, MSAL cache, etc.)
#    Mounted read-write so the Azure CLI can persist refreshed access tokens
#    back to the host cache.  Without write access, token-refresh calls fail
#    silently and any MCP server that invokes `az` (e.g. ado-git) will error.
mkdir -p "${HOME}/.azure"
add_mount "${HOME}/.azure" "/root/.azure" "rw"

# 6. GitHub token – forward into the container so the Copilot CLI can
#    authenticate without mounting the host keyring (not available inside the
#    container), and so entrypoint.sh can download the agent binary on first run.
declare -a ENV_ARGS=()
if [[ -n "${GH_TOKEN_VALUE}" ]]; then
    info "Forwarding GitHub token from host gh CLI as GH_TOKEN"
    ENV_ARGS+=("-e" "GH_TOKEN=${GH_TOKEN_VALUE}")
elif command -v gh &>/dev/null; then
    warn "Could not read a GitHub token from 'gh auth token'."
    warn "Run 'gh auth login' on the host first, or the container may prompt for login."
fi

# 7. Workspace directory (read-write so Copilot can edit files)
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
    "${ENV_ARGS[@]}" \
    "${IMAGE_NAME}" \
    "${COPILOT_CLI_ARGS[@]+"${COPILOT_CLI_ARGS[@]}"}"
