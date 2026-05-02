# java-agent-dev-sandbox

An on-demand Docker sandbox for Java development, driven by the
[GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli).
Run it once and you are immediately inside an AI-powered coding session with
full Java toolchains, Maven, Gradle, Spring Boot, Azure CLI and your local MCP
servers all wired up automatically.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker (≥ 24) | Must be running |
| `gh` CLI (≥ 2.x) | `brew install gh` / <https://cli.github.com> |
| Authenticated `gh` session | `gh auth login` |
| `jq` (optional) | Used to auto-mount MCP server paths; `brew install jq` |

---

## Quick start

```bash
# 1. Clone this repository
git clone https://github.com/knibel/java-agent-dev-sandbox.git
cd java-agent-dev-sandbox

# 2. Make the launcher executable (only needed once)
chmod +x start-sandbox.sh

# 3. Build the image and enter the Copilot CLI
./start-sandbox.sh
```

The first run builds the Docker image (takes a few minutes to install
SDKMAN, Java, Maven, Gradle, Spring Boot CLI and the Azure CLI).
Subsequent runs reuse the cached image and start in seconds.

---

## What the launcher script does

`start-sandbox.sh` inspects your home directory and mounts the relevant
parts as read-only volumes before handing control to the container:

| Host path | Container path | Access | Purpose |
|---|---|---|---|
| `~/.copilot/` | `/root/.copilot/` | read-only | Custom instructions & MCP config |
| `~/.copilot/mcp-config.json` | parsed | — | Any absolute paths referenced by MCP servers are also mounted |
| `~/.config/gh/` | `/root/.config/gh/` | read-only | GitHub / Copilot authentication token |
| `~/.local/share/gh/copilot/` | `/root/.local/share/gh/copilot/` | read-only | Pre-downloaded Copilot CLI binary (Linux hosts only; skips re-download) |
| `~/.azure/` | `/root/.azure/` | read-only | Azure CLI credentials & MSAL token cache |
| `<workspace>` (default: `$PWD`) | `/workspace/` | read-write | Your project files |

---

## Usage

```
./start-sandbox.sh [options] [-- <copilot-cli-args>]

Options
  -w, --workspace <dir>   Directory to mount as /workspace  (default: $PWD)
  -i, --image <name>      Docker image name/tag             (default: java-copilot-sandbox)
  --no-build              Skip image rebuild; use existing image
  --build-arg <ARG=VAL>   Pass extra docker build arguments
  -h, --help              Show help
```

Anything after `--` is forwarded verbatim to the Copilot CLI inside the
container.

### Examples

```bash
# Interactive session in the current directory
./start-sandbox.sh

# Mount a specific project
./start-sandbox.sh -w ~/projects/my-spring-app

# Start in autopilot mode with a task
./start-sandbox.sh -- --autopilot -i "Add unit tests to every service class"

# Resume the last session
./start-sandbox.sh -- --resume

# Use a different Java version at build time
./start-sandbox.sh --build-arg JAVA_VERSION=21.0.5-tem

# Skip rebuild (faster start after the first build)
./start-sandbox.sh --no-build
```

---

## Copilot CLI – key flags

The container launches with `--allow-all` by default (equivalent to
`--allow-all-tools --allow-all-paths --allow-all-urls`).  You can override
this by supplying flags after `--`.

```bash
# Allow only specific tools
./start-sandbox.sh -- --allow-tool=write --allow-tool='shell(git:*)'

# Deny a specific tool while allowing everything else
./start-sandbox.sh -- --allow-all-tools --deny-tool='shell(git push)'

# Extra flags via environment variable (added on top of defaults)
COPILOT_EXTRA_ARGS="--model gpt-4.1 --effort high" ./start-sandbox.sh
```

---

## MCP servers

The Copilot CLI reads MCP server configuration from
`~/.copilot/mcp-config.json` automatically.  Example file:

```jsonc
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "<token>" }
    },
    "my-local-server": {
      "command": "/home/user/tools/my-mcp-server/index.js",
      "args": []
    }
  }
}
```

`start-sandbox.sh` parses this file with `jq` and automatically mounts any
absolute filesystem paths it finds, so local MCP servers are available inside
the container at the same path.

`npx`-based servers work out of the box because Node.js is installed in the
image.

---

## Custom instructions

Place your standing instructions in `~/.copilot/` — the entire directory is
mounted read-only.  The Copilot CLI also reads `AGENTS.md` from the workspace
root.

```
~/.copilot/
├── mcp-config.json      # MCP server definitions
└── instructions.md      # (optional) personal coding style guide
```

For workspace-specific instructions, add an `AGENTS.md` in your project root.

---

## Java toolchains

The image ships with [SDKMAN!](https://sdkman.io) and the following candidates:

| Tool | Default version |
|---|---|
| Java | 25 (Temurin) – configurable via `JAVA_VERSION` build arg |
| Maven | latest stable |
| Gradle | latest stable |
| Spring Boot CLI | latest stable |

To use a different Java version, pass it as a build argument:

```bash
./start-sandbox.sh --build-arg JAVA_VERSION=21.0.5-tem
```

Inside the container you can also switch on the fly:

```bash
sdk install java 23.0.2-tem
sdk use java 23.0.2-tem
```

---

## Azure CLI

If `~/.azure` exists on the host it is mounted read-only so the Azure CLI
inside the container can reuse existing login sessions (including refresh
tokens from `az login`).

---

## Customising the image

Edit `Dockerfile` to add extra tools before rebuilding:

```dockerfile
# Example: install Python and the AWS CLI
RUN apt-get update && apt-get install -y python3-pip \
    && pip3 install awscli \
    && rm -rf /var/lib/apt/lists/*
```

Then rebuild:

```bash
./start-sandbox.sh  # automatically rebuilds
# or explicitly:
docker build -t java-copilot-sandbox .
```
