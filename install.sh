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
#   --update            Download and install the latest GitHub release, then rebuild
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
# shellcheck source=lib/update.sh
source "${SCRIPT_DIR}/lib/update.sh"

# ── defaults ──────────────────────────────────────────────────────────────────
SKIP_BUILD=false
UPDATE_MODE=false
ALIAS_NAME="copilot-sandbox"
ALIAS_EXPLICIT=false
DEVOPS_ORG_INPUT=""
declare -a RC_FILES=()

collect_rc_files() {
    RC_FILES=()
    [[ -f "${HOME}/.bashrc" ]] && RC_FILES+=("${HOME}/.bashrc")
    [[ -f "${HOME}/.zshrc" ]]  && RC_FILES+=("${HOME}/.zshrc")
}

resolve_saved_alias_name() {
    local rc saved_alias

    collect_rc_files
    for rc in "${RC_FILES[@]}"; do
        saved_alias="$(extract_saved_alias_name "${rc}")"
        if [[ -n "${saved_alias}" ]]; then
            printf '%s' "${saved_alias}"
            return 0
        fi
    done
}

build_image() {
    if [[ "${SKIP_BUILD}" == false ]]; then
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
}

register_shell_config() {
    local rc action devops_org_to_write

    collect_rc_files
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
        return 0
    fi

    log "Registering shell config for '${ALIAS_NAME}' …"
    for rc in "${RC_FILES[@]}"; do
        devops_org_to_write="${DEVOPS_ORG}"
        if [[ -z "${devops_org_to_write}" ]]; then
            devops_org_to_write="$(extract_saved_devops_org "${rc}")"
        fi

        if grep -qF "${MANAGED_BLOCK_START}" "${rc}" 2>/dev/null \
                || grep -qF "${LEGACY_MARKER}" "${rc}" 2>/dev/null; then
            action="updated"
        else
            action="added"
        fi

        write_shell_block "${rc}" "${devops_org_to_write}" "${ALIAS_NAME}" "${SCRIPT_DIR}/start-sandbox.sh --no-build"
        ok "Sandbox config ${action} in ${rc}"
    done
}

print_install_summary() {
    local rc

    echo ""
    log "Installation complete."
    echo ""

    if [[ ${#RC_FILES[@]} -gt 0 ]]; then
        echo "Reload your shell config to activate the alias:"
        for rc in "${RC_FILES[@]}"; do
            echo "   source ${rc}"
        done
        echo ""
    fi

    if [[ -n "${DEVOPS_ORG}" ]]; then
        echo "Saved Azure DevOps organization: ${DEVOPS_ORG}"
        echo ""
    fi
    echo "Then launch the sandbox from any project directory:"
    echo "   ${ALIAS_NAME}                          # interactive session"
    echo "   ${ALIAS_NAME} -- --autopilot -i '…'   # autopilot mode"
}

run_install_flow() {
    chmod +x "${SCRIPT_DIR}/start-sandbox.sh"
    info "start-sandbox.sh is executable."
    build_image
    register_shell_config
    print_install_summary
}

perform_release_update() {
    local current_tag latest_tag tmp_root archive_path backup_dir extract_dir extracted_tree
    local download_mode download_meta tag_commit reinstall_status=0
    local -a reinstall_args=()

    require_cmd gh
    require_cmd git
    require_cmd tar
    require_cmd sha256sum

    if git_worktree_dirty "${SCRIPT_DIR}"; then
        warn "Refusing to update because ${SCRIPT_DIR} has uncommitted changes."
        warn "Commit, stash, or discard local changes first."
        exit 1
    fi

    current_tag="$(detect_installed_release_tag "${SCRIPT_DIR}")"
    latest_tag="$(latest_release_tag)"
    if [[ -z "${latest_tag}" ]]; then
        warn "Could not determine the latest sandbox release."
        exit 1
    fi

    if [[ -n "${current_tag}" && "${current_tag}" == "${latest_tag}" ]]; then
        ok "Sandbox is already up to date (${latest_tag})."
        exit 0
    fi

    tmp_root="$(mktemp -d /tmp/java-agent-dev-sandbox-update-XXXXXX)"
    archive_path="${tmp_root}/release.tar.gz"
    backup_dir="${tmp_root}/backup"
    extract_dir="${tmp_root}/extract"

    log "Updating sandbox from ${current_tag:-unknown} to ${latest_tag} …"
    download_meta="$(download_release_archive "${latest_tag}" "${archive_path}")" || {
        rm -rf "${tmp_root}"
        warn "Could not download a verified sandbox release archive."
        exit 1
    }
    IFS=$'\t' read -r download_mode _ <<< "${download_meta}"

    extracted_tree="$(extract_archive_tree "${archive_path}" "${extract_dir}")"
    if [[ "${download_mode}" == "tarball" ]]; then
        tag_commit="$(resolve_release_tag_commit "${latest_tag}")"
        if [[ -z "${tag_commit}" || ! verify_tarball_tree_matches_tag "${extracted_tree}" "${tag_commit}" ]]; then
            rm -rf "${tmp_root}"
            warn "Downloaded release tarball did not match the expected release tag commit."
            exit 1
        fi
    fi

    copy_install_tree "${SCRIPT_DIR}" "${backup_dir}"
    replace_install_tree "${SCRIPT_DIR}" "${extracted_tree}"

    reinstall_args+=("--alias" "${ALIAS_NAME}")
    if [[ -n "${DEVOPS_ORG}" ]]; then
        reinstall_args+=("--devops-org" "${DEVOPS_ORG}")
    fi

    bash "${SCRIPT_DIR}/install.sh" "${reinstall_args[@]}" || reinstall_status=$?
    if [[ "${reinstall_status}" -ne 0 ]]; then
        warn "Updated install failed; restoring the previous sandbox files."
        replace_install_tree "${SCRIPT_DIR}" "${backup_dir}"
        if [[ -n "${current_tag}" ]]; then
            write_installed_release_tag "${SCRIPT_DIR}" "${current_tag}"
        else
            rm -f "$(installed_release_file "${SCRIPT_DIR}")"
        fi
        rm -rf "${tmp_root}"
        exit "${reinstall_status}"
    fi

    write_installed_release_tag "${SCRIPT_DIR}" "${latest_tag}"
    rm -rf "${tmp_root}"
    ok "Sandbox updated to release ${latest_tag}."
}

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            SKIP_BUILD=true
            shift ;;
        --update)
            UPDATE_MODE=true
            shift ;;
        --alias)
            ALIAS_NAME="$2"
            ALIAS_EXPLICIT=true
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

if [[ "${UPDATE_MODE}" == true && "${SKIP_BUILD}" == true ]]; then
    warn "--no-build is ignored when --update is used so the updated sandbox is rebuilt."
    SKIP_BUILD=false
fi

if [[ "${UPDATE_MODE}" == true && "${ALIAS_EXPLICIT}" == false ]]; then
    SAVED_ALIAS_NAME="$(resolve_saved_alias_name)"
    if [[ -n "${SAVED_ALIAS_NAME}" ]]; then
        ALIAS_NAME="${SAVED_ALIAS_NAME}"
    fi
fi

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

if [[ "${UPDATE_MODE}" == true ]]; then
    perform_release_update
else
    run_install_flow
fi
