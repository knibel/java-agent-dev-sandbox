#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  pr-watch-register.sh --register --project <PROJECT> --repo <REPO> --pr-id <PR_ID> [--org <https://dev.azure.com/ORG>]
  pr-watch-register.sh --unregister --pr-id <PR_ID>
  pr-watch-register.sh --list

Notes:
  - Stores watched pull requests in ~/.copilot/pr-watchlist.json.
  - Registration snapshots the current thread/comment counts so only future comments notify.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

MODE=""
PROJECT=""
REPO=""
PR_ID=""
ORG_URL=""

STATE_DIR="${HOME:-/root}/.copilot"
WATCHLIST_FILE="${STATE_DIR}/pr-watchlist.json"
WATCHLIST_LOCK="${STATE_DIR}/pr-watchlist.lock"

acquire_lock() {
    local lock_dir="$1"
    local attempts=0
    while ! mkdir "${lock_dir}" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ "${attempts}" -ge 300 ]]; then
            die "Timed out waiting for lock: ${lock_dir}"
        fi
        sleep 0.1
    done
}

release_lock() {
    local lock_dir="$1"
    rmdir "${lock_dir}" 2>/dev/null || true
}

init_watchlist() {
    mkdir -p "${STATE_DIR}"
    if [[ ! -f "${WATCHLIST_FILE}" ]]; then
        printf '{"watched":[]}\n' > "${WATCHLIST_FILE}"
    fi
}

resolve_org() {
    if [[ -n "${ORG_URL}" ]]; then
        return 0
    fi
    if [[ -n "${AZURE_DEVOPS_ORG:-}" ]]; then
        ORG_URL="https://dev.azure.com/${AZURE_DEVOPS_ORG}"
        return 0
    fi
    ORG_URL="$(az devops configure --list --query 'defaults.organization' -o tsv 2>/dev/null || true)"
    [[ -n "${ORG_URL}" ]] || die "Set --org, AZURE_DEVOPS_ORG, or az devops default organization"
}

fetch_last_seen_threads() {
    local repo_id
    local threads_json

    repo_id="$(az repos show \
        --repo "${REPO}" \
        --project "${PROJECT}" \
        --org "${ORG_URL}" \
        --query id -o tsv)"
    [[ -n "${repo_id}" ]] || die "Failed to resolve repository id for ${REPO}"

    threads_json="$(
        az devops invoke \
            --area git \
            --resource pullRequestThreads \
            --route-parameters "project=${PROJECT}" "repositoryId=${repo_id}" "pullRequestId=${PR_ID}" \
            --http-method GET \
            --org "${ORG_URL}" \
            --output json
    )"

    [[ -n "${threads_json//[[:space:]]/}" ]] || threads_json='{"value":[]}'
    echo "${threads_json}" | jq -e . >/dev/null || die "PR thread API returned invalid JSON"
    echo "${threads_json}" | jq -c '
        reduce (.value // [])[] as $thread ({};
            .[($thread.id | tostring)] = (($thread.comments // []) | length)
        )
    '
}

register_pr() {
    local last_seen_threads
    local tmp_file

    resolve_org
    [[ -n "${PROJECT}" ]] || die "--project is required with --register"
    [[ -n "${REPO}" ]] || die "--repo is required with --register"
    [[ "${PR_ID}" =~ ^[0-9]+$ ]] || die "--pr-id must be a positive integer"

    last_seen_threads="$(fetch_last_seen_threads)"

    acquire_lock "${WATCHLIST_LOCK}"
    init_watchlist
    tmp_file="$(mktemp)"
    jq \
        --arg org "${ORG_URL}" \
        --arg project "${PROJECT}" \
        --arg repo "${REPO}" \
        --argjson prId "${PR_ID}" \
        --argjson lastSeenThreads "${last_seen_threads}" \
        '
        .watched = (
            [(.watched // [])[] | select(.org != $org or .project != $project or .repo != $repo or .prId != $prId)]
            + [{
                org: $org,
                project: $project,
                repo: $repo,
                prId: $prId,
                lastSeenThreads: $lastSeenThreads
            }]
        )
        ' "${WATCHLIST_FILE}" > "${tmp_file}"
    mv "${tmp_file}" "${WATCHLIST_FILE}"
    release_lock "${WATCHLIST_LOCK}"
}

unregister_pr() {
    local tmp_file

    [[ "${PR_ID}" =~ ^[0-9]+$ ]] || die "--pr-id must be a positive integer"
    acquire_lock "${WATCHLIST_LOCK}"
    init_watchlist
    tmp_file="$(mktemp)"
    jq \
        --argjson prId "${PR_ID}" \
        '.watched = [(.watched // [])[] | select(.prId != $prId)]' \
        "${WATCHLIST_FILE}" > "${tmp_file}"
    mv "${tmp_file}" "${WATCHLIST_FILE}"
    release_lock "${WATCHLIST_LOCK}"
}

list_prs() {
    acquire_lock "${WATCHLIST_LOCK}"
    init_watchlist
    jq -r '
        if ((.watched // []) | length) == 0 then
            empty
        else
            (.watched // [])[]
            | "\(.org) \(.project) \(.repo) PR #\(.prId)"
        end
    ' "${WATCHLIST_FILE}"
    release_lock "${WATCHLIST_LOCK}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --register)
            MODE="register"
            shift
            ;;
        --unregister)
            MODE="unregister"
            shift
            ;;
        --list)
            MODE="list"
            shift
            ;;
        --project)
            PROJECT="${2:-}"
            shift 2
            ;;
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --pr-id)
            PR_ID="${2:-}"
            shift 2
            ;;
        --org)
            ORG_URL="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "${MODE}" ]] || die "Specify one of --register, --unregister, or --list"
command -v jq >/dev/null 2>&1 || die "jq is required"

case "${MODE}" in
    register)
        command -v az >/dev/null 2>&1 || die "az is required for --register"
        register_pr
        ;;
    unregister)
        unregister_pr
        ;;
    list)
        list_prs
        ;;
esac
