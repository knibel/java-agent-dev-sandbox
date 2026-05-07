#!/usr/bin/env bash
# lib/shell-config.sh – helpers for managing the managed shell-config block
# that install.sh writes into ~/.bashrc / ~/.zshrc.
#
# Source this file (do not execute it directly):
#   source "${SCRIPT_DIR}/lib/shell-config.sh"
#
# The managed block looks like:
#   # >>> java-agent-dev-sandbox >>>
#   export AZURE_DEVOPS_ORG=contoso   # optional
#   alias copilot-sandbox='/path/to/start-sandbox.sh --no-build'
#   # <<< java-agent-dev-sandbox <<<

# Guard against being sourced more than once.
[[ -n "${_LIB_SHELL_CONFIG_LOADED:-}" ]] && return 0
_LIB_SHELL_CONFIG_LOADED=1

MANAGED_BLOCK_START="# >>> java-agent-dev-sandbox >>>"
MANAGED_BLOCK_END="# <<< java-agent-dev-sandbox <<<"
LEGACY_MARKER="# java-agent-dev-sandbox"

# normalize_devops_org <raw>
# ──────────────────────────
# Accepts an org name ("contoso"), a dev.azure.com URL, or a
# visualstudio.com URL and returns just the bare organisation slug.
# Exits non-zero when the slug contains invalid characters.
normalize_devops_org() {
    local raw="$1"

    case "${raw}" in
        https://dev.azure.com/*)
            raw="${raw#https://dev.azure.com/}"
            raw="${raw%%/*}" ;;
        http://dev.azure.com/*)
            raw="${raw#http://dev.azure.com/}"
            raw="${raw%%/*}" ;;
    esac

    if [[ "${raw}" =~ ^https?://([^./]+)\.visualstudio\.com(/.*)?$ ]]; then
        raw="${BASH_REMATCH[1]}"
    fi

    raw="${raw%/}"

    if [[ ! "${raw}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        return 1
    fi

    printf '%s' "${raw}"
}

# shell_escape <string>
# ─────────────────────
# Returns a shell-safe quoted representation of the argument using printf %q.
shell_escape() {
    printf '%q' "$1"
}

# strip_wrapping_quotes <value>
# ─────────────────────────────
# Removes a matching pair of surrounding single or double quotes (if present).
strip_wrapping_quotes() {
    local value="$1"

    if [[ -n "${value}" ]] \
            && [[ "${value:0:1}" == "${value: -1}" ]] \
            && [[ "${value:0:1}" == "'" || "${value:0:1}" == '"' ]]; then
        printf '%s' "${value:1:-1}"
    else
        printf '%s' "${value}"
    fi
}

# extract_saved_devops_org <rc_file>
# ───────────────────────────────────
# Reads and normalizes the AZURE_DEVOPS_ORG value from within the managed
# block of an existing shell RC file.  Prints nothing when absent.
extract_saved_devops_org() {
    local rc_file="$1"
    local line value

    line="$(
        sed -n "\%^${MANAGED_BLOCK_START}\$%,\%^${MANAGED_BLOCK_END}\$%p" "${rc_file}" \
            | grep '^export AZURE_DEVOPS_ORG=' \
            | head -1 \
            || true
    )"

    value="$(strip_wrapping_quotes "${line#export AZURE_DEVOPS_ORG=}")"

    if [[ -n "${value}" ]]; then
        normalize_devops_org "${value}" || true
    fi
}

# write_shell_block <rc_file> <org_value> <alias_name> <alias_command>
# ─────────────────────────────────────────────────────────────────────
# Atomically rewrites <rc_file>:
#   • Removes any existing managed block (new or legacy format).
#   • Appends a fresh managed block with an optional AZURE_DEVOPS_ORG export
#     and the sandbox alias.
write_shell_block() {
    local rc_file="$1"
    local org_value="$2"
    local alias_name="$3"
    local alias_command="$4"
    local tmp_file

    tmp_file="$(mktemp)"

    awk \
        -v start="${MANAGED_BLOCK_START}" \
        -v end="${MANAGED_BLOCK_END}" \
        -v legacy="${LEGACY_MARKER}" '
        $0 == start { skip=1; next }
        $0 == end { skip=0; next }
        skip { next }
        $0 == legacy { skip_legacy=1; next }
        # Older installs wrote a single marker line followed by one sandbox alias line.
        skip_legacy && $0 ~ /^alias[[:space:]]+[^[:space:]=]+=.*start-sandbox\.sh/ { skip_legacy=0; next }
        skip_legacy { skip_legacy=0 }
        { print }
    ' "${rc_file}" > "${tmp_file}"

    printf '\n%s\n' "${MANAGED_BLOCK_START}" >> "${tmp_file}"
    if [[ -n "${org_value}" ]]; then
        printf 'export AZURE_DEVOPS_ORG=%s\n' "$(shell_escape "${org_value}")" >> "${tmp_file}"
    fi
    printf 'alias %s=%s\n' "${alias_name}" "$(shell_escape "${alias_command}")" >> "${tmp_file}"
    printf '%s\n' "${MANAGED_BLOCK_END}" >> "${tmp_file}"

    mv "${tmp_file}" "${rc_file}"
}
