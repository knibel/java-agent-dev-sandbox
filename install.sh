#!/usr/bin/env bash
# install.sh
# ─────────────────────────────────────────────────────────────────────────────
# One-time setup: builds the Docker image and registers a shell alias so you
# can launch the Java + Copilot sandbox from *any* directory with a single
# command.
#
# What this script does
# ─────────────────────
# 1. Makes start-sandbox.sh executable.
# 2. Builds the Docker image (can be skipped with --no-build).
# 3. Appends a managed shell config block to ~/.bashrc and/or ~/.zshrc:
#
#      export AZURE_DEVOPS_ORG=contoso     # optional
#      alias copilot-sandbox='/path/to/start-sandbox.sh --no-build'
#      # (plus tab-completion for Bash and Zsh)
#
#    The alias always mounts $PWD (evaluated at call time) as /workspace and
#    starts the Copilot CLI there.
#
# Usage
# ─────
#   ./install.sh [options]
#
# Options
#   --no-build          Skip the initial Docker image build
#   --alias <name>      Alias name to register  (default: copilot-sandbox)
#   --devops-org <org>  Persist the Azure DevOps org for future sandbox runs
#   -h, --help          Show this help
#
# Note: the managed shell block stores the absolute path to this repository.
#       If you move the repository, re-run install.sh to update the alias.
#       Precedence: --devops-org overrides AZURE_DEVOPS_ORG for this run;
#       otherwise the current AZURE_DEVOPS_ORG is used, or any saved org is kept.
#
# After installation, reload your shell config or open a new terminal, then
# run from any project directory:
#
#   copilot-sandbox                   # interactive Copilot session
#   copilot-sandbox -- --autopilot -i "Add unit tests"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── shared libraries ──────────────────────────────────────────────────────────
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/shell-config.sh
source "${SCRIPT_DIR}/lib/shell-config.sh"

# ── defaults ──────────────────────────────────────────────────────────────────
SKIP_BUILD=false
ALIAS_NAME="copilot-sandbox"
DEVOPS_ORG_INPUT=""

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            SKIP_BUILD=true
            shift ;;
        --alias)
            ALIAS_NAME="$2"
            shift 2 ;;
        --devops-org)
            DEVOPS_ORG_INPUT="$2"
            shift 2 ;;
        -h|--help)
            sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1 ;;
    esac
done

DEVOPS_ORG=""
if [[ -n "${DEVOPS_ORG_INPUT}" ]]; then
    if ! DEVOPS_ORG="$(normalize_devops_org "${DEVOPS_ORG_INPUT}")"; then
        warn "Invalid Azure DevOps org: ${DEVOPS_ORG_INPUT}"
        warn "Use an org name like 'contoso' or a URL like 'https://dev.azure.com/contoso'."
        exit 1
    fi
elif [[ -n "${AZURE_DEVOPS_ORG:-}" ]]; then
    if ! DEVOPS_ORG="$(normalize_devops_org "${AZURE_DEVOPS_ORG}")"; then
        warn "Invalid AZURE_DEVOPS_ORG value: ${AZURE_DEVOPS_ORG}"
        exit 1
    fi
fi

# ── make launcher executable ──────────────────────────────────────────────────
chmod +x "${SCRIPT_DIR}/start-sandbox.sh"
info "start-sandbox.sh is executable."

# ── build the Docker image ────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
    log "Building Docker image 'java-copilot-sandbox' …"

    # Resolve the latest gh CLI release so the image is never pinned to a
    # stale version.  Falls back gracefully when the API is unreachable.
    LATEST_GH_VERSION=""
    if command -v curl &>/dev/null; then
        GH_API_RESPONSE="$(curl -fsSL "https://api.github.com/repos/cli/cli/releases/latest" 2>/dev/null || true)"
        if [[ -n "${GH_API_RESPONSE}" ]]; then
            if command -v jq &>/dev/null; then
                LATEST_GH_VERSION="$(printf '%s' "${GH_API_RESPONSE}" | jq -r '.tag_name | ltrimstr("v")' 2>/dev/null || true)"
            else
                LATEST_GH_VERSION="$(printf '%s' "${GH_API_RESPONSE}" | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/' || true)"
            fi
        fi
    fi

    GH_BUILD_ARGS=()
    if [[ -n "${LATEST_GH_VERSION}" ]]; then
        info "Using latest gh CLI version: ${LATEST_GH_VERSION}"
        GH_BUILD_ARGS+=("--build-arg" "GH_VERSION=${LATEST_GH_VERSION}")
    else
        warn "Could not determine latest gh CLI version; using Dockerfile default."
    fi

    docker build \
        "${GH_BUILD_ARGS[@]}" \
        -t java-copilot-sandbox \
        "${SCRIPT_DIR}"
    ok "Docker image built."
else
    log "Skipping Docker image build (--no-build)."
fi

# ── register shell alias ──────────────────────────────────────────────────────
# Collect rc files that exist
RC_FILES=()
[[ -f "${HOME}/.bashrc" ]] && RC_FILES+=("${HOME}/.bashrc")
[[ -f "${HOME}/.zshrc" ]]  && RC_FILES+=("${HOME}/.zshrc")

if [[ ${#RC_FILES[@]} -eq 0 ]]; then
    warn "Neither ~/.bashrc nor ~/.zshrc was found."
    warn "Add the following shell config block manually:"
    echo ""
    echo "  ${MANAGED_BLOCK_START}"
    if [[ -n "${DEVOPS_ORG}" ]]; then
        echo "  export AZURE_DEVOPS_ORG=$(shell_escape "${DEVOPS_ORG}")"
    fi
    echo "  alias ${ALIAS_NAME}=$(shell_escape "${SCRIPT_DIR}/start-sandbox.sh --no-build")"
    echo "  # (plus tab-completion – re-run install.sh from a terminal with ~/.bashrc or ~/.zshrc)"
    echo "  ${MANAGED_BLOCK_END}"
    echo ""
    exit 0
fi

log "Registering shell config for '${ALIAS_NAME}' …"
for rc in "${RC_FILES[@]}"; do
    DEVOPS_ORG_TO_WRITE="${DEVOPS_ORG}"
    if [[ -z "${DEVOPS_ORG_TO_WRITE}" ]]; then
        DEVOPS_ORG_TO_WRITE="$(extract_saved_devops_org "${rc}")"
    fi

    if grep -qF "${MANAGED_BLOCK_START}" "${rc}" 2>/dev/null \
            || grep -qF "${LEGACY_MARKER}" "${rc}" 2>/dev/null; then
        ACTION="updated"
    else
        ACTION="added"
    fi

    write_shell_block "${rc}" "${DEVOPS_ORG_TO_WRITE}" "${ALIAS_NAME}" "${SCRIPT_DIR}/start-sandbox.sh --no-build"
    ok "Sandbox config ${ACTION} in ${rc}"
done

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
log "Installation complete."
echo ""
echo "Reload your shell config to activate the alias:"
for rc in "${RC_FILES[@]}"; do
    echo "   source ${rc}"
done
echo ""
if [[ -n "${DEVOPS_ORG}" ]]; then
    echo "Saved Azure DevOps organization: ${DEVOPS_ORG}"
    echo ""
fi
echo "Then launch the sandbox from any project directory:"
echo "   ${ALIAS_NAME}                          # interactive session"
echo "   ${ALIAS_NAME} -- --autopilot -i '…'   # autopilot mode"
