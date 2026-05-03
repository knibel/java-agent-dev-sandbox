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
# 3. Appends a shell alias to ~/.bashrc and/or ~/.zshrc:
#
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
#   -h, --help          Show this help
#
# Note: the alias stores the absolute path to this repository at install time.
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

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            SKIP_BUILD=true
            shift ;;
        --alias)
            ALIAS_NAME="$2"
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
ALIAS_LINE="alias ${ALIAS_NAME}='${SCRIPT_DIR}/start-sandbox.sh --no-build'"
MARKER="# java-agent-dev-sandbox"

# Collect rc files that exist
RC_FILES=()
[[ -f "${HOME}/.bashrc" ]] && RC_FILES+=("${HOME}/.bashrc")
[[ -f "${HOME}/.zshrc" ]]  && RC_FILES+=("${HOME}/.zshrc")

if [[ ${#RC_FILES[@]} -eq 0 ]]; then
    warn "Neither ~/.bashrc nor ~/.zshrc was found."
    warn "Add the following line to your shell configuration manually:"
    echo ""
    echo "  ${ALIAS_LINE}"
    echo ""
    exit 0
fi

log "Registering alias '${ALIAS_NAME}' …"
for rc in "${RC_FILES[@]}"; do
    if grep -qF "${MARKER}" "${rc}" 2>/dev/null; then
        info "Alias already present in ${rc} — skipping."
    else
        printf '\n%s\n%s\n' "${MARKER}" "${ALIAS_LINE}" >> "${rc}"
        ok "Alias added to ${rc}"
    fi
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
echo "Then launch the sandbox from any project directory:"
echo "   ${ALIAS_NAME}                          # interactive session"
echo "   ${ALIAS_NAME} -- --autopilot -i '…'   # autopilot mode"
