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

# ── copy host ~/.copilot config to writable container directory ───────────────
# start-sandbox.sh mounts the host ~/.copilot at /root/.copilot-host (read-only)
# so the Copilot CLI cannot accidentally modify host config files.  Here we copy
# the contents into /root/.copilot (a plain, writable container directory) so
# that the CLI can freely write files such as settings.json (e.g. when the user
# changes the model).  The session-state subdirectory is excluded because it
# already has its own read-write bind-mount at /root/.copilot/session-state.
if [[ -d /root/.copilot-host ]]; then
    mkdir -p /root/.copilot
    find /root/.copilot-host -mindepth 1 -maxdepth 1 ! -name 'session-state' \
        -exec cp -r {} /root/.copilot/ \;
fi

# ── Java LSP MCP server ───────────────────────────────────────────────────────
# Automatically register the Eclipse JDT Language Server as an MCP tool-server
# so the Copilot CLI can navigate Java code (go-to-definition, references,
# diagnostics, hover, rename, …) without any manual configuration.
#
# The entry is only injected when:
#   • jq        – available (needed to read/write the JSON config)
#   • mcp-language-server – installed in the image (LSP → MCP bridge)
#   • jdtls     – installed in the image (Eclipse JDT Language Server wrapper)
#   • the "java-language-server" key is NOT already present in the config
#     (lets users override the entry in their own ~/.copilot/mcp-config.json)
if command -v jq &>/dev/null \
        && command -v mcp-language-server &>/dev/null \
        && command -v jdtls &>/dev/null; then
    MCP_CONFIG="/root/.copilot/mcp-config.json"
    mkdir -p /root/.copilot
    # Seed a minimal config when none was copied from the host.
    if [[ ! -f "${MCP_CONFIG}" ]]; then
        echo '{"mcpServers":{}}' > "${MCP_CONFIG}"
    fi
    # Add the Java LSP entry only when not already present.
    if ! jq -e '.mcpServers["java-language-server"] // empty' \
            "${MCP_CONFIG}" &>/dev/null; then
        tmp_cfg="$(mktemp)"
        if jq '.mcpServers["java-language-server"] = {
            "command": "mcp-language-server",
            "args": ["--workspace", "/workspace", "--lsp", "jdtls"]
        }' "${MCP_CONFIG}" > "${tmp_cfg}" \
                && mv "${tmp_cfg}" "${MCP_CONFIG}"; then
            echo "✓  Java LSP registered (mcp-language-server → jdtls)"
        else
            rm -f "${tmp_cfg}"
        fi
    fi
fi

# ── Java LSP native skill (fallback when MCP is disabled) ────────────────────
# Copilot CLI has built-in LSP support via ~/.copilot/lsp-config.json.
# When MCP is disabled (or not available), Copilot falls back to this native
# language-server channel for go-to-definition, references, hover, rename, etc.
#
# We register jdtls directly (no mcp-language-server bridge needed) so that
# the native skill works independently of the MCP configuration above.
# The entry is only injected when:
#   • jq    – available
#   • jdtls – installed in the image
#   • the "java" server key is NOT already present in the config
#     (lets users supply their own ~/.copilot/lsp-config.json)
if command -v jq &>/dev/null && command -v jdtls &>/dev/null; then
    LSP_CONFIG="/root/.copilot/lsp-config.json"
    mkdir -p /root/.copilot
    # Seed a minimal config when none exists.
    if [[ ! -f "${LSP_CONFIG}" ]]; then
        echo '{"lspServers":{}}' > "${LSP_CONFIG}"
    fi
    # Add the Java entry only when not already present.
    if ! jq -e '.lspServers["java"] // empty' "${LSP_CONFIG}" &>/dev/null; then
        tmp_lsp="$(mktemp)"
        if jq '.lspServers["java"] = {
            "command": "jdtls",
            "args": [],
            "fileExtensions": { ".java": "java" }
        }' "${LSP_CONFIG}" > "${tmp_lsp}"; then
            if mv "${tmp_lsp}" "${LSP_CONFIG}"; then
                echo "✓  Java LSP native skill registered (jdtls)"
            else
                rm -f "${tmp_lsp}"
            fi
        else
            rm -f "${tmp_lsp}"
        fi
    fi
fi

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
# Two modes, determined by whether start-sandbox.sh found a GitHub PAT in the
# host Linux keychain (secret-tool) and set GH_PAT_MODE=1.
#
# PAT mode  (GH_PAT_MODE=1):
#   • GH_TOKEN is already set in the environment (forwarded by start-sandbox.sh
#     via a private env-file).  No login is needed or desired.
#   • The `gh` CLI automatically uses GH_TOKEN for all operations.
#
# GitHub CLI mode  (GH_PAT_MODE unset, fallback):
#   • ~/.config/gh is mounted read-only from the host.
#   • If neither GH_TOKEN nor GITHUB_TOKEN is set and no valid gh session
#     exists, the user is prompted to log in via `gh auth login`.
if [[ -n "${GH_PAT_MODE:-}" ]]; then
    echo "ℹ  PAT mode: GitHub access via GH_TOKEN (~/.config/gh not mounted)"
elif [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]] && ! gh auth status &>/dev/null; then
    echo ""
    echo "⚠  No GitHub authentication found."
    echo "   Please log in so the Copilot CLI can access the API."
    echo "   You can authenticate via a web browser (--web) or by pasting a personal access token."
    echo ""
    gh auth login
    echo ""
fi

# ── Azure authentication ──────────────────────────────────────────────────────
# Two modes, determined by whether start-sandbox.sh found a PAT in the host
# Linux keychain (secret-tool) and set ADO_PAT_MODE=1.
#
# PAT mode  (ADO_PAT_MODE=1):
#   • AZURE_DEVOPS_EXT_PAT is already set in the environment (forwarded by
#     start-sandbox.sh).  No az login is needed or desired.
#   • az is shadowed by a wrapper script that passes `az devops` commands
#     through to the real binary (they authenticate via AZURE_DEVOPS_EXT_PAT)
#     while refusing all other az invocations, preventing MCP servers or the
#     user from accidentally calling az with broader-than-intended credentials.
#
# Azure CLI mode  (ADO_PAT_MODE unset, fallback):
#   • ~/.azure is mounted read-write from the host.
#   • If az is present but no valid subscription is active, az login is run
#     before launching Copilot so that ADO MCP servers (e.g. ado-git) have a
#     working session from the very first tool call.
if [[ -n "${ADO_PAT_MODE:-}" ]]; then
    echo "ℹ  PAT mode: Azure DevOps access via AZURE_DEVOPS_EXT_PAT (only az devops commands allowed)"
    # Shadow the az binary so that broader Azure CLI commands fail with a clear
    # message instead of operating silently on a different auth context.
    # Exception: `az devops` subcommands are passed through to the real binary
    # because they authenticate exclusively via AZURE_DEVOPS_EXT_PAT (already
    # set in the environment) and do not touch the broader Azure credential
    # store – they are exactly what the ADO skills need in PAT mode.
    # Write atomically: stage to a temp file, restrict permissions, add content,
    # make executable, then move into place.
    _real_az="$(command -v az)"
    _az_wrapper="$(mktemp)"
    chmod 600 "${_az_wrapper}"
    cat > "${_az_wrapper}" << WRAPPER
#!/usr/bin/env bash
# In PAT mode, only 'az devops' commands are permitted.
if [[ "\${1:-}" == "devops" ]]; then
    exec "${_real_az}" "\$@"
fi
echo "⛔  az CLI is disabled in PAT mode." >&2
echo "   Azure DevOps access uses the AZURE_DEVOPS_EXT_PAT environment variable." >&2
echo "   Only 'az devops' subcommands are permitted in PAT mode." >&2
echo "   To re-enable full az CLI, remove the PAT from your host keychain:" >&2
echo "     secret-tool clear service azure-devops-pat account default" >&2
exit 1
WRAPPER
    chmod +x "${_az_wrapper}"
    mv "${_az_wrapper}" /usr/local/bin/az
elif command -v az &>/dev/null && ! az account show &>/dev/null 2>&1; then
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
