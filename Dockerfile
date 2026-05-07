# syntax=docker/dockerfile:1
FROM ubuntu:24.04

# ── build arguments ─────────────────────────────────────────────────────────
# Override JAVA_VERSION to any SDKMAN identifier, e.g. "21.0.5-tem" or "25-graalce"
ARG JAVA_VERSION=25.0.1-tem
# Override GH_VERSION to pin the GitHub CLI release used in the image
ARG GH_VERSION=2.89.0
# Override GO_VERSION to pin the Go toolchain used to compile mcp-language-server
ARG GO_VERSION=1.24.3

# ── environment ──────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    SDKMAN_DIR=/root/.sdkman \
    JAVA_HOME=/root/.sdkman/candidates/java/current \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# ── base packages ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # essentials
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    # utilities
    git \
    zip \
    unzip \
    jq \
    file \
    # shells / process tools
    bash \
    procps \
    # editors
    nano \
    vim \
    # build
    build-essential \
    # locale
    locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js LTS (needed for npm-based MCP servers) ───────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ───────────────────────────────────────────────────────────────
# First try the Ubuntu-packaged version (always available, may be older).
# Then attempt to upgrade to the release version from GitHub so that the
# built-in `gh copilot` command is available.  The upgrade is best-effort:
# if GitHub releases cannot be reached the image still gets a usable gh.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/* \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.deb" \
        -o /tmp/gh.deb 2>/dev/null \
    && dpkg -i /tmp/gh.deb 2>/dev/null \
    && rm -f /tmp/gh.deb \
    || echo "Note: GitHub releases not reachable; using the Ubuntu-packaged gh."

# ── Azure CLI ─────────────────────────────────────────────────────────────────
# Best-effort: install when the Microsoft package repository is reachable.
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
    && rm -rf /var/lib/apt/lists/* \
    || echo "Note: Azure CLI installer not reachable; az will not be available."

# Install Azure DevOps extension for `az repos`/`az devops` commands.
# Best-effort: skipped when extension index cannot be reached.
RUN az extension add --name azure-devops --only-show-errors --yes \
    || echo "Note: azure-devops extension could not be installed; Azure DevOps commands may prompt at runtime."

# ── SDKMAN + Java toolchains ──────────────────────────────────────────────────
# Install SDKMAN non-interactively (best-effort).
# If get.sdkman.io is unreachable the install-sdkman-candidates.sh script
# falls back to Ubuntu apt packages automatically.
RUN curl -s https://get.sdkman.io | bash \
    || echo "Note: SDKMAN installer not reachable; will fall back to apt."

# Install Java, Maven, Gradle and Spring Boot CLI via SDKMAN.
# The helper script tries the exact ARG version first, then falls back to the
# latest available Temurin release with the same major, then to the default.
COPY install-sdkman-candidates.sh /tmp/install-sdkman-candidates.sh
RUN bash /tmp/install-sdkman-candidates.sh \
    && rm /tmp/install-sdkman-candidates.sh

# ── Eclipse JDT Language Server (jdtls) ─────────────────────────────────────
# Download the latest jdtls snapshot; provides Java code intelligence over LSP.
# Best-effort: skipped silently when eclipse.org is unreachable so the image
# still builds in network-restricted environments.
RUN mkdir -p /opt/jdtls \
    && curl -fsSL \
        "https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz" \
        -o /tmp/jdtls.tar.gz \
    && tar -xzf /tmp/jdtls.tar.gz -C /opt/jdtls \
    && rm /tmp/jdtls.tar.gz \
    || echo "Note: jdtls could not be downloaded; Java LSP will not be available."

# Install the jdtls launcher wrapper used by mcp-language-server.
COPY jdtls.sh /usr/local/bin/jdtls
RUN chmod +x /usr/local/bin/jdtls

# ── mcp-language-server (LSP → MCP bridge) ───────────────────────────────────
# Installs the bridge that exposes the jdtls Language Server as MCP tools
# (definition, references, diagnostics, hover, rename, …) so that the Copilot
# CLI can call them directly.
#
# Strategy: download Go, compile the binary, then remove Go to keep the image
# lean (all in one RUN layer so the intermediate files don't bloat the image).
# Best-effort: the whole step is skipped when golang.org / GitHub is unreachable.
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" \
        -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz \
    && GOPATH=/root/go /usr/local/go/bin/go install \
        github.com/isaacphi/mcp-language-server@latest \
    && cp /root/go/bin/mcp-language-server /usr/local/bin/mcp-language-server \
    && rm -rf /usr/local/go /root/go /root/.cache/go-build \
    || echo "Note: Go / mcp-language-server could not be installed; Java LSP navigation will not be available."

# Make SDKMAN candidate binaries available without sourcing init in every RUN
ENV PATH="\
/root/.sdkman/candidates/springboot/current/bin:\
/root/.sdkman/candidates/gradle/current/bin:\
/root/.sdkman/candidates/maven/current/bin:\
/root/.sdkman/candidates/java/current/bin:\
${PATH}"

# ── GitHub Copilot CLI agent ─────────────────────────────────────────────────
# Try to pre-install the agent binary at build time (best-effort).
# Without a valid GitHub token in the build environment this step is silently
# skipped; start-sandbox.sh bind-mounts a persistent host-side cache directory
# read-write so the binary is downloaded exactly once on the first container
# start and reused on every subsequent start without any re-download.
RUN printf 'y\n' | gh copilot version 2>/dev/null || \
    echo "Note: Copilot CLI agent could not be pre-installed; it will be installed on first run."

# ── shell initialisation ─────────────────────────────────────────────────────
# Source SDKMAN in interactive shells
RUN echo '\n# SDKMAN\nsource /root/.sdkman/bin/sdkman-init.sh' >> /root/.bashrc

# ── working directory ────────────────────────────────────────────────────────
WORKDIR /workspace

# ── entrypoint ───────────────────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
