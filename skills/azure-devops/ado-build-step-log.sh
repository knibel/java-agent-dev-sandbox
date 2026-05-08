#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ado-build-step-log.sh --project <PROJECT> --build-id <BUILD_ID> \
      [--step-name <STEP_NAME> | --record-id <RECORD_GUID> | --task-id <TASK_GUID>] \
      [--failed-only] [--org <https://dev.azure.com/ORG>]

Notes:
  - Uses az devops invoke + build timeline to map step/task identity to log ID.
  - Fetches text log via build logs API and fails if output is empty.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

PROJECT=""
BUILD_ID=""
STEP_NAME=""
RECORD_ID=""
TASK_ID=""
FAILED_ONLY=0
ORG_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            PROJECT="${2:-}"
            shift 2
            ;;
        --build-id)
            BUILD_ID="${2:-}"
            shift 2
            ;;
        --step-name)
            STEP_NAME="${2:-}"
            shift 2
            ;;
        --record-id)
            RECORD_ID="${2:-}"
            shift 2
            ;;
        --task-id)
            TASK_ID="${2:-}"
            shift 2
            ;;
        --failed-only)
            FAILED_ONLY=1
            shift
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

[[ -n "${PROJECT}" ]] || die "--project is required"
[[ -n "${BUILD_ID}" ]] || die "--build-id is required"

selector_count=0
[[ -n "${STEP_NAME}" ]] && selector_count=$((selector_count + 1))
[[ -n "${RECORD_ID}" ]] && selector_count=$((selector_count + 1))
[[ -n "${TASK_ID}" ]] && selector_count=$((selector_count + 1))
[[ "${selector_count}" -eq 1 ]] || die "Specify exactly one of --step-name, --record-id, or --task-id"

if [[ -z "${ORG_URL}" ]]; then
    if [[ -n "${AZURE_DEVOPS_ORG:-}" ]]; then
        ORG_URL="https://dev.azure.com/${AZURE_DEVOPS_ORG}"
    fi
fi
if [[ -z "${ORG_URL}" ]]; then
    ORG_URL="$(az devops configure --list --query 'defaults.organization' -o tsv 2>/dev/null || true)"
fi
[[ -n "${ORG_URL}" ]] || die "Set --org, AZURE_DEVOPS_ORG, or az devops default organization"

timeline_json="$(
    az devops invoke \
        --area build \
        --resource timelines \
        --route-parameters "project=${PROJECT}" "buildId=${BUILD_ID}" \
        --http-method GET \
        --api-version 7.1 \
        --org "${ORG_URL}" \
        --output json
)"

[[ -n "${timeline_json//[[:space:]]/}" ]] || die "Timeline API returned empty output"
echo "${timeline_json}" | jq -e . >/dev/null || die "Timeline API returned invalid JSON"

selector_filter='.name == $selector'
selector_value="${STEP_NAME}"
if [[ -n "${RECORD_ID}" ]]; then
    selector_filter='.id == $selector'
    selector_value="${RECORD_ID}"
elif [[ -n "${TASK_ID}" ]]; then
    selector_filter='.task.id == $selector'
    selector_value="${TASK_ID}"
fi

candidate_json="$(echo "${timeline_json}" | jq -c \
    --arg selector "${selector_value}" \
    --argjson failed_only "${FAILED_ONLY}" \
    "
    [
      (.records // [])[]
      | select(${selector_filter})
      | select(.log.id != null)
      # failed-only mode intentionally targets explicit failed steps only.
      # Comparison is case-insensitive in case API values vary by casing.
      | select((\$failed_only == 0) or ((.result // \"\" | ascii_downcase) == \"failed\"))
    ]
    ")"

candidate_count="$(echo "${candidate_json}" | jq 'length')"
if [[ "${candidate_count}" -eq 0 ]]; then
    die "No timeline record matched the requested selector"
fi
if [[ "${candidate_count}" -gt 1 ]]; then
    die "Multiple timeline records matched; refine selector (record ids: $(echo "${candidate_json}" | jq -r '.[].id' | paste -sd, -))"
fi

selected_record="$(echo "${candidate_json}" | jq -c '.[0]')"
log_id="$(echo "${selected_record}" | jq -r '.log.id')"
[[ -n "${log_id}" && "${log_id}" != "null" ]] || die "Matched record has no log id"

outdir="$(mktemp -d -t ado-build-log-XXXXXX)"
outfile="${outdir}/log.txt"
az devops invoke \
    --area build \
    --resource logs \
    --route-parameters "project=${PROJECT}" "buildId=${BUILD_ID}" "logId=${log_id}" \
    --http-method GET \
    --accept-media-type text/plain \
    --api-version 7.1 \
    --org "${ORG_URL}" \
    --out-file "${outfile}" >/dev/null

if [[ ! -f "${outfile}" ]]; then
    rm -rf "${outdir}"
    die "Log API did not create output file for log id ${log_id}"
fi
if [[ ! -s "${outfile}" ]]; then
    rm -rf "${outdir}"
    die "Log API returned empty output for log id ${log_id}"
fi

cat "${outfile}"
rm -rf "${outdir}"
