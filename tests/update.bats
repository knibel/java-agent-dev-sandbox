#!/usr/bin/env bats
# tests/update.bats – tests for lib/update.sh

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/update.sh"
}

@test "select_release_archive_asset_line: prefers archive matching repo name" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/update.sh'; printf 'other.tar.gz\tsha256:one\njava-agent-dev-sandbox-0.0.1.tar.gz\tsha256:two\n' | select_release_archive_asset_line 'java-agent-dev-sandbox'"
    [ "$status" -eq 0 ]
    [ "$output" = $'java-agent-dev-sandbox-0.0.1.tar.gz\tsha256:two' ]
}

@test "select_release_archive_asset_line: falls back to first archive when no name matches" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/update.sh'; printf 'first.tar.gz\tsha256:one\nsecond.tar.gz\tsha256:two\n' | select_release_archive_asset_line 'java-agent-dev-sandbox'"
    [ "$status" -eq 0 ]
    [ "$output" = $'first.tar.gz\tsha256:one' ]
}

@test "verify_release_archive_checksum: succeeds when sha256 matches" {
    local archive
    archive="$(mktemp)"
    printf 'hello world' > "${archive}"
    local digest
    digest="sha256:$(sha256sum "${archive}" | awk '{print $1}')"
    run verify_release_archive_checksum "${archive}" "${digest}"
    rm -f "${archive}"
    [ "$status" -eq 0 ]
}

@test "verify_release_archive_checksum: fails when sha256 differs" {
    local archive
    archive="$(mktemp)"
    printf 'hello world' > "${archive}"
    run verify_release_archive_checksum "${archive}" "sha256:nottherightdigest"
    rm -f "${archive}"
    [ "$status" -ne 0 ]
}

@test "detect_installed_release_tag: prefers updater state file" {
    local install_dir
    install_dir="$(mktemp -d)"
    write_installed_release_tag "${install_dir}" "0.0.1"
    run detect_installed_release_tag "${install_dir}"
    rm -rf "${install_dir}"
    [ "$status" -eq 0 ]
    [ "$output" = "0.0.1" ]
}

@test "extract_archive_tree: returns extracted root directory when archive has one top-level directory" {
    local root source_dir archive extract_dir
    root="$(mktemp -d)"
    source_dir="${root}/payload"
    archive="${root}/payload.tar.gz"
    extract_dir="${root}/extracted"
    mkdir -p "${source_dir}/nested"
    printf 'content' > "${source_dir}/nested/file.txt"
    tar -czf "${archive}" -C "${root}" payload

    run extract_archive_tree "${archive}" "${extract_dir}"

    rm -rf "${root}"
    [ "$status" -eq 0 ]
    [[ "$output" == */payload ]]
}

@test "verify_tarball_tree_matches_tag: succeeds when extracted directory includes commit prefix" {
    run verify_tarball_tree_matches_tag "/tmp/org-java-agent-dev-sandbox-f5c3abc" "f5c3abc2dcf75396b775ebaf4256760b7e1dcdd6"
    [ "$status" -eq 0 ]
}

@test "copy_install_tree: skips git metadata and updater state" {
    local source_dir destination_dir
    source_dir="$(mktemp -d)"
    destination_dir="$(mktemp -d)"
    mkdir -p "${source_dir}/.git" "${source_dir}/.java-agent-dev-sandbox-state"
    printf 'README' > "${source_dir}/README.md"
    printf 'secret' > "${source_dir}/.java-agent-dev-sandbox-state/installed-release"

    copy_install_tree "${source_dir}" "${destination_dir}"

    [ -f "${destination_dir}/README.md" ]
    [ ! -e "${destination_dir}/.git" ]
    [ ! -e "${destination_dir}/.java-agent-dev-sandbox-state" ]
    rm -rf "${source_dir}" "${destination_dir}"
}
