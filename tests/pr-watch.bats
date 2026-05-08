#!/usr/bin/env bats
#
# tests/pr-watch.bats - regression tests for Azure DevOps PR watch helpers

setup() {
    REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    REGISTER_SCRIPT="${REPO_ROOT}/skills/azure-devops/pr-watch-register.sh"
    DAEMON_SCRIPT="${REPO_ROOT}/skills/azure-devops/pr-watch-daemon.sh"
    READ_SCRIPT="${REPO_ROOT}/skills/azure-devops/pr-watch-read.sh"

    FAKE_ROOT="$(mktemp -d)"
    FAKE_BIN="${FAKE_ROOT}/bin"
    export HOME="${FAKE_ROOT}/home"
    mkdir -p "${FAKE_BIN}" "${HOME}/.copilot"
    export PATH="${FAKE_BIN}:${PATH}"

    cat > "${FAKE_BIN}/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "repos" && "${2:-}" == "show" ]]; then
    printf '%s\n' "${AZ_FAKE_REPO_ID:-repo-id}"
    exit 0
fi

if [[ "${1:-}" == "devops" && "${2:-}" == "invoke" ]]; then
    shift 2
    resource=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resource)
                resource="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    if [[ "${resource}" == "pullRequestThreads" ]]; then
        if [[ -n "${AZ_FAKE_THREADS_JSON:-}" ]]; then
            printf '%s' "${AZ_FAKE_THREADS_JSON}"
        else
            printf '%s' '{"value":[]}'
        fi
        exit 0
    fi
fi

if [[ "${1:-}" == "devops" && "${2:-}" == "configure" && "${3:-}" == "--list" ]]; then
    printf '%s\n' "${AZ_FAKE_DEFAULT_ORG:-https://dev.azure.com/example}"
    exit 0
fi

echo "unexpected az call: $*" >&2
exit 99
EOF
    chmod +x "${FAKE_BIN}/az"
}

teardown() {
    rm -rf "${FAKE_ROOT}"
}

@test "pr-watch-register: creates and updates watchlist entries" {
    export AZ_FAKE_THREADS_JSON='{"value":[{"id":101,"comments":[{"id":1},{"id":2}]}]}'
    run "${REGISTER_SCRIPT}" \
        --register \
        --project proj \
        --repo repo \
        --pr-id 42 \
        --org "https://dev.azure.com/example"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.watched | length' "${HOME}/.copilot/pr-watchlist.json")" -eq 1 ]
    [ "$(jq -r '.watched[0].lastSeenThreads["101"]' "${HOME}/.copilot/pr-watchlist.json")" -eq 2 ]

    export AZ_FAKE_THREADS_JSON='{"value":[{"id":101,"comments":[{"id":1},{"id":2},{"id":3}]},{"id":102,"comments":[{"id":4}]}]}'
    run "${REGISTER_SCRIPT}" \
        --register \
        --project proj \
        --repo repo \
        --pr-id 42 \
        --org "https://dev.azure.com/example"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.watched | length' "${HOME}/.copilot/pr-watchlist.json")" -eq 1 ]
    [ "$(jq -r '.watched[0].lastSeenThreads["101"]' "${HOME}/.copilot/pr-watchlist.json")" -eq 3 ]
    [ "$(jq -r '.watched[0].lastSeenThreads["102"]' "${HOME}/.copilot/pr-watchlist.json")" -eq 1 ]
}

@test "pr-watch-register: unregister removes watched PRs by id" {
    export AZ_FAKE_THREADS_JSON='{"value":[{"id":101,"comments":[{"id":1}]}]}'
    run "${REGISTER_SCRIPT}" \
        --register \
        --project proj \
        --repo repo \
        --pr-id 42 \
        --org "https://dev.azure.com/example"
    [ "$status" -eq 0 ]

    run "${REGISTER_SCRIPT}" --unregister --pr-id 42
    [ "$status" -eq 0 ]
    [ "$(jq -r '.watched | length' "${HOME}/.copilot/pr-watchlist.json")" -eq 0 ]
}

@test "pr-watch-read: returns 1 when there are no unread notifications" {
    run "${READ_SCRIPT}"
    [ "$status" -eq 1 ]
}

@test "pr-watch-read: prints notifications and archives them" {
    cat > "${HOME}/.copilot/pr-notifications.jsonl" <<'EOF'
{"prId":42,"threadId":101,"commentId":2,"author":"alice","content":"Please fix the null check","filePath":"/src/Foo.java","line":17,"ts":"2026-05-08T18:00:00Z"}
EOF

    run "${READ_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "${output}" == *"PR #42 | alice | /src/Foo.java:17"* ]]
    [[ "${output}" == *"Please fix the null check"* ]]
    [ ! -f "${HOME}/.copilot/pr-notifications.jsonl" ]
    archive_count="$(find "${HOME}/.copilot" -maxdepth 1 -name 'pr-notifications.jsonl.*.read' | wc -l | tr -d ' ')"
    [ "${archive_count}" -eq 1 ]
}

@test "pr-watch-daemon: one iteration records new comments and updates last-seen state" {
    cat > "${HOME}/.copilot/pr-watchlist.json" <<'EOF'
{"watched":[{"org":"https://dev.azure.com/example","project":"proj","repo":"repo","prId":42,"lastSeenThreads":{"101":1}}]}
EOF

    export AZ_FAKE_THREADS_JSON='{"value":[{"id":101,"threadContext":{"filePath":"/src/Foo.java","rightFileStart":{"line":17}},"comments":[{"id":1,"author":{"displayName":"alice"},"content":"Existing comment","publishedDate":"2026-05-08T18:00:00Z"},{"id":2,"author":{"displayName":"bob"},"content":"New reply","publishedDate":"2026-05-08T18:05:00Z"}]},{"id":102,"comments":[{"id":3,"author":{"displayName":"carol"},"content":"Fresh thread","publishedDate":"2026-05-08T18:06:00Z"}]}]}'

    run "${DAEMON_SCRIPT}" --once
    [ "$status" -eq 0 ]
    [ "$(wc -l < "${HOME}/.copilot/pr-notifications.jsonl" | tr -d ' ')" -eq 2 ]
    [ "$(jq -r '.watched[0].lastSeenThreads["101"]' "${HOME}/.copilot/pr-watchlist.json")" -eq 2 ]
    [ "$(jq -r '.watched[0].lastSeenThreads["102"]' "${HOME}/.copilot/pr-watchlist.json")" -eq 1 ]
    [[ "$(sed -n '1p' "${HOME}/.copilot/pr-notifications.jsonl")" == *'"content":"New reply"'* ]]
    [[ "$(sed -n '2p' "${HOME}/.copilot/pr-notifications.jsonl")" == *'"content":"Fresh thread"'* ]]
}
