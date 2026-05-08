# Makefile – developer convenience targets for java-agent-dev-sandbox.
#
# Targets:
#   make help   – show this help
#   make lint   – check all shell scripts for syntax errors
#   make test   – run the bats unit-test suite
#   make all    – lint then test

.PHONY: all help lint test

SHELL_SCRIPTS := entrypoint.sh install-sdkman-candidates.sh install.sh jdtls.sh start-sandbox.sh \
                 lib/common.sh lib/shell-config.sh lib/mcp-mounts.sh lib/update.sh \
                 skills/azure-devops/ado-build-step-log.sh \
                 skills/azure-devops/pr-watch-daemon.sh \
                 skills/azure-devops/pr-watch-register.sh \
                 skills/azure-devops/pr-watch-read.sh
TEST_FILES    := tests/common.bats tests/shell-config.bats tests/mcp-mounts.bats tests/update.bats \
                 tests/azure-devops-skill.bats tests/pr-watch.bats

all: lint test

help:
	@echo "Available targets:"
	@echo "  lint   – syntax-check all shell scripts with 'bash -n'"
	@echo "  test   – run the bats unit-test suite (installs bats if absent)"
	@echo "  all    – lint then test"

# ── lint ──────────────────────────────────────────────────────────────────────
lint:
	@echo "▶  Checking shell script syntax …"
	bash -n $(SHELL_SCRIPTS)
	@echo "✅ All syntax checks passed."

# ── test ──────────────────────────────────────────────────────────────────────
# Install bats when it is not already on PATH (requires sudo / apt on Debian/Ubuntu).
test: _ensure_bats
	bats $(TEST_FILES)

_ensure_bats:
	@command -v bats >/dev/null 2>&1 || { \
	    echo "bats not found – installing via apt …"; \
	    sudo apt-get install -y bats; \
	}
