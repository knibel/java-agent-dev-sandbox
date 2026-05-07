#!/usr/bin/env bats
# tests/shell-config.bats – tests for lib/shell-config.sh

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/shell-config.sh"
}

# ── normalize_devops_org ──────────────────────────────────────────────────────

@test "normalize_devops_org: plain org name is returned unchanged" {
    run normalize_devops_org "contoso"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "normalize_devops_org: strips https://dev.azure.com/ prefix" {
    run normalize_devops_org "https://dev.azure.com/contoso"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "normalize_devops_org: strips http://dev.azure.com/ prefix" {
    run normalize_devops_org "http://dev.azure.com/contoso"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "normalize_devops_org: strips https://dev.azure.com/ prefix with trailing slash" {
    run normalize_devops_org "https://dev.azure.com/contoso/"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "normalize_devops_org: strips https://dev.azure.com/ prefix with project path" {
    run normalize_devops_org "https://dev.azure.com/contoso/myproject"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "normalize_devops_org: strips visualstudio.com subdomain" {
    run normalize_devops_org "https://contoso.visualstudio.com"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "normalize_devops_org: strips visualstudio.com subdomain with path" {
    run normalize_devops_org "https://contoso.visualstudio.com/DefaultCollection"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "normalize_devops_org: allows dots, dashes, underscores" {
    run normalize_devops_org "my.org-name_1"
    [ "$status" -eq 0 ]
    [ "$output" = "my.org-name_1" ]
}

@test "normalize_devops_org: fails on empty string" {
    run normalize_devops_org ""
    [ "$status" -ne 0 ]
}

@test "normalize_devops_org: fails on string starting with special character" {
    run normalize_devops_org "-invalid"
    [ "$status" -ne 0 ]
}

@test "normalize_devops_org: fails on string with spaces" {
    run normalize_devops_org "my org"
    [ "$status" -ne 0 ]
}

# ── strip_wrapping_quotes ─────────────────────────────────────────────────────

@test "strip_wrapping_quotes: removes matching single quotes" {
    run strip_wrapping_quotes "'contoso'"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "strip_wrapping_quotes: removes matching double quotes" {
    run strip_wrapping_quotes '"contoso"'
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "strip_wrapping_quotes: returns value unchanged when no wrapping quotes" {
    run strip_wrapping_quotes "contoso"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "strip_wrapping_quotes: does not strip mismatched quotes" {
    run strip_wrapping_quotes "'contoso\""
    [ "$status" -eq 0 ]
    [ "$output" = "'contoso\"" ]
}

@test "strip_wrapping_quotes: returns empty string unchanged" {
    run strip_wrapping_quotes ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ── shell_escape ──────────────────────────────────────────────────────────────

@test "shell_escape: plain word is returned unchanged" {
    run shell_escape "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "hello" ]
}

@test "shell_escape: path with spaces is quoted" {
    run shell_escape "/path/with spaces/file"
    [ "$status" -eq 0 ]
    # The exact quoting style (single quotes or backslashes) is an
    # implementation detail; what matters is that the output re-evaluates
    # to the original string.
    result="$(eval "printf '%s' ${output}")"
    [ "$result" = "/path/with spaces/file" ]
}

@test "shell_escape: path with special characters is safely quoted" {
    run shell_escape "/home/user/my app & things"
    [ "$status" -eq 0 ]
    result="$(eval "printf '%s' ${output}")"
    [ "$result" = "/home/user/my app & things" ]
}

# ── extract_saved_devops_org ──────────────────────────────────────────────────

@test "extract_saved_devops_org: reads org from managed block" {
    local rc
    rc="$(mktemp)"
    cat > "$rc" <<'EOF'
some existing content
# >>> java-agent-dev-sandbox >>>
export AZURE_DEVOPS_ORG=contoso
alias copilot-sandbox=/some/path/start-sandbox.sh
# <<< java-agent-dev-sandbox <<<
EOF
    run extract_saved_devops_org "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

@test "extract_saved_devops_org: returns empty when no managed block" {
    local rc
    rc="$(mktemp)"
    echo "# just a comment" > "$rc"
    run extract_saved_devops_org "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "extract_saved_devops_org: returns empty when managed block has no org" {
    local rc
    rc="$(mktemp)"
    cat > "$rc" <<'EOF'
# >>> java-agent-dev-sandbox >>>
alias copilot-sandbox=/some/path/start-sandbox.sh
# <<< java-agent-dev-sandbox <<<
EOF
    run extract_saved_devops_org "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "extract_saved_devops_org: strips single quotes around org value" {
    local rc
    rc="$(mktemp)"
    cat > "$rc" <<'EOF'
# >>> java-agent-dev-sandbox >>>
export AZURE_DEVOPS_ORG='contoso'
alias copilot-sandbox=/some/path/start-sandbox.sh
# <<< java-agent-dev-sandbox <<<
EOF
    run extract_saved_devops_org "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
    [ "$output" = "contoso" ]
}

# ── write_shell_block ─────────────────────────────────────────────────────────

@test "write_shell_block: adds managed block to an empty file" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    run grep -c "java-agent-dev-sandbox" "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
    # Both start and end markers must be present (count >= 2)
    [ "$output" -ge 2 ]
}

@test "write_shell_block: writes alias into the managed block" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    run grep "alias copilot-sandbox=" "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
}

@test "write_shell_block: writes AZURE_DEVOPS_ORG when org is provided" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "contoso" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    run grep "AZURE_DEVOPS_ORG" "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"contoso"* ]]
}

@test "write_shell_block: does NOT write AZURE_DEVOPS_ORG when org is empty" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    run grep "AZURE_DEVOPS_ORG" "$rc"
    rm -f "$rc"
    # grep exits 1 when no match – that is the expected outcome
    [ "$status" -ne 0 ]
}

@test "write_shell_block: replaces an existing managed block" {
    local rc
    rc="$(mktemp)"
    cat > "$rc" <<'EOF'
existing line
# >>> java-agent-dev-sandbox >>>
export AZURE_DEVOPS_ORG=old
alias copilot-sandbox=/old/path/start-sandbox.sh --no-build
# <<< java-agent-dev-sandbox <<<
after block
EOF
    write_shell_block "$rc" "neworg" "copilot-sandbox" "/new/path/start-sandbox.sh --no-build"
    # Should contain exactly one start marker
    run bash -c "grep -c '# >>> java-agent-dev-sandbox >>>' '$rc'"
    rm -f "$rc"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "write_shell_block: removes legacy single-line marker and alias" {
    local rc
    rc="$(mktemp)"
    cat > "$rc" <<'EOF'
before
# java-agent-dev-sandbox
alias copilot-sandbox=/old/start-sandbox.sh --no-build
after
EOF
    write_shell_block "$rc" "" "copilot-sandbox" "/new/start-sandbox.sh --no-build"
    # Legacy marker must be gone
    run grep "# java-agent-dev-sandbox$" "$rc"
    rm -f "$rc"
    # grep exits 1 when not found – that is the expected outcome (legacy line removed)
    [ "$status" -ne 0 ]
}

@test "write_shell_block: preserves lines outside the managed block" {
    local rc
    rc="$(mktemp)"
    cat > "$rc" <<'EOF'
line_before
# >>> java-agent-dev-sandbox >>>
alias copilot-sandbox=/old/start-sandbox.sh --no-build
# <<< java-agent-dev-sandbox <<<
line_after
EOF
    write_shell_block "$rc" "" "mysandbox" "/new/start-sandbox.sh --no-build"
    run grep "line_before" "$rc"
    [ "$status" -eq 0 ]
    run grep "line_after" "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
}

# ── write_shell_block: completion ─────────────────────────────────────────────

@test "write_shell_block: writes bash completion function into the managed block" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    run grep "complete -F _copilot_sandbox_complete copilot-sandbox" "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
}

@test "write_shell_block: writes zsh completion registration into the managed block" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    run grep "compdef _copilot_sandbox_complete copilot-sandbox" "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
}

@test "write_shell_block: completion function name matches a custom alias name" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "" "my-sandbox" "/path/start-sandbox.sh --no-build"
    run grep "complete -F _my_sandbox_complete my-sandbox" "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
}

@test "write_shell_block: completion block appears exactly once after re-run" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    write_shell_block "$rc" "" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    run bash -c "grep -c 'complete -F _copilot_sandbox_complete' '$rc'"
    rm -f "$rc"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "write_shell_block: completion covers key launcher flags" {
    local rc
    rc="$(mktemp)"
    > "$rc"
    write_shell_block "$rc" "" "copilot-sandbox" "/path/start-sandbox.sh --no-build"
    run grep "\-\-workspace" "$rc"
    [ "$status" -eq 0 ]
    run grep "\-\-no-build" "$rc"
    [ "$status" -eq 0 ]
    run grep "\-\-build-arg" "$rc"
    rm -f "$rc"
    [ "$status" -eq 0 ]
}
