#!/usr/bin/env bats
# tests/common.bats – tests for lib/common.sh

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/common.sh"
}

# ── log / info / ok ────────────────────────────────────────────────────────────

@test "log: prefixes output with '▶  '" {
    run log "hello world"
    [ "$status" -eq 0 ]
    [ "$output" = "▶  hello world" ]
}

@test "info: prefixes output with '   '" {
    run info "some info"
    [ "$status" -eq 0 ]
    [ "$output" = "   some info" ]
}

@test "ok: prefixes output with '✅ '" {
    run ok "all good"
    [ "$status" -eq 0 ]
    [ "$output" = "✅ all good" ]
}

@test "warn: writes to stderr and prefixes with '⚠  '" {
    run warn "something bad"
    [ "$status" -eq 0 ]
    # output goes to stderr, captured in $output by bats
    [ "$output" = "⚠  something bad" ]
}

# ── require_cmd ───────────────────────────────────────────────────────────────

@test "require_cmd: succeeds for a command that exists on PATH" {
    run require_cmd bash
    [ "$status" -eq 0 ]
}

@test "require_cmd: exits non-zero when the command is missing" {
    run require_cmd __no_such_command_xyz__
    [ "$status" -ne 0 ]
}

@test "require_cmd: resolves command from snap bin path when missing on PATH" {
    run bash -c '
        source "'"${BATS_TEST_DIRNAME}"'/../lib/common.sh"
        tmp_snap="$(mktemp -d)"
        trap "PATH=/usr/bin:/bin; rm -rf \"${tmp_snap}\"" EXIT
        mkdir -p "${tmp_snap}/snap-bin"
        cat > "${tmp_snap}/snap-bin/docker" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
echo docker
EOF
        chmod +x "${tmp_snap}/snap-bin/docker"
        PATH="/nonexistent-path-for-test"
        SNAP_BIN_DIR="${tmp_snap}/snap-bin"
        require_cmd docker
        command -v docker
    '
    [ "$status" -eq 0 ]
    [[ "$output" == */snap-bin/docker ]]
}

# ── idempotent sourcing (guard variable) ──────────────────────────────────────

@test "lib/common.sh can be sourced multiple times without error" {
    run bash -c '
        source "'"${BATS_TEST_DIRNAME}"'/../lib/common.sh"
        source "'"${BATS_TEST_DIRNAME}"'/../lib/common.sh"
        log "still works"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "▶  still works" ]
}

# ── version helpers ────────────────────────────────────────────────────────────

@test "normalize_semver strips v-prefix and suffix" {
    run normalize_semver "v2.89.0-rc1"
    [ "$status" -eq 0 ]
    [ "$output" = "2.89.0" ]
}

@test "normalize_semver fails on invalid version string" {
    run normalize_semver "gh-version"
    [ "$status" -ne 0 ]
}

@test "version_gte returns success for equal versions" {
    run version_gte "2.0.0" "2.0.0"
    [ "$status" -eq 0 ]
}

@test "version_gte returns success when left is greater" {
    run version_gte "2.10.0" "2.9.9"
    [ "$status" -eq 0 ]
}

@test "version_gte returns non-zero when left is lower" {
    run version_gte "1.99.0" "2.0.0"
    [ "$status" -ne 0 ]
}
