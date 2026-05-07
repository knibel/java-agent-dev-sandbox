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
#      /var/run/docker.sock    → /var/run/docker.sock:rw
#                               (host Docker daemon for Testcontainers)
#      ~/.azure               not mounted (Azure DevOps PAT-only auth)
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
#   --auto-update           Check for and apply the latest sandbox release before launch
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

# ── shared libraries ──────────────────────────────────────────────────────────
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/mcp-mounts.sh
source "${SCRIPT_DIR}/lib/mcp-mounts.sh"
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"

# ── defaults ─────────────────────────────────────────────────────────────────
IMAGE_NAME="java-copilot-sandbox"
WORKSPACE_DIR="$(pwd)"
USE_TMP_WORKSPACE=false
SKIP_BUILD=false
AUTO_UPDATE=false
EXTRA_BUILD_ARGS=()
COPILOT_CLI_ARGS=()   # args forwarded to the container (after --)

prompt_for_auto_update() {
    local current_tag="$1"
    local latest_tag="$2"
    local reply

    if [[ -t 0 && -t 1 ]]; then
        printf "A newer sandbox release is available (%s → %s). Update now? [Y/n] " "${current_tag:-unknown}" "${latest_tag}"
        read -r reply
        [[ ! "${reply}" =~ ^[Nn]$ ]]
    else
        return 0
    fi
}

maybe_auto_update() {
    local current_tag latest_tag
    local -a install_args=("--update")

    [[ "${AUTO_UPDATE}" == true ]] || return 0

    if ! command -v gh &>/dev/null; then
        warn "gh is required for --auto-update; continuing without updating."
        return 0
    fi

    latest_tag="$(latest_release_tag 2>/dev/null || true)"
    if [[ -z "${latest_tag}" ]]; then
        warn "Could not determine the latest sandbox release; continuing without updating."
        return 0
    fi

    current_tag="$(detect_installed_release_tag "${SCRIPT_DIR}")"
    if [[ -n "${current_tag}" && "${current_tag}" == "${latest_tag}" ]]; then
        info "Sandbox release ${latest_tag} is already installed."
        return 0
    fi

    if ! prompt_for_auto_update "${current_tag}" "${latest_tag}"; then
        info "Skipping sandbox update."
        return 0
    fi

    log "Applying sandbox update before launch …"
    if [[ -n "${AZURE_DEVOPS_ORG:-}" ]]; then
        install_args+=("--devops-org" "${AZURE_DEVOPS_ORG}")
    fi
    bash "${SCRIPT_DIR}/install.sh" "${install_args[@]}"

    if [[ "${IMAGE_NAME}" == "java-copilot-sandbox" && ${#EXTRA_BUILD_ARGS[@]} -eq 0 ]]; then
        SKIP_BUILD=true
    fi
}

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
        --auto-update)
            AUTO_UPDATE=true
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

# ── temporary workspace ───────────────────────────────────────────────────────
if [[ "$USE_TMP_WORKSPACE" == true ]]; then
    WORKSPACE_DIR="$(mktemp -d /tmp/sandbox-workspace-XXXXXX)"
    log "Created temporary workspace: ${WORKSPACE_DIR}"
fi

require_cmd docker
command -v jq &>/dev/null || warn "jq not found – MCP config paths will not be auto-mounted"

maybe_auto_update

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
declare -a ENV_ARGS=()
declare -a DOCKER_RUN_EXTRA_ARGS=()

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
scan_mcp_paths "${MCP_CONFIG}"

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

# 5. Host Docker daemon socket (required for Testcontainers and similar tools)
#    Mounted at the same path inside the sandbox so Docker clients in the
#    container can talk to the host daemon.
if [[ -S "/var/run/docker.sock" ]]; then
    info "Docker socket  /var/run/docker.sock  →  /var/run/docker.sock  (rw)"
    MOUNTS+=("-v" "/var/run/docker.sock:/var/run/docker.sock:rw")
    # Ensure Docker clients use the mounted Unix socket by default.
    ENV_ARGS+=("-e" "DOCKER_HOST=unix:///var/run/docker.sock")
    # Testcontainers connectivity helper:
    # resolve host.docker.internal to the host gateway from inside the sandbox
    # and use that hostname as the container host override.
    ENV_ARGS+=("-e" "TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal")
    DOCKER_RUN_EXTRA_ARGS+=("--add-host" "host.docker.internal:host-gateway")
else
    warn "Host Docker socket not found at /var/run/docker.sock; Testcontainers may not work in the sandbox."
fi

# ── collect environment variables ─────────────────────────────────────────────

# 5. Azure DevOps credentials – optional PAT mode:
#    Read a Personal Access Token stored with:
#      secret-tool store --label "Azure DevOps PAT" \
#                        service azure-devops-pat account default
#    The token is forwarded as AZURE_DEVOPS_EXT_PAT (used by `az devops`
#    and the native Azure DevOps skill in entrypoint.sh). ADO_PAT_MODE=1 is set so entrypoint.sh knows
#    to restrict `az` to Azure DevOps extension command groups only.
#    The host ~/.azure directory is never mounted.
#    If no PAT is found, the sandbox still starts; Azure DevOps features are
#    simply unavailable.
ADO_PAT_VALUE=""
if command -v secret-tool &>/dev/null; then
    ADO_PAT_VALUE="$(secret-tool lookup service azure-devops-pat account default 2>/dev/null || true)"
fi

if [[ -n "${ADO_PAT_VALUE}" ]]; then
    info "Azure DevOps PAT found in keychain – using PAT mode (only Azure DevOps az command groups allowed)"
    ENV_ARGS+=("-e" "ADO_PAT_MODE=1")
    # Write the PAT to a private temp env-file so it does not appear in the
    # docker run command line or `ps` output.  The file is removed after the
    # container exits via a trap registered below.
    ADO_ENV_FILE="$(mktemp)"
    chmod 600 "${ADO_ENV_FILE}"
    printf 'AZURE_DEVOPS_EXT_PAT=%s\n' "${ADO_PAT_VALUE}" > "${ADO_ENV_FILE}"
else
    if ! command -v secret-tool &>/dev/null; then
        warn "secret-tool not found; starting without Azure DevOps integration."
    else
        warn "No Azure DevOps PAT found; starting without Azure DevOps integration."
    fi
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

# 5a. Optional Azure DevOps organization name:
#     AZURE_DEVOPS_ORG is forwarded into the container so entrypoint.sh can
#     pre-configure az devops defaults (az devops configure) and include the
#     org in the Azure DevOps native skill instructions.
if [[ -n "${AZURE_DEVOPS_ORG:-}" ]]; then
    info "Forwarding Azure DevOps organization: ${AZURE_DEVOPS_ORG}"
    ENV_ARGS+=("-e" "AZURE_DEVOPS_ORG=${AZURE_DEVOPS_ORG}")
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
    "${DOCKER_RUN_EXTRA_ARGS[@]+"${DOCKER_RUN_EXTRA_ARGS[@]}"}" \
    "${MOUNTS[@]}" \
    "${ENV_ARGS[@]}" \
    "${ADO_ENV_FILE_ARGS[@]+"${ADO_ENV_FILE_ARGS[@]}"}" \
    "${GH_ENV_FILE_ARGS[@]+"${GH_ENV_FILE_ARGS[@]}"}" \
    "${IMAGE_NAME}" \
    "${COPILOT_CLI_ARGS[@]+"${COPILOT_CLI_ARGS[@]}"}"
