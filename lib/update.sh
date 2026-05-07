#!/usr/bin/env bash
# lib/update.sh – shared helpers for install/update flows.
#
# Source this file (do not execute it directly):
#   source "${SCRIPT_DIR}/lib/update.sh"

[[ -n "${_LIB_UPDATE_LOADED:-}" ]] && return 0
_LIB_UPDATE_LOADED=1

_UPDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${_UPDATE_LIB_DIR}/common.sh"

# Self-updates target this repository's GitHub Releases by default, but the
# repository slug can be overridden for testing or forks.
readonly SANDBOX_RELEASE_REPO="${SANDBOX_RELEASE_REPO:-knibel/java-agent-dev-sandbox}"
readonly UPDATE_STATE_DIR_NAME=".java-agent-dev-sandbox-state"
readonly INSTALLED_RELEASE_FILE_NAME="installed-release"

update_state_dir() {
    printf '%s/%s' "$1" "${UPDATE_STATE_DIR_NAME}"
}

installed_release_file() {
    printf '%s/%s' "$(update_state_dir "$1")" "${INSTALLED_RELEASE_FILE_NAME}"
}

ensure_update_state_dir() {
    mkdir -p "$(update_state_dir "$1")"
}

read_installed_release_tag() {
    local install_dir="$1"
    local state_file

    state_file="$(installed_release_file "${install_dir}")"
    if [[ -f "${state_file}" ]]; then
        tr -d '\r\n' < "${state_file}"
    fi
}

write_installed_release_tag() {
    local install_dir="$1"
    local tag="$2"

    ensure_update_state_dir "${install_dir}"
    printf '%s\n' "${tag}" > "$(installed_release_file "${install_dir}")"
}

detect_installed_release_tag() {
    local install_dir="$1"
    local current_tag

    current_tag="$(read_installed_release_tag "${install_dir}")"
    if [[ -n "${current_tag}" ]]; then
        printf '%s' "${current_tag}"
        return 0
    fi

    if command -v git &>/dev/null && [[ -d "${install_dir}/.git" ]]; then
        current_tag="$(git -C "${install_dir}" describe --tags --exact-match 2>/dev/null || true)"
        if [[ -n "${current_tag}" ]]; then
            printf '%s' "${current_tag}"
        fi
    fi
}

latest_release_tag() {
    gh api "repos/${SANDBOX_RELEASE_REPO}/releases/latest" --jq '.tag_name'
}

latest_release_tarball_url() {
    gh api "repos/${SANDBOX_RELEASE_REPO}/releases/latest" --jq '.tarball_url'
}

list_release_archive_assets() {
    gh api "repos/${SANDBOX_RELEASE_REPO}/releases/latest" \
        --jq '.assets[]? | select(((.name | ascii_downcase) | endswith(".tar.gz")) or ((.name | ascii_downcase) | endswith(".tgz")) or ((.name | ascii_downcase) | endswith(".tar"))) | "\(.name)\t\(.digest // "")"'
}

select_release_archive_asset_line() {
    local repo_basename="$1"
    local preferred=""
    local fallback=""
    local line asset_name

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        IFS=$'\t' read -r asset_name _ <<< "${line}"
        [[ -z "${fallback}" ]] && fallback="${line}"
        if [[ "${asset_name,,}" == *"${repo_basename,,}"* ]]; then
            preferred="${line}"
            break
        fi
    done

    if [[ -n "${preferred}" ]]; then
        printf '%s' "${preferred}"
    else
        printf '%s' "${fallback}"
    fi
}

verify_release_archive_checksum() {
    local archive_path="$1"
    local digest="$2"
    local expected actual

    [[ "${digest}" =~ ^sha256:(.+)$ ]] || return 1
    expected="${BASH_REMATCH[1]}"
    actual="$(sha256sum "${archive_path}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]]
}

download_release_archive() {
    local tag="$1"
    local destination="$2"
    local repo_basename asset_line asset_name asset_digest tarball_url

    repo_basename="${SANDBOX_RELEASE_REPO##*/}"
    asset_line="$(list_release_archive_assets | select_release_archive_asset_line "${repo_basename}" || true)"
    if [[ -n "${asset_line}" ]]; then
        IFS=$'\t' read -r asset_name asset_digest <<< "${asset_line}"
        if [[ "${asset_digest}" =~ ^sha256:.+ ]]; then
            gh release download "${tag}" \
                --repo "${SANDBOX_RELEASE_REPO}" \
                --pattern "${asset_name}" \
                --dir "$(dirname "${destination}")" \
                --clobber \
                >/dev/null
            mv -f "$(dirname "${destination}")/${asset_name}" "${destination}"

            if verify_release_archive_checksum "${destination}" "${asset_digest}"; then
                printf 'asset\t%s' "${asset_digest}"
                return 0
            fi

            rm -f "${destination}"
            return 1
        fi
    fi

    tarball_url="$(latest_release_tarball_url)"
    [[ -n "${tarball_url}" ]] || return 1
    gh api --method GET -H "Accept: application/octet-stream" "${tarball_url#https://api.github.com/}" > "${destination}"
    printf 'tarball\t'
}

resolve_release_tag_commit() {
    local tag="$1"

    git ls-remote --tags "https://github.com/${SANDBOX_RELEASE_REPO}.git" \
        "refs/tags/${tag}" "refs/tags/${tag}^{}" \
        | awk '{print $1}' \
        | tail -1
}

extract_archive_tree() {
    local archive_path="$1"
    local extract_dir="$2"
    local entries=()

    mkdir -p "${extract_dir}"
    tar -xf "${archive_path}" -C "${extract_dir}"

    while IFS= read -r entry; do
        entries+=("${entry}")
    done < <(find "${extract_dir}" -mindepth 1 -maxdepth 1 -print | sort)

    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
        printf '%s' "${entries[0]}"
    else
        printf '%s' "${extract_dir}"
    fi
}

verify_tarball_tree_matches_tag() {
    local extracted_tree="$1"
    local expected_commit="$2"
    local tree_name expected_short

    tree_name="$(basename "${extracted_tree}")"
    expected_short="${expected_commit:0:7}"
    [[ -n "${expected_short}" && "${tree_name}" == *"${expected_short}"* ]]
}

copy_install_tree() {
    local source_dir="$1"
    local destination_dir="$2"
    local entry base_name

    mkdir -p "${destination_dir}"
    shopt -s nullglob
    for entry in "${source_dir}"/* "${source_dir}"/.[!.]* "${source_dir}"/..?*; do
        [[ -e "${entry}" ]] || continue
        base_name="${entry##*/}"
        [[ "${base_name}" == ".git" || "${base_name}" == "${UPDATE_STATE_DIR_NAME}" ]] && continue
        cp -a "${entry}" "${destination_dir}/"
    done
    shopt -u nullglob
}

replace_install_tree() {
    local install_dir="$1"
    local new_tree="$2"
    local entry base_name

    ensure_update_state_dir "${install_dir}"

    shopt -s nullglob
    for entry in "${install_dir}"/* "${install_dir}"/.[!.]* "${install_dir}"/..?*; do
        [[ -e "${entry}" ]] || continue
        base_name="${entry##*/}"
        [[ "${base_name}" == ".git" || "${base_name}" == "${UPDATE_STATE_DIR_NAME}" ]] && continue
        rm -rf "${entry}"
    done
    shopt -u nullglob

    copy_install_tree "${new_tree}" "${install_dir}"
}

git_worktree_dirty() {
    local install_dir="$1"

    [[ -d "${install_dir}/.git" ]] || return 1
    [[ -n "$(git -C "${install_dir}" status --porcelain --untracked-files=normal 2>/dev/null)" ]]
}
