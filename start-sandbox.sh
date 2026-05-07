#!/usr/bin/env bash
# start-sandbox.sh
# ─────────────────────────────────────────────────────────────────────────────
# Launches a Java + GitHub Copilot CLI development sandbox inside Docker.
#
# What this script does
# ─────────────────────
# 1. Builds (or reuses) a Docker image based on the Dockerfile in this repo.
# 2. Detects host-side files and mounts them into the container:
#      ~/.copilot             → /root/.copilot-host:ro (instructions + MCP config, copied to writable /root/.copilot by entrypoint)
#      ~/.config/gh           → /root/.config/gh:ro (GitHub / Copilot auth)
#                               NOT mounted in GitHub PAT mode – see below
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

# ── resolve GitHub authentication mode ───────────────────────────────────────
# Detects early whether to use PAT mode or GitHub CLI mode, because the result
# controls whether ~/.config/gh is mounted in the section below.
# Full credential handling (env-file, info messages) is done in the
# "collect environment variables" section alongside Azure DevOps auth.
GH_PAT_VALUE=""
if command -v secret-tool &>/dev/null; then
    GH_PAT_VALUE="$(secret-tool lookup service github-pat account default 2>/dev/null || true)"
fi
GH_PAT_MODE=false
GH_TOKEN_VALUE=""
if [[ -n "${GH_PAT_VALUE}" ]]; then
    GH_PAT_MODE=true
elif command -v gh &>/dev/null; then
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
#    Mounted at a staging path (/root/.copilot-host) so that entrypoint.sh can
#    copy the contents into /root/.copilot (a plain container-local directory)
#    before starting the CLI.  This lets the Copilot CLI write files such as
#    settings.json (e.g. when changing the model) without touching the host.
add_mount "${HOME}/.copilot" "/root/.copilot-host" "ro"
# 1a. ~/.copilot/session-state  ─  writable bind-mount for session persistence.
#     Mounted directly at /root/.copilot/session-state so that session events
#     are persisted back to the host (--resume works across restarts) even
#     though the rest of /root/.copilot is container-local and writable.
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
#    Not mounted in GitHub PAT mode – the container authenticates via GH_TOKEN only.
if [[ "${GH_PAT_MODE}" == false ]]; then
    add_mount "${HOME}/.config/gh" "/root/.config/gh" "ro"
fi

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

# ── collect environment variables ─────────────────────────────────────────────
declare -a ENV_ARGS=()

# 5. Azure DevOps credentials – two mutually exclusive modes:
#
#    Mode A – PAT from Linux keychain (preferred, least-privilege):
#      Read a Personal Access Token stored with:
#        secret-tool store --label "Azure DevOps PAT" \
#                          service azure-devops-pat account default
#      When a PAT is found:
#        • The token is forwarded as AZURE_DEVOPS_EXT_PAT (used by `az devops`
#          and many ADO MCP servers).
#        • ADO_PAT_MODE=1 is set so entrypoint.sh knows to restrict `az`:
          only `az devops` subcommands are allowed (they authenticate via
          AZURE_DEVOPS_EXT_PAT); all other `az` commands are blocked.
#        • The host ~/.azure directory is NOT mounted, keeping the container
#          isolated from broader Azure CLI credentials.
#
#    Mode B – Azure CLI credentials (automatic fallback):
#      When no PAT is found (or secret-tool is not installed), ~/.azure is
#      mounted read-write so the Azure CLI can read cached tokens and persist
#      refreshed ones.  The container's `az login` prompt is preserved.
ADO_PAT_VALUE=""
if command -v secret-tool &>/dev/null; then
    ADO_PAT_VALUE="$(secret-tool lookup service azure-devops-pat account default 2>/dev/null || true)"
fi

if [[ -n "${ADO_PAT_VALUE}" ]]; then
    info "Azure DevOps PAT found in keychain – using PAT mode (only az devops commands allowed)"
    ENV_ARGS+=("-e" "ADO_PAT_MODE=1")
    # Write the PAT to a private temp env-file so it does not appear in the
    # docker run command line or `ps` output.  The file is removed after the
    # container exits via a trap registered below.
    ADO_ENV_FILE="$(mktemp)"
    chmod 600 "${ADO_ENV_FILE}"
    printf 'AZURE_DEVOPS_EXT_PAT=%s\n' "${ADO_PAT_VALUE}" > "${ADO_ENV_FILE}"
else
    if ! command -v secret-tool &>/dev/null; then
        info "secret-tool not installed – falling back to Azure CLI credentials (~/.azure mount)"
        info "Install libsecret-tools and store a PAT to use least-privilege PAT mode:"
        info "  secret-tool store --label 'Azure DevOps PAT' service azure-devops-pat account default"
    else
        info "No Azure DevOps PAT found in keychain – falling back to Azure CLI credentials (~/.azure mount)"
        info "To use least-privilege PAT mode:"
        info "  secret-tool store --label 'Azure DevOps PAT' service azure-devops-pat account default"
    fi
    mkdir -p "${HOME}/.azure"
    add_mount "${HOME}/.azure" "/root/.azure" "rw"
fi

# Register a cleanup trap to remove the PAT env-files (if created) once the
# container exits, regardless of whether it exits normally or is interrupted.
ADO_ENV_FILE="${ADO_ENV_FILE:-}"
GH_ENV_FILE="${GH_ENV_FILE:-}"
cleanup_env_files() {
    # Guard: only delete if the path was set and is under /tmp (safety check).
    [[ -n "${ADO_ENV_FILE}" && "${ADO_ENV_FILE}" =~ ^/tmp/ ]] && rm -f "${ADO_ENV_FILE}"
    [[ -n "${GH_ENV_FILE}"  && "${GH_ENV_FILE}"  =~ ^/tmp/ ]] && rm -f "${GH_ENV_FILE}"
}
trap cleanup_env_files EXIT INT TERM

# Build optional --env-file arguments for the PAT env-files (empty when not in PAT mode).
declare -a ADO_ENV_FILE_ARGS=()
if [[ -n "${ADO_ENV_FILE}" ]]; then
    ADO_ENV_FILE_ARGS+=("--env-file" "${ADO_ENV_FILE}")
fi

declare -a GH_ENV_FILE_ARGS=()

# 6. GitHub credentials – two mutually exclusive modes:
#
#    Mode A – PAT from Linux keychain (preferred, least-privilege):
#      Read a Personal Access Token stored with:
#        secret-tool store --label "GitHub PAT" \
#                          service github-pat account default
#      When a PAT is found:
#        • The token is forwarded as GH_TOKEN (used by `gh` and the Copilot CLI).
#        • GH_PAT_MODE=1 is set so entrypoint.sh can print an info message.
#        • ~/.config/gh is NOT mounted (see section 3 above), keeping the
#          container isolated from broader GitHub CLI credentials.
#
#    Mode B – GitHub CLI credentials (automatic fallback):
#      ~/.config/gh is mounted read-only (section 3 above) and the token read
#      by `gh auth token` is forwarded as GH_TOKEN so the Copilot CLI can
#      authenticate without mounting the host keyring (not available inside
#      the container). entrypoint.sh also uses it to download the agent binary
#      on first run.
GH_ENV_FILE=""
if [[ "${GH_PAT_MODE}" == true && -n "${GH_PAT_VALUE}" ]]; then
    info "GitHub PAT found in keychain – using PAT mode (~/.config/gh will not be mounted)"
    ENV_ARGS+=("-e" "GH_PAT_MODE=1")
    # Write the PAT to a private temp env-file so it does not appear in the
    # docker run command line or `ps` output.  The file is removed after the
    # container exits via a trap registered above.
    GH_ENV_FILE="$(mktemp)"
    chmod 600 "${GH_ENV_FILE}"
    printf 'GH_TOKEN=%s\n' "${GH_PAT_VALUE}" > "${GH_ENV_FILE}"
    GH_ENV_FILE_ARGS+=("--env-file" "${GH_ENV_FILE}")
elif [[ -n "${GH_TOKEN_VALUE}" ]]; then
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
    "${ADO_ENV_FILE_ARGS[@]+"${ADO_ENV_FILE_ARGS[@]}"}" \
    "${GH_ENV_FILE_ARGS[@]+"${GH_ENV_FILE_ARGS[@]}"}" \
    "${IMAGE_NAME}" \
    "${COPILOT_CLI_ARGS[@]+"${COPILOT_CLI_ARGS[@]}"}"
