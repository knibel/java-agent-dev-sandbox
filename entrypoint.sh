#!/usr/bin/env bash
# entrypoint.sh – container entrypoint
# Initialises SDKMAN, then hands control directly to the GitHub Copilot CLI.
#
# Any arguments passed to `docker run` are forwarded verbatim to the
# Copilot CLI, so you can do things like:
#
#   docker run -it ... java-copilot-sandbox --model gpt-4.1
#   docker run -it ... java-copilot-sandbox --resume
#   docker run -it ... java-copilot-sandbox -i "scaffold a Spring Boot app"
#
# If no arguments are given the CLI starts in interactive mode with
# --allow-all (all tools + paths + URLs permitted).

set -euo pipefail

# ── SDKMAN ───────────────────────────────────────────────────────────────────
# sdkman-init.sh references variables (e.g. SDKMAN_CANDIDATES_API) before they
# are assigned, which conflicts with `set -u`.  Disable that check temporarily.
# shellcheck source=/dev/null
if [[ -f "${SDKMAN_DIR:-/root/.sdkman}/bin/sdkman-init.sh" ]]; then
    set +u
    source "${SDKMAN_DIR:-/root/.sdkman}/bin/sdkman-init.sh"
    set -u
fi

# ── GitHub authentication ─────────────────────────────────────────────────────
# If ~/.config/gh was not mounted from the host (or has no valid token), walk
# the user through `gh auth login` before trying to start the Copilot CLI.
# Without a token the CLI will fail immediately anyway, so this is friendlier.
#
# Note: `gh auth status` only checks file-based credentials – it does NOT
# recognise tokens supplied via GH_TOKEN / GITHUB_TOKEN.  Skip the prompt
# when either of those env vars is already set (start-sandbox.sh forwards the
# host token this way).
if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]] && ! gh auth status &>/dev/null; then
    echo ""
    echo "⚠  No GitHub authentication found."
    echo "   Please log in so the Copilot CLI can access the API."
    echo "   You can authenticate via a web browser (--web) or by pasting a personal access token."
    echo ""
    gh auth login
    echo ""
fi

# ── Azure authentication ──────────────────────────────────────────────────────
# If the Azure CLI is present and no valid subscription is active, walk the user
# through `az login` before launching Copilot.  MCP servers that call Azure
# DevOps APIs (e.g. ado-git) will fail immediately without a valid session, so
# catching this early gives a much friendlier experience.
#
# ~/.azure is mounted read-write by start-sandbox.sh so that refreshed tokens
# are persisted back to the host cache across container restarts.
if command -v az &>/dev/null && ! az account show &>/dev/null 2>&1; then
    echo ""
    echo "⚠  No Azure authentication found."
    echo "   MCP servers that use Azure DevOps (e.g. ado-git) require an Azure login."
    echo "   Please log in now (a browser tab will open, or use --use-device-code)."
    echo ""
    az login
    echo ""
fi

# ── ensure Copilot CLI agent binary is installed ─────────────────────────────
# The binary is cached in a host-side directory mounted read-write by
# start-sandbox.sh (/root/.local/share/gh/copilot), so this download only
# ever happens once – on the very first container start.
# Show a message when downloading so the user knows what is happening; show a
# warning (without aborting) if the download fails so the main CLI invocation
# can surface the prompt itself.
printf 'y\n' | gh copilot version > /dev/null \
    || echo "⚠  Copilot CLI agent could not be installed; the CLI may prompt to install on launch."

# ── default Copilot CLI arguments ────────────────────────────────────────────
# COPILOT_EXTRA_ARGS may be set via `docker run -e COPILOT_EXTRA_ARGS=...`
# to pass additional flags without overriding the defaults below.
DEFAULT_COPILOT_ARGS=(
    --allow-all   # shorthand for --allow-all-tools --allow-all-paths --allow-all-urls
)

# Merge env-supplied extras
EXTRA_ARGS=()
if [[ -n "${COPILOT_EXTRA_ARGS:-}" ]]; then
    # word-split intentionally here
    # shellcheck disable=SC2206
    EXTRA_ARGS=( ${COPILOT_EXTRA_ARGS} )
fi

# ── launch ───────────────────────────────────────────────────────────────────
# If the caller passed arguments, those completely replace the defaults so
# the user has full control.  Otherwise we launch with --allow-all.
if [[ $# -gt 0 ]]; then
    exec gh copilot -- "${EXTRA_ARGS[@]}" "$@"
else
    exec gh copilot -- "${DEFAULT_COPILOT_ARGS[@]}" "${EXTRA_ARGS[@]}"
fi
