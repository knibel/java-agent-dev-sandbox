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
#
# After installation, reload your shell config or open a new terminal, then
# run from any project directory:
#
#   copilot-sandbox                   # interactive Copilot session
#   copilot-sandbox -- --autopilot -i "Add unit tests"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults ──────────────────────────────────────────────────────────────────
SKIP_BUILD=false
ALIAS_NAME="copilot-sandbox"
DEVOPS_ORG_INPUT=""
MANAGED_BLOCK_START="# >>> java-agent-dev-sandbox >>>"
MANAGED_BLOCK_END="# <<< java-agent-dev-sandbox <<<"
LEGACY_MARKER="# java-agent-dev-sandbox"

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

# ── helpers ───────────────────────────────────────────────────────────────────
log()  { echo "▶  $*"; }
info() { echo "   $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠  $*" >&2; }

normalize_devops_org() {
    local raw="$1"

    case "${raw}" in
        https://dev.azure.com/*)
            raw="${raw#https://dev.azure.com/}" ;;
        http://dev.azure.com/*)
            raw="${raw#http://dev.azure.com/}" ;;
    esac

    if [[ "${raw}" =~ ^https?://([^./]+)\.visualstudio\.com(/.*)?$ ]]; then
        raw="${BASH_REMATCH[1]}"
    fi

    raw="${raw%/}"

    if [[ -z "${raw}" || "${raw}" == *[[:space:]]* || "${raw}" == */* ]]; then
        return 1
    fi

    printf '%s' "${raw}"
}

shell_escape() {
    printf '%q' "$1"
}

extract_saved_devops_org() {
    local rc_file="$1"
    local line value

    line="$(
        sed -n "\%^${MANAGED_BLOCK_START}\$%,\%^${MANAGED_BLOCK_END}\$%p" "${rc_file}" \
            | grep '^export AZURE_DEVOPS_ORG=' \
            | head -1 \
            || true
    )"

    value="${line#export AZURE_DEVOPS_ORG=}"
    if [[ -n "${value}" && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:-1}"
    elif [[ -n "${value}" && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:-1}"
    fi

    printf '%s' "${value}"
}

write_shell_block() {
    local rc_file="$1"
    local org_value="$2"
    local alias_command tmp_file

    alias_command="${SCRIPT_DIR}/start-sandbox.sh --no-build"
    tmp_file="$(mktemp)"

    awk \
        -v start="${MANAGED_BLOCK_START}" \
        -v end="${MANAGED_BLOCK_END}" \
        -v legacy="${LEGACY_MARKER}" '
        $0 == start { skip=1; next }
        $0 == end { skip=0; next }
        skip { next }
        $0 == legacy { skip_legacy=1; next }
        # Older installs wrote a single marker line followed by one alias line.
        skip_legacy && $0 ~ /^alias[[:space:]]+/ { skip_legacy=0; next }
        skip_legacy { skip_legacy=0 }
        { print }
    ' "${rc_file}" > "${tmp_file}"

    printf '\n%s\n' "${MANAGED_BLOCK_START}" >> "${tmp_file}"
    if [[ -n "${org_value}" ]]; then
        printf 'export AZURE_DEVOPS_ORG=%s\n' "$(shell_escape "${org_value}")" >> "${tmp_file}"
    fi
    printf 'alias %s=%s\n' "${ALIAS_NAME}" "$(shell_escape "${alias_command}")" >> "${tmp_file}"
    printf '%s\n' "${MANAGED_BLOCK_END}" >> "${tmp_file}"

    mv "${tmp_file}" "${rc_file}"
}

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
    echo "  ${MANAGED_BLOCK_END}"
    echo ""
    exit 0
fi

log "Registering shell config for '${ALIAS_NAME}' …"
for rc in "${RC_FILES[@]}"; do
    SAVED_DEVOPS_ORG="${DEVOPS_ORG}"
    if [[ -z "${SAVED_DEVOPS_ORG}" ]]; then
        SAVED_DEVOPS_ORG="$(extract_saved_devops_org "${rc}")"
    fi

    if grep -qF "${MANAGED_BLOCK_START}" "${rc}" 2>/dev/null \
            || grep -qF "${LEGACY_MARKER}" "${rc}" 2>/dev/null; then
        ACTION="updated"
    else
        ACTION="added"
    fi

    write_shell_block "${rc}" "${SAVED_DEVOPS_ORG}"
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
