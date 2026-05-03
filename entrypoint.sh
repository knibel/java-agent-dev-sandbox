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
