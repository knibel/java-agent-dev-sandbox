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

If `AZURE_DEVOPS_ORG` was provided when the sandbox started, the default
organization URL has already been configured via `az devops configure`.
Check or set it with:

```bash
az devops configure --list
az devops configure --defaults organization=https://dev.azure.com/<ORG>
```

---

## List repositories

```bash
az repos list --project <PROJECT> --output table
```

---

## Get repository details

```bash
az repos show --repo <REPO> --project <PROJECT>
```

---

## Read a file from a repository

**Option 1 – Clone the repository** (full access, works for any path or branch):

```bash
CLONE_URL=$(az repos show --repo <REPO> --project <PROJECT> \
    --query remoteUrl -o tsv)
# Use GIT_ASKPASS to supply the PAT without exposing it in the process list
GIT_ASKPASS_SCRIPT=$(mktemp -t ado-askpass-XXXXXX) && chmod 700 "${GIT_ASKPASS_SCRIPT}"
printf '#!/bin/sh\necho "${AZURE_DEVOPS_EXT_PAT}"\n' > "${GIT_ASKPASS_SCRIPT}"
GIT_ASKPASS="${GIT_ASKPASS_SCRIPT}" git clone "${CLONE_URL}" /tmp/<REPO>
rm -f "${GIT_ASKPASS_SCRIPT}"
```

**Option 2 – Fetch a single file without a full clone** (faster for one file):

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --query id -o tsv)
az devops invoke \
    --area git \
    --resource items \
    --route-parameters project=<PROJECT> repositoryId="${REPO_ID}" \
    --query-parameters "path=/<PATH/TO/FILE>&versionType=branch&version=<BRANCH>" \
    --accept-media-type text/plain \
    --output json
```

---

## Create a branch

```bash
# Resolve the commit SHA of the source branch first
SOURCE_SHA=$(az repos ref list \
    --repo <REPO> --project <PROJECT> \
    --filter refs/heads/<SOURCE_BRANCH> \
    --query "[0].objectId" -o tsv)

az repos ref create \
    --name refs/heads/<NEW_BRANCH> \
    --object-id "${SOURCE_SHA}" \
    --repo <REPO> \
    --project <PROJECT>
```

---

## Create a pull request

```bash
az repos pr create \
    --repository <REPO> \
    --project <PROJECT> \
    --source-branch <SOURCE_BRANCH> \
    --target-branch <TARGET_BRANCH> \
    --title "<TITLE>" \
    --description "<DESCRIPTION>"
```

---

## List pull requests

```bash
az repos pr list \
    --project <PROJECT> \
    --repository <REPO> \
    --status active
```

---

## Get pull request details

```bash
az repos pr show --id <PR_ID>
```

---

## Read PR comment threads

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --query id -o tsv)

az devops invoke \
    --area git \
    --resource pullRequestThreads \
    --route-parameters project=<PROJECT> repositoryId="${REPO_ID}" pullRequestId=<PR_ID> \
    --http-method GET \
    --output json
```

---

## Post an inline suggestion (code comment) on a PR

Create a uniquely-named temp file with the thread payload, post it, then clean up:

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --query id -o tsv)

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
    --in-file "${ADO_THREAD_FILE}" \
    --api-version 7.1-preview.1 \
    --output json

rm -f "${ADO_THREAD_FILE}"
```

---

## Reply to an existing PR comment thread

```bash
REPO_ID=$(az repos show --repo <REPO> --project <PROJECT> --query id -o tsv)

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
    --in-file "${ADO_REPLY_FILE}" \
    --output json

rm -f "${ADO_REPLY_FILE}"
```

---

## Update a pull request

```bash
az repos pr update \
    --id <PR_ID> \
    --title "<NEW_TITLE>" \
    --description "<NEW_DESCRIPTION>"
```
