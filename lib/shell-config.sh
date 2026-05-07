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
#   if [[ -n "${BASH_VERSION:-}" ]]; then
#       _copilot_sandbox_complete() { ... }
#       complete -F _copilot_sandbox_complete copilot-sandbox
#   elif [[ -n "${ZSH_VERSION:-}" ]]; then
#       _copilot_sandbox_complete() { ... }
#       compdef _copilot_sandbox_complete copilot-sandbox
#   fi
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

# extract_saved_alias_name <rc_file>
# ───────────────────────────────────
# Reads the alias name from within the managed block of an existing shell RC
# file. Prints nothing when absent.
extract_saved_alias_name() {
    local rc_file="$1"
    local line

    line="$(
        sed -n "\%^${MANAGED_BLOCK_START}\$%,\%^${MANAGED_BLOCK_END}\$%p" "${rc_file}" \
            | grep '^alias ' \
            | head -1 \
            || true
    )"

    line="${line#alias }"
    printf '%s' "${line%%=*}"
}

# _write_completion_block <alias_name> <fn_name> <target_file>
# ─────────────────────────────────────────────────────────────
# Appends Bash and Zsh tab-completion code for <alias_name> to <target_file>.
# <fn_name> is the shell identifier used for the completion function
# (derived from the alias name with hyphens replaced by underscores).
# The completion covers all start-sandbox.sh launcher flags.
_write_completion_block() {
    local alias_name="$1"
    local fn_name="$2"
    local target="$3"

    cat >> "${target}" <<COMPLETION_EOF
if [[ -n "\${BASH_VERSION:-}" ]]; then
    ${fn_name}() {
        local cur prev i
        COMPREPLY=()
        cur="\${COMP_WORDS[COMP_CWORD]}"
        prev="\${COMP_WORDS[COMP_CWORD-1]}"
        for ((i = 1; i < COMP_CWORD; i++)); do
            [[ "\${COMP_WORDS[i]}" == "--" ]] && return 0
        done
        case "\${prev}" in
            -w|--workspace)
                COMPREPLY=( \$(compgen -d -- "\${cur}") )
                return 0 ;;
            -i|--image|--build-arg) return 0 ;;
        esac
        COMPREPLY=( \$(compgen -W "-w --workspace --tmp -i --image --no-build --auto-update --build-arg -h --help --" -- "\${cur}") )
    }
    complete -F ${fn_name} ${alias_name}
elif [[ -n "\${ZSH_VERSION:-}" ]]; then
    ${fn_name}() {
        _arguments -s \\
            '(-w --workspace)'{-w,--workspace}'[workspace directory to mount]:dir:_directories' \\
            '--tmp[use a fresh temporary directory as workspace]' \\
            '(-i --image)'{-i,--image}'[Docker image name/tag]:image:' \\
            '--no-build[skip image rebuild]' \\
            '--auto-update[check for and apply a newer sandbox release before launch]' \\
            '--build-arg[extra docker build argument]:ARG=VAL:' \\
            '(-h --help)'{-h,--help}'[show help and exit]' \\
            '--[pass remaining arguments to the Copilot CLI]'
    }
    compdef ${fn_name} ${alias_name}
fi
COMPLETION_EOF
}

# write_shell_block <rc_file> <org_value> <alias_name> <alias_command>
# ─────────────────────────────────────────────────────────────────────
# Atomically rewrites <rc_file>:
#   • Removes any existing managed block (new or legacy format).
#   • Appends a fresh managed block with an optional AZURE_DEVOPS_ORG export,
#     the sandbox alias, and Bash/Zsh tab-completion for the alias.
write_shell_block() {
    local rc_file="$1"
    local org_value="$2"
    local alias_name="$3"
    local alias_command="$4"
    local fn_name tmp_file

    # Derive a valid shell identifier: replace hyphens with underscores.
    fn_name="_${alias_name//-/_}_complete"
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
    _write_completion_block "${alias_name}" "${fn_name}" "${tmp_file}"
    printf '%s\n' "${MANAGED_BLOCK_END}" >> "${tmp_file}"

    mv "${tmp_file}" "${rc_file}"
}
