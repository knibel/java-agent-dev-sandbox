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
| `secret-tool` (optional) | Used to read GitHub or Azure DevOps PATs from the Linux keychain; `sudo apt install libsecret-tools` (Debian/Ubuntu) or `sudo dnf install libsecret` (Fedora/RHEL) |

---

## Quick start

```bash
# 1. Clone this repository
git clone https://github.com/knibel/java-agent-dev-sandbox.git
cd java-agent-dev-sandbox

# 2. Run the install script (builds the image + registers a shell alias)
chmod +x install.sh && ./install.sh

# Optional: persist your Azure DevOps org for future sandbox runs
./install.sh --devops-org contoso

# 3. Reload your shell config
source ~/.bashrc   # or ~/.zshrc
```

The install script:
- Builds the Docker image (takes a few minutes the first time to install SDKMAN, Java, Maven, Gradle, Spring Boot CLI and the Azure CLI).
- Adds a `copilot-sandbox` alias to `~/.bashrc` / `~/.zshrc`.

After that, launch from **any** directory with a single command:

```bash
cd ~/projects/my-spring-app
copilot-sandbox
```

`$PWD` is automatically mounted as `/workspace` and Copilot starts there.

### Manual start (without the alias)

```bash
./start-sandbox.sh
```

Subsequent runs reuse the cached image and start in seconds.

---

## Install script options

```
./install.sh [options]

Options
  --no-build          Skip the initial Docker image build
  --alias <name>      Alias name to register  (default: copilot-sandbox)
  --devops-org <org>  Persist the Azure DevOps org for future sandbox runs
  -h, --help          Show help
```

The install script manages a small block in `~/.bashrc` / `~/.zshrc` containing
the sandbox alias and, when provided, `AZURE_DEVOPS_ORG`.

`--devops-org` overrides the current `AZURE_DEVOPS_ORG` for that install run.
If neither is set, re-running `install.sh` keeps any previously saved org.

> **Note:** the managed shell block stores the absolute path to the cloned
> repository. If you move the repository, re-run `install.sh` to update it.

---

## What the launcher script does

`start-sandbox.sh` inspects your home directory and mounts the relevant
parts as read-only volumes before handing control to the container:

| Host path | Container path | Access | Purpose |
|---|---|---|---|
| `~/.copilot/` | `/root/.copilot/` | read-only | Custom instructions & MCP config |
| `~/.copilot/mcp-config.json` | parsed | — | Any absolute paths referenced by MCP servers are also mounted |
| `~/.config/gh/` | `/root/.config/gh/` | read-only | GitHub / Copilot authentication token **(GitHub CLI mode only – not mounted in PAT mode)** |
| `~/.local/share/gh/copilot/` | `/root/.local/share/gh/copilot/` | read-only | Pre-downloaded Copilot CLI binary (Linux hosts only; skips re-download) |
| `~/.azure/` | — | — | Not mounted (Azure DevOps authentication is PAT-only) |
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

When a binary lives inside a virtual environment (`.venv/bin/`, `venv/bin/`,
etc.) or a `node_modules` directory, the script walks up to the **project root**
(the parent of the venv / `node_modules` directory) and mounts that instead.
This ensures the Python interpreter, installed packages, and any other project
files are all accessible at their original absolute paths, which is required for
the MCP server process to start correctly.

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

## Java code navigation (LSP)

The image bundles two complementary layers of Java code intelligence, so
Copilot can navigate Java projects whether MCP is enabled or not.

| Tool | Role |
|---|---|
| [Eclipse JDT Language Server](https://github.com/eclipse/eclipse.jdt.ls) (`jdtls`) | Java Language Server – type-aware code intelligence |
| [`mcp-language-server`](https://github.com/isaacphi/mcp-language-server) | LSP → MCP bridge – exposes LSP capabilities as Copilot MCP tools |

### Layer 1 – Native LSP skill (always active)

Copilot CLI has built-in LSP support: when a language server is registered in
`~/.copilot/lsp-config.json`, Copilot uses it automatically for any operation
that benefits from semantic code understanding.

At container start `entrypoint.sh` registers `jdtls` directly as the native
Java language server:

```jsonc
// ~/.copilot/lsp-config.json (auto-injected)
{
  "lspServers": {
    "java": {
      "command": "jdtls",
      "args": [],
      "fileExtensions": { ".java": "java" }
    }
  }
}
```

Native LSP operations available to Copilot:

| Operation | What Copilot can do |
|---|---|
| Go to definition | Find where a symbol is defined |
| Find references | Find every usage of a symbol |
| Hover | Type info and Javadoc for a symbol |
| Rename | Rename a symbol across the entire project |
| Document symbols | List all symbols in a file |
| Workspace symbol search | Search for symbols by name |
| Go to implementation | Find implementations of an interface |
| Incoming / outgoing calls | Navigate call graphs |

### Layer 2 – MCP tool-server (when MCP is enabled)

`entrypoint.sh` also registers `jdtls` via the `mcp-language-server` bridge
in `~/.copilot/mcp-config.json`, giving Copilot explicit MCP tool calls:

```jsonc
// ~/.copilot/mcp-config.json (auto-injected)
{
  "mcpServers": {
    "java-language-server": {
      "command": "mcp-language-server",
      "args": ["--workspace", "/workspace", "--lsp", "jdtls"]
    }
  }
}
```

MCP tools exposed: `definition` · `references` · `diagnostics` · `hover` ·
`rename_symbol` · `edit_file`

> **Note:** both tools are installed from the internet during `docker build`.
> If the build runs in a network-restricted environment the tools are silently
> skipped and Java LSP will not be available; all other sandbox functionality
> is unaffected.

### Overriding the Java LSP configuration

The entrypoint only injects each entry when the key is **not already present**,
so you can override either layer from your host-side config files:

| To override… | Edit this file on your host | Key to add |
|---|---|---|
| Native LSP skill | `~/.copilot/lsp-config.json` | `lspServers.java` |
| MCP tool-server | `~/.copilot/mcp-config.json` | `mcpServers.java-language-server` |

You can also verify or reload the native LSP server from inside a Copilot CLI
session with the `/lsp` slash commands:

```
/lsp            # show status of all configured LSP servers
/lsp test java  # test that jdtls starts correctly
/lsp reload     # reload LSP configs from disk
```

---

## GitHub authentication

The sandbox supports two mutually exclusive authentication modes for GitHub /
GitHub Copilot.  The mode is chosen automatically at start-up based on whether
a PAT is stored in your Linux keychain.

### Mode A – PAT mode (recommended, least-privilege)

Store a scoped GitHub Personal Access Token in your Linux keychain once:

```bash
# Store the PAT (you will be prompted for the token value)
secret-tool store --label "GitHub PAT" \
                  service github-pat account default
```

When a PAT is found at container start:
- The token is forwarded into the container as `GH_TOKEN` via a private
  env-file (never visible in `ps` output or the Docker command line).
- `~/.config/gh` is **not** mounted – the container has no access to your
  broader GitHub CLI session or credentials.
- The `gh` CLI and Copilot CLI inside the container automatically use
  `GH_TOKEN` for all API calls.

To remove the PAT and revert to GitHub CLI mode:

```bash
secret-tool clear service github-pat account default
```

> **Prerequisite:** `secret-tool` must be installed on the host
> (`sudo apt install libsecret-tools` on Debian/Ubuntu).

### Mode B – GitHub CLI mode (automatic fallback)

When no PAT is found in the keychain (or `secret-tool` is not installed),
`start-sandbox.sh` falls back to the original behaviour:
- `~/.config/gh` is mounted **read-only** from the host.
- The token from `gh auth token` is forwarded into the container as `GH_TOKEN`.
- If no token is available, the entrypoint runs `gh auth login` before
  launching Copilot.

---

## Azure DevOps authentication (PAT-only)

Store a scoped Azure DevOps Personal Access Token in your Linux keychain once:

```bash
# Store the PAT (you will be prompted for the token value)
secret-tool store --label "Azure DevOps PAT" \
                  service azure-devops-pat account default
```

At container start:
- The token is forwarded into the container as `AZURE_DEVOPS_EXT_PAT`
  (read automatically by the `az devops` extension — no login needed).
- `~/.azure` is **not** mounted – the container has no access to your broader
  Azure CLI credentials.
- The `az` binary inside the container is replaced by a wrapper that allows
  only Azure DevOps extension command groups (`az devops`, `az repos`,
  `az boards`, `az pipelines`, `az artifacts`) and refuses all other
  invocations with a clear error message, preventing accidental use of Azure
  CLI with broader-than-intended permissions.
- The built-in **Azure DevOps native skill** (`skills/azure-devops/SKILL.md`)
  is installed into `~/.copilot/skills/azure-devops/` automatically.  Copilot
  loads this skill when you ask about repositories, branches, or pull requests.

You can persist your Azure DevOps organization during install so Copilot and
the Azure DevOps skill always start with the same default org:

```bash
./install.sh --devops-org contoso
```

Or set it manually before launching so that `az` commands don't need `--org` on
every call:

```bash
export AZURE_DEVOPS_ORG="contoso"
./start-sandbox.sh
```

When `AZURE_DEVOPS_ORG` is set, the sandbox also auto-appends
`--org https://dev.azure.com/<ORG>` for Azure DevOps command groups if omitted.
The built-in Azure DevOps skill treats `main` as the default branch unless a
different branch is explicitly requested.

### What the Azure DevOps skill can do

| Operation | How Copilot does it |
|---|---|
| List repositories | `az repos list` |
| Read a file | `git clone` with PAT, or `az devops invoke` (items API) |
| Create a branch | `az repos ref create` |
| Create a pull request | `az repos pr create` |
| List / read PR comments | `az devops invoke` (pullRequestThreads API) |
| Post inline PR suggestion | `az devops invoke` (pullRequestThreads POST) |
| Reply to a PR thread | `az devops invoke` (pullRequestThreadComments POST) |
| Update a pull request | `az repos pr update` |

To remove the PAT:

```bash
secret-tool clear service azure-devops-pat account default
```

> **Prerequisite:** `secret-tool` must be installed on the host
> (`sudo apt install libsecret-tools` on Debian/Ubuntu).

If no PAT is found in the keychain (or `secret-tool` is not installed),
`start-sandbox.sh` exits with a clear setup message.

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
