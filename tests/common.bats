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
