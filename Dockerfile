FROM ubuntu:24.04

# ── build arguments ─────────────────────────────────────────────────────────
# Override JAVA_VERSION to any SDKMAN identifier, e.g. "21.0.5-tem" or "25-graalce"
ARG JAVA_VERSION=25.0.1-tem
# Override GH_VERSION to pin the GitHub CLI release used in the image
ARG GH_VERSION=2.89.0

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

# Make SDKMAN candidate binaries available without sourcing init in every RUN
ENV PATH="\
/root/.sdkman/candidates/springboot/current/bin:\
/root/.sdkman/candidates/gradle/current/bin:\
/root/.sdkman/candidates/maven/current/bin:\
/root/.sdkman/candidates/java/current/bin:\
${PATH}"

# ── GitHub Copilot CLI agent ─────────────────────────────────────────────────
# Accept the install prompt non-interactively so the agent binary is cached in
# the image.  The first `gh copilot` run inside the container will therefore
# never pause and ask "Would you like to install GitHub Copilot? [Y/n]".
# The download is best-effort; if GitHub releases are unreachable the image
# still builds and the binary will be fetched on first use instead.
RUN printf 'y\n' | gh copilot version 2>/dev/null || \
    echo "Warning: Copilot CLI agent could not be pre-installed; it will be installed on first run."

# ── shell initialisation ─────────────────────────────────────────────────────
# Source SDKMAN in interactive shells
RUN echo '\n# SDKMAN\nsource /root/.sdkman/bin/sdkman-init.sh' >> /root/.bashrc

# ── working directory ────────────────────────────────────────────────────────
WORKDIR /workspace

# ── entrypoint ───────────────────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
