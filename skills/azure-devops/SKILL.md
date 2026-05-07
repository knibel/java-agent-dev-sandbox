---
name: azure-devops
description: >
  Azure DevOps operations – listing repositories, reading files, creating
  branches, creating and updating pull requests, reading PR comment threads,
  posting inline code suggestions, and cloning repositories. Use this skill
  whenever the user asks about Azure DevOps repositories, branches, pull
  requests, code reviews, or any operation that involves Azure DevOps.
allowed-tools: shell
---

# Azure DevOps Skill

## Authentication

`AZURE_DEVOPS_EXT_PAT` is set in the environment — the Azure DevOps CLI
extension reads it automatically. **No `az devops login` is required.**

Prefer resolving an org URL once and passing `--org` explicitly in commands.
This avoids failures when no default org is configured:

```bash
ADO_ORG_URL="${AZURE_DEVOPS_ORG:+https://dev.azure.com/${AZURE_DEVOPS_ORG}}"
if [[ -z "${ADO_ORG_URL}" ]]; then
    ADO_ORG_URL="$(az devops configure --list \
        --query 'defaults.organization' -o tsv 2>/dev/null || true)"
fi
if [[ -z "${ADO_ORG_URL}" ]]; then
    echo "Set AZURE_DEVOPS_ORG or run: az devops configure --defaults organization=https://dev.azure.com/<ORG>" >&2
    exit 1
fi
```

You can still check or set defaults with:

```bash
az devops configure --list
az devops configure --defaults organization=https://dev.azure.com/<ORG>
```

Use `main` as the default branch for all branch-sensitive operations unless
the user explicitly requests a different branch.

---

## List repositories

```bash
az repos list --project <PROJECT> --org "${ADO_ORG_URL}" --output table
```

---

## Get repository details

```bash
az repos show --repo <REPO> --project <PROJECT> --org "${ADO_ORG_URL}"
```

---

## Read a file from a repository

**Option 1 – Clone the repository** (full access, works for any path or branch):

```bash
CLONE_URL=$(az repos show --repo <REPO> --project <PROJECT> \
    --org "${ADO_ORG_URL}" \
    --query remoteUrl -o tsv)
# Use GIT_ASKPASS to supply the PAT without exposing it in the process list
GIT_ASKPASS_SCRIPT=$(mktemp -t ado-askpass-XXXXXX) && chmod 700 "${GIT_ASKPASS_SCRIPT}"
printf '#!/bin/sh\necho "${AZURE_DEVOPS_EXT_PAT}"\n' > "${GIT_ASKPASS_SCRIPT}"
GIT_ASKPASS="${GIT_ASKPASS_SCRIPT}" git clone "${CLONE_URL}" /tmp/<REPO>
rm -f "${GIT_ASKPASS_SCRIPT}"
```

**Option 2 – Fetch a single file without a full clone** (faster for one file):

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --org "${ADO_ORG_URL}" --query id -o tsv)
OUTFILE=$(mktemp -t ado-item-XXXXXX)
rm -f "${OUTFILE}"  # az devops invoke --out-file requires a non-existent path
az devops invoke \
    --area git \
    --resource items \
    --route-parameters project=<PROJECT> repositoryId="${REPO_ID}" \
    --query-parameters "path=/<PATH/TO/FILE>&versionType=branch&version=main" \
    --accept-media-type text/plain \
    --org "${ADO_ORG_URL}" \
    --out-file "${OUTFILE}"
if [[ -f "${OUTFILE}" ]]; then
    cat "${OUTFILE}"
else
    echo "Failed to fetch file: az devops invoke did not create ${OUTFILE}" >&2
    rm -f "${OUTFILE}"
    exit 1
fi
rm -f "${OUTFILE}"
```

`--accept-media-type text/plain` returns raw file content, not JSON.
Use `--out-file` and read the file afterwards (for example with `cat`/`grep`).
Check that the file was actually created before reading it, because failed
requests can leave no output file behind.

---

## List directory contents

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --org "${ADO_ORG_URL}" --query id -o tsv)

az devops invoke \
    --area git \
    --resource items \
    --route-parameters project=<PROJECT> repositoryId="${REPO_ID}" \
    --query-parameters "scopePath=/<DIRECTORY/PATH>&recursionLevel=Full&versionType=branch&version=main" \
    --http-method GET \
    --org "${ADO_ORG_URL}" \
    --output json
```

Use `scopePath` when combining a directory query with `recursionLevel`.
Using `path=...&recursionLevel=...` causes the Azure DevOps API to reject the
request.

---

## Create a branch

```bash
# Resolve the commit SHA of the source branch first (default: main)
SOURCE_SHA=$(az repos ref list \
    --repo <REPO> --project <PROJECT> \
    --org "${ADO_ORG_URL}" \
    --filter refs/heads/main \
    --query "[0].objectId" -o tsv)

az repos ref create \
    --name refs/heads/<NEW_BRANCH> \
    --object-id "${SOURCE_SHA}" \
    --repo <REPO> \
    --project <PROJECT> \
    --org "${ADO_ORG_URL}"
```

---

## Create a pull request

```bash
az repos pr create \
    --repository <REPO> \
    --project <PROJECT> \
    --org "${ADO_ORG_URL}" \
    --source-branch <SOURCE_BRANCH> \
    --target-branch main \
    --title "<TITLE>" \
    --description "<DESCRIPTION>"
```

---

## List pull requests

```bash
az repos pr list \
    --project <PROJECT> \
    --repository <REPO> \
    --org "${ADO_ORG_URL}" \
    --status active
```

---

## Get pull request details

```bash
az repos pr show --id <PR_ID> --org "${ADO_ORG_URL}"
```

---

## Read PR comment threads

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --org "${ADO_ORG_URL}" --query id -o tsv)

az devops invoke \
    --area git \
    --resource pullRequestThreads \
    --route-parameters project=<PROJECT> repositoryId="${REPO_ID}" pullRequestId=<PR_ID> \
    --http-method GET \
    --org "${ADO_ORG_URL}" \
    --output json
```

---

## Post an inline suggestion (code comment) on a PR

Create a uniquely-named temp file with the thread payload, post it, then clean up:

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --org "${ADO_ORG_URL}" --query id -o tsv)

ADO_THREAD_FILE=$(mktemp -t ado-thread-XXXXXX)
cat > "${ADO_THREAD_FILE}" << 'PAYLOAD'
{
  "comments": [
    {
      "parentCommentId": 0,
      "content": "<YOUR SUGGESTION OR COMMENT>",
      "commentType": 1
    }
  ],
  "status": "active",
  "threadContext": {
    "filePath": "/<PATH/TO/FILE>",
    "rightFileStart": { "line": <START_LINE>, "offset": 1 },
    "rightFileEnd":   { "line": <END_LINE>,   "offset": 1 }
  }
}
PAYLOAD

az devops invoke \
    --area git \
    --resource pullRequestThreads \
    --route-parameters project=<PROJECT> repositoryId="${REPO_ID}" pullRequestId=<PR_ID> \
    --http-method POST \
    --org "${ADO_ORG_URL}" \
    --in-file "${ADO_THREAD_FILE}" \
    --api-version 7.1-preview.1 \
    --output json

rm -f "${ADO_THREAD_FILE}"
```

---

## Reply to an existing PR comment thread

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --org "${ADO_ORG_URL}" --query id -o tsv)

ADO_REPLY_FILE=$(mktemp -t ado-reply-XXXXXX)
cat > "${ADO_REPLY_FILE}" << 'PAYLOAD'
{
  "comments": [
    {
      "parentCommentId": 1,
      "content": "<YOUR REPLY>",
      "commentType": 1
    }
  ]
}
PAYLOAD

az devops invoke \
    --area git \
    --resource pullRequestThreadComments \
    --route-parameters project=<PROJECT> repositoryId="${REPO_ID}" pullRequestId=<PR_ID> threadId=<THREAD_ID> \
    --http-method POST \
    --org "${ADO_ORG_URL}" \
    --in-file "${ADO_REPLY_FILE}" \
    --output json

rm -f "${ADO_REPLY_FILE}"
```

---

## Update a pull request

```bash
az repos pr update \
    --id <PR_ID> \
    --org "${ADO_ORG_URL}" \
    --title "<NEW_TITLE>" \
    --description "<NEW_DESCRIPTION>"
```
