#!/usr/bin/env bats
# tests/azure-devops-skill.bats – regression tests for Azure DevOps skill helper

setup() {
    REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    HELPER_SCRIPT="${REPO_ROOT}/skills/azure-devops/ado-build-step-log.sh"

    FAKE_ROOT="$(mktemp -d)"
    FAKE_BIN="${FAKE_ROOT}/bin"
    mkdir -p "${FAKE_BIN}"
    export PATH="${FAKE_BIN}:${PATH}"

    cat > "${FAKE_BIN}/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "devops" && "${2:-}" == "invoke" ]]; then
    shift 2
    resource=""
    route_params=()
    out_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resource)
                resource="${2:-}"
                shift 2
                ;;
            --route-parameters)
                shift
                while [[ $# -gt 0 && "${1}" != --* ]]; do
                    route_params+=("$1")
                    shift
                done
                ;;
            --out-file)
                out_file="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ "${resource}" == "timelines" ]]; then
        printf '%s' "${AZ_FAKE_TIMELINE_JSON:-{"records":[]}}"
        exit 0
    fi

    if [[ "${resource}" == "logs" ]]; then
        log_id=""
        for param in "${route_params[@]}"; do
            if [[ "${param}" == logId=* ]]; then
                log_id="${param#logId=}"
            fi
        done

        if [[ "${AZ_FAKE_SKIP_OUTFILE:-0}" == "1" ]]; then
            exit 0
        fi
        if [[ "${AZ_FAKE_LOG_EMPTY:-0}" == "1" ]]; then
            : > "${out_file}"
            exit 0
        fi

        printf '%s' "${AZ_FAKE_LOG_PREFIX:-log for }${log_id}" > "${out_file}"
        exit 0
    fi
fi

if [[ "${1:-}" == "devops" && "${2:-}" == "configure" && "${3:-}" == "--list" ]]; then
    printf '%s\n' ""
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

@test "ado-build-step-log: maps step name to timeline log id and fetches correct log" {
    export AZ_FAKE_TIMELINE_JSON='{"records":[{"id":"rec-1","name":"Compile","result":"succeeded","log":{"id":5}},{"id":"rec-2","name":"Unit Tests","result":"failed","log":{"id":7}}]}'
    run "${HELPER_SCRIPT}" \
        --project proj \
        --build-id 42 \
        --step-name "Unit Tests" \
        --org "https://dev.azure.com/example"
    [ "$status" -eq 0 ]
    [ "$output" = "log for 7" ]
}

@test "ado-build-step-log: fails loudly when no timeline record matches selector" {
    export AZ_FAKE_TIMELINE_JSON='{"records":[{"id":"rec-1","name":"Compile","result":"succeeded","log":{"id":5}}]}'
    run "${HELPER_SCRIPT}" \
        --project proj \
        --build-id 42 \
        --step-name "Package" \
        --org "https://dev.azure.com/example"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No timeline record matched"* ]]
}

@test "ado-build-step-log: fails when log fetch returns empty output" {
    export AZ_FAKE_TIMELINE_JSON='{"records":[{"id":"rec-1","name":"Compile","result":"failed","log":{"id":5}}]}'
    export AZ_FAKE_LOG_EMPTY=1
    run "${HELPER_SCRIPT}" \
        --project proj \
        --build-id 42 \
        --step-name "Compile" \
        --org "https://dev.azure.com/example"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty output"* ]]
}
