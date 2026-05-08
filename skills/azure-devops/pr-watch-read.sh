#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  pr-watch-read.sh

Notes:
  - Prints unread PR review notifications from ~/.copilot/pr-notifications.jsonl.
  - Moves consumed notifications into a timestamped .read archive file.
  - Returns 1 when there are no unread notifications.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

STATE_DIR="${HOME:-/root}/.copilot"
NOTIFICATIONS_FILE="${STATE_DIR}/pr-notifications.jsonl"
NOTIFICATIONS_LOCK="${STATE_DIR}/pr-notifications.lock"

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

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
mkdir -p "${STATE_DIR}"

acquire_lock "${NOTIFICATIONS_LOCK}"
if [[ ! -s "${NOTIFICATIONS_FILE}" ]]; then
    release_lock "${NOTIFICATIONS_LOCK}"
    exit 1
fi

archive_file="${NOTIFICATIONS_FILE}.$(date -u +%Y%m%dT%H%M%SZ).$$.read"
mv "${NOTIFICATIONS_FILE}" "${archive_file}"
release_lock "${NOTIFICATIONS_LOCK}"

jq -r -s '
    .[]
    | "PR #\(.prId) | \(.author // "unknown")"
      + (if ((.filePath // "") | length) > 0
          then " | \(.filePath)\(if .line != null then ":\(.line)" else "" end)"
          else ""
        end)
      + "\n"
      + (.content // "")
      + "\n"
' "${archive_file}"
