#!/usr/bin/env bash
# install-sdkman-candidates.sh
# Called during Docker image build to install Java toolchains.
#
# Primary path:  SDKMAN (get.sdkman.io) — provides the latest versions and
#                Spring Boot CLI.
# Fallback path: Ubuntu apt packages — used automatically when SDKMAN's
#                installer cannot be reached (e.g. restricted CI environments).
#
# The JAVA_VERSION build arg is injected as an environment variable.

set -euo pipefail

SDKMAN_INIT="${SDKMAN_DIR:-/root/.sdkman}/bin/sdkman-init.sh"

# ─────────────────────────────────────────────────────────────────────────────
# SDKMAN path
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "${SDKMAN_INIT}" ]]; then
    echo "SDKMAN found – installing Java toolchains via SDKMAN …"

    # shellcheck source=/dev/null
    source "${SDKMAN_INIT}"

    # ── Java ──────────────────────────────────────────────────────────────
    JAVA_MAJOR=$(echo "${JAVA_VERSION}" | cut -d. -f1 | cut -d- -f1)

    echo "Attempting to install Java ${JAVA_VERSION} …"
    if sdk install java "${JAVA_VERSION}" < /dev/null; then
        echo "Installed Java ${JAVA_VERSION}"
    else
        echo "Exact version not found; searching for latest Temurin ${JAVA_MAJOR} …"
        FALLBACK=$(sdk list java 2>/dev/null \
            | grep -E "\| *tem *\|" \
            | grep -E "\| *${JAVA_MAJOR}\." \
            | head -1 \
            | awk -F'|' '{gsub(/[[:space:]]/,""); print $NF}')
        if [[ -n "${FALLBACK}" ]]; then
            echo "Falling back to: ${FALLBACK}"
            sdk install java "${FALLBACK}" < /dev/null
        else
            echo "No Temurin ${JAVA_MAJOR} found; installing SDKMAN default Java …"
            sdk install java < /dev/null
        fi
    fi

    # ── Build tools ──────────────────────────────────────────────────────
    echo "Installing Maven …"
    sdk install maven < /dev/null

    echo "Installing Gradle …"
    sdk install gradle < /dev/null

    echo "Installing Spring Boot CLI …"
    sdk install springboot < /dev/null

    # ── Cleanup ───────────────────────────────────────────────────────────
    sdk flush archives
    sdk flush temp

    echo ""
    echo "Done – installed SDKMAN candidates:"
    sdk current

# ─────────────────────────────────────────────────────────────────────────────
# Fallback: Ubuntu apt packages
# Used when SDKMAN's installer could not be reached during docker build
# (e.g. network-restricted CI environments).
# ─────────────────────────────────────────────────────────────────────────────
else
    echo "SDKMAN not available; falling back to Ubuntu apt packages …"

    # apt-get update may report errors for unreachable external repos
    # (e.g. nodesource) – that's fine as long as the Ubuntu mirrors work.
    DEBIAN_FRONTEND=noninteractive apt-get update || true

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openjdk-25-jdk \
        maven \
        gradle
    rm -rf /var/lib/apt/lists/*

    # Create the SDKMAN candidate directory structure so that the JAVA_HOME
    # ENV variable (/root/.sdkman/candidates/java/current) still resolves
    # correctly even without SDKMAN installed.
    JDK_PATH=$(readlink -f /usr/bin/java | sed 's|/bin/java||')
    mkdir -p /root/.sdkman/candidates/java
    ln -sfn "${JDK_PATH}" /root/.sdkman/candidates/java/current

    # Symlink Maven so the PATH entry /root/.sdkman/candidates/maven/current/bin works.
    MAVEN_HOME=$(readlink -f /usr/bin/mvn | sed 's|/bin/mvn||')
    mkdir -p /root/.sdkman/candidates/maven
    [[ -d "${MAVEN_HOME}" ]] && ln -sfn "${MAVEN_HOME}" /root/.sdkman/candidates/maven/current || true

    # Symlink Gradle so the PATH entry /root/.sdkman/candidates/gradle/current/bin works.
    GRADLE_HOME=$(readlink -f /usr/share/gradle)
    mkdir -p /root/.sdkman/candidates/gradle
    [[ -d "${GRADLE_HOME}" ]] && ln -sfn "${GRADLE_HOME}" /root/.sdkman/candidates/gradle/current || true

    echo ""
    echo "Installed via apt:"
    java -version 2>&1
    mvn -version 2>&1 | head -1 || true
    gradle --version 2>&1 | head -3 || true
    echo ""
    echo "Note: Spring Boot CLI and latest Gradle require SDKMAN."
    echo "      Rebuild with unrestricted network access to get those tools."
fi
