#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  pr-watch-daemon.sh [--once] [--interval <SECONDS>]

Notes:
  - Polls watched Azure DevOps pull requests and appends new review comments to
    ~/.copilot/pr-notifications.jsonl.
  - Writes its PID to ~/.copilot/pr-watch-daemon.pid and logs to
    ~/.copilot/pr-watch-daemon.log.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

RUN_ONCE=0
POLL_INTERVAL="${PR_WATCH_INTERVAL:-60}"
STATE_DIR="${HOME:-/root}/.copilot"
WATCHLIST_FILE="${STATE_DIR}/pr-watchlist.json"
WATCHLIST_LOCK="${STATE_DIR}/pr-watchlist.lock"
NOTIFICATIONS_FILE="${STATE_DIR}/pr-notifications.jsonl"
NOTIFICATIONS_LOCK="${STATE_DIR}/pr-notifications.lock"
PID_FILE="${STATE_DIR}/pr-watch-daemon.pid"
LOG_FILE="${STATE_DIR}/pr-watch-daemon.log"

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

log_msg() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${LOG_FILE}"
}

init_watchlist() {
    mkdir -p "${STATE_DIR}"
    if [[ ! -f "${WATCHLIST_FILE}" ]]; then
        printf '{"watched":[]}\n' > "${WATCHLIST_FILE}"
    fi
}

cleanup() {
    if [[ -f "${PID_FILE}" ]] && [[ "$(cat "${PID_FILE}" 2>/dev/null || true)" == "$$" ]]; then
        rm -f "${PID_FILE}"
    fi
}

read_watchlist_snapshot() {
    local snapshot
    acquire_lock "${WATCHLIST_LOCK}"
    init_watchlist
    snapshot="$(cat "${WATCHLIST_FILE}")"
    release_lock "${WATCHLIST_LOCK}"
    printf '%s' "${snapshot}"
}

fetch_threads_json() {
    local org_url="$1"
    local project="$2"
    local repo="$3"
    local pr_id="$4"
    local repo_id
    local threads_json

    repo_id="$(az repos show \
        --repo "${repo}" \
        --project "${project}" \
        --org "${org_url}" \
        --query id -o tsv)"
    [[ -n "${repo_id}" ]] || {
        log_msg "Failed to resolve repository id for ${project}/${repo}"
        return 1
    }

    threads_json="$(
        az devops invoke \
            --area git \
            --resource pullRequestThreads \
            --route-parameters "project=${project}" "repositoryId=${repo_id}" "pullRequestId=${pr_id}" \
            --http-method GET \
            --org "${org_url}" \
            --output json
    )" || {
        log_msg "Failed to fetch PR threads for ${project}/${repo} PR #${pr_id}"
        return 1
    }

    [[ -n "${threads_json//[[:space:]]/}" ]] || threads_json='{"value":[]}'
    echo "${threads_json}" | jq -e . >/dev/null || {
        log_msg "Invalid PR thread JSON for ${project}/${repo} PR #${pr_id}"
        return 1
    }
    printf '%s' "${threads_json}"
}

build_last_seen_threads() {
    local threads_json="$1"
    echo "${threads_json}" | jq -c '
        reduce (.value // [])[] as $thread ({};
            .[($thread.id | tostring)] = (($thread.comments // []) | length)
        )
    '
}

append_notifications() {
    local notification_lines="$1"
    [[ -n "${notification_lines}" ]] || return 0
    acquire_lock "${NOTIFICATIONS_LOCK}"
    printf '%s\n' "${notification_lines}" >> "${NOTIFICATIONS_FILE}"
    release_lock "${NOTIFICATIONS_LOCK}"
}

update_watch_state() {
    local org_url="$1"
    local project="$2"
    local repo="$3"
    local pr_id="$4"
    local last_seen_threads="$5"
    local tmp_file

    acquire_lock "${WATCHLIST_LOCK}"
    init_watchlist
    tmp_file="$(mktemp)"
    jq \
        --arg org "${org_url}" \
        --arg project "${project}" \
        --arg repo "${repo}" \
        --argjson prId "${pr_id}" \
        --argjson lastSeenThreads "${last_seen_threads}" \
        '
        .watched = [
            (.watched // [])[]
            | if .org == $org and .project == $project and .repo == $repo and .prId == $prId then
                .lastSeenThreads = $lastSeenThreads
              else
                .
              end
        ]
        ' "${WATCHLIST_FILE}" > "${tmp_file}"
    mv "${tmp_file}" "${WATCHLIST_FILE}"
    release_lock "${WATCHLIST_LOCK}"
}

process_entry() {
    local entry_json="$1"
    local org_url
    local project
    local repo
    local pr_id
    local previous_threads
    local threads_json
    local last_seen_threads
    local notification_lines

    org_url="$(echo "${entry_json}" | jq -r '.org')"
    project="$(echo "${entry_json}" | jq -r '.project')"
    repo="$(echo "${entry_json}" | jq -r '.repo')"
    pr_id="$(echo "${entry_json}" | jq -r '.prId')"
    previous_threads="$(echo "${entry_json}" | jq -c '.lastSeenThreads // {}')"

    if [[ -z "${org_url}" || "${org_url}" == "null" ]]; then
        if [[ -n "${AZURE_DEVOPS_ORG:-}" ]]; then
            org_url="https://dev.azure.com/${AZURE_DEVOPS_ORG}"
        else
            log_msg "Skipping ${project}/${repo} PR #${pr_id}: no org configured"
            return 0
        fi
    fi

    threads_json="$(fetch_threads_json "${org_url}" "${project}" "${repo}" "${pr_id}")" || return 0
    last_seen_threads="$(build_last_seen_threads "${threads_json}")"
    notification_lines="$(echo "${threads_json}" | jq -cr \
        --argjson prev "${previous_threads}" \
        --argjson prId "${pr_id}" \
        '
        (.value // [])[] as $thread
        | (($prev[$thread.id | tostring] // 0) | tonumber) as $previousCount
        | ($thread.comments // []) as $comments
        | if ($comments | length) > $previousCount then
            range($previousCount; ($comments | length)) as $idx
            | {
                prId: $prId,
                threadId: $thread.id,
                commentId: ($comments[$idx].id // ($idx + 1)),
                author: ($comments[$idx].author.displayName // $comments[$idx].author.uniqueName // "unknown"),
                content: ($comments[$idx].content // ""),
                filePath: ($thread.threadContext.filePath // ""),
                line: ($thread.threadContext.rightFileStart.line // $thread.threadContext.leftFileStart.line // null),
                ts: ($comments[$idx].publishedDate // $comments[$idx].lastUpdatedDate // "")
            }
          else
            empty
          end
        ')"

    if [[ -n "${notification_lines}" ]]; then
        append_notifications "${notification_lines}"
        log_msg "Recorded new review comments for ${project}/${repo} PR #${pr_id}"
    fi

    update_watch_state "${org_url}" "${project}" "${repo}" "${pr_id}" "${last_seen_threads}"
}

run_iteration() {
    local snapshot
    snapshot="$(read_watchlist_snapshot)"
    while IFS= read -r entry_json; do
        [[ -n "${entry_json}" ]] || continue
        process_entry "${entry_json}"
    done < <(echo "${snapshot}" | jq -c '.watched // [] | .[]')
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --once)
            RUN_ONCE=1
            shift
            ;;
        --interval)
            POLL_INTERVAL="${2:-}"
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

[[ "${POLL_INTERVAL}" =~ ^[0-9]+$ ]] || die "--interval must be a positive integer"
[[ "${POLL_INTERVAL}" -gt 0 ]] || die "--interval must be greater than zero"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v az >/dev/null 2>&1 || die "az is required"

mkdir -p "${STATE_DIR}"
init_watchlist
printf '%s\n' "$$" > "${PID_FILE}"
trap cleanup EXIT INT TERM
log_msg "PR watch daemon started (interval=${POLL_INTERVAL}s, run_once=${RUN_ONCE})"

while true; do
    run_iteration
    if [[ "${RUN_ONCE}" -eq 1 ]]; then
        break
    fi
    sleep "${POLL_INTERVAL}"
done
