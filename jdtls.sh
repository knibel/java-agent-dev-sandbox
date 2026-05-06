#!/usr/bin/env bash
# jdtls.sh – thin launcher wrapper for Eclipse JDT Language Server.
#
# mcp-language-server starts this script as the LSP subprocess and
# communicates with it via stdin/stdout (the LSP default transport).
#
# Environment overrides
#   JDTLS_HOME       – installation directory  (default: /opt/jdtls)
#   JDTLS_DATA_DIR   – workspace-data directory (default: /tmp/jdtls-data)

set -euo pipefail

JDTLS_HOME="${JDTLS_HOME:-/opt/jdtls}"

# Use a fixed data directory inside the container; containers are started
# with --rm so /tmp is wiped on exit anyway.
DATA_DIR="${JDTLS_DATA_DIR:-/tmp/jdtls-data}"
mkdir -p "${DATA_DIR}"

# Locate the Equinox launcher JAR (the version number varies across releases).
LAUNCHER=$(ls "${JDTLS_HOME}/plugins/org.eclipse.equinox.launcher_"*.jar 2>/dev/null | head -1)
if [[ -z "${LAUNCHER}" ]]; then
    echo "Error: jdtls launcher JAR not found under ${JDTLS_HOME}/plugins/" >&2
    echo "       Install jdtls to ${JDTLS_HOME} or set JDTLS_HOME to the correct path." >&2
    exit 1
fi

# Select the right configuration directory for this CPU architecture.
case "$(uname -m)" in
    aarch64|arm64) CFG="${JDTLS_HOME}/config_linux_arm" ;;
    *)             CFG="${JDTLS_HOME}/config_linux" ;;
esac
[[ -d "${CFG}" ]] || CFG="${JDTLS_HOME}/config_linux"

exec java \
    -Declipse.application=org.eclipse.jdt.ls.core.id1 \
    -Dosgi.bundles.defaultStartLevel=4 \
    -Declipse.product=org.eclipse.jdt.ls.core.product \
    -Dlog.level=ALL \
    -Xmx1G \
    --add-modules=ALL-SYSTEM \
    --add-opens java.base/java.util=ALL-UNNAMED \
    --add-opens java.base/java.lang=ALL-UNNAMED \
    -jar "${LAUNCHER}" \
    -configuration "${CFG}" \
    -data "${DATA_DIR}" \
    "$@"
