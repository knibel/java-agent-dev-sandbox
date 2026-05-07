#!/usr/bin/env bats
# tests/mcp-mounts.bats – tests for lib/mcp-mounts.sh

setup() {
    # Each test gets a clean MOUNTS array and HOME pointing at a temp dir so
    # that real host ~/.copilot does not interfere.
    declare -ga MOUNTS=()
    export HOME
    HOME="$(mktemp -d)"
    source "${BATS_TEST_DIRNAME}/../lib/mcp-mounts.sh"
}

teardown() {
    rm -rf "$HOME"
}

# ── add_mount ─────────────────────────────────────────────────────────────────

@test "add_mount: adds entry to MOUNTS when source exists" {
    local src
    src="$(mktemp -d)"
    add_mount "$src" "/container/path" "ro"
    rm -rf "$src"
    [ "${#MOUNTS[@]}" -eq 2 ]
    [ "${MOUNTS[0]}" = "-v" ]
    [ "${MOUNTS[1]}" = "${src}:/container/path:ro" ]
}

@test "add_mount: does nothing when source does not exist" {
    add_mount "/nonexistent/path/xyz" "/container/path" "ro"
    [ "${#MOUNTS[@]}" -eq 0 ]
}

@test "add_mount: defaults opts to 'ro'" {
    local src
    src="$(mktemp -d)"
    add_mount "$src" "/container/path"
    rm -rf "$src"
    [ "${MOUNTS[1]}" = "${src}:/container/path:ro" ]
}

@test "add_mount: accepts 'rw' opts" {
    local src
    src="$(mktemp -d)"
    add_mount "$src" "/container/path" "rw"
    rm -rf "$src"
    [ "${MOUNTS[1]}" = "${src}:/container/path:rw" ]
}

# ── _resolve_mount_dir ────────────────────────────────────────────────────────

@test "_resolve_mount_dir: returns directory for a plain file" {
    local dir file
    dir="$(mktemp -d)"
    file="${dir}/script.py"
    touch "$file"
    run _resolve_mount_dir "$file"
    rm -rf "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = "$dir" ]
}

@test "_resolve_mount_dir: returns the directory itself for a directory path" {
    local dir
    dir="$(mktemp -d)"
    run _resolve_mount_dir "$dir"
    rm -rf "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = "$dir" ]
}

@test "_resolve_mount_dir: hoists out of .venv to project root" {
    local project venv file
    project="$(mktemp -d)"
    venv="${project}/.venv"
    mkdir -p "${venv}/bin"
    file="${venv}/bin/python"
    touch "$file"
    run _resolve_mount_dir "$file"
    rm -rf "$project"
    [ "$status" -eq 0 ]
    [ "$output" = "$project" ]
}

@test "_resolve_mount_dir: hoists out of venv (no dot) to project root" {
    local project venv file
    project="$(mktemp -d)"
    venv="${project}/venv"
    mkdir -p "${venv}/bin"
    file="${venv}/bin/activate"
    touch "$file"
    run _resolve_mount_dir "$file"
    rm -rf "$project"
    [ "$status" -eq 0 ]
    [ "$output" = "$project" ]
}

@test "_resolve_mount_dir: hoists out of node_modules to project root" {
    local project nm file
    project="$(mktemp -d)"
    nm="${project}/node_modules/.bin"
    mkdir -p "$nm"
    file="${nm}/some-tool"
    touch "$file"
    run _resolve_mount_dir "$file"
    rm -rf "$project"
    [ "$status" -eq 0 ]
    [ "$output" = "$project" ]
}

@test "_resolve_mount_dir: exits non-zero for a non-existent path" {
    run _resolve_mount_dir "/no/such/path/xyz"
    [ "$status" -ne 0 ]
}

# ── scan_mcp_paths ────────────────────────────────────────────────────────────

@test "scan_mcp_paths: does nothing when config file does not exist" {
    scan_mcp_paths "/nonexistent/mcp-config.json"
    [ "${#MOUNTS[@]}" -eq 0 ]
}

@test "scan_mcp_paths: mounts directory referenced as 'command'" {
    local cfg dir
    dir="$(mktemp -d)"
    cfg="$(mktemp)"
    cat > "$cfg" <<EOF
{
  "mcpServers": {
    "my-server": {
      "command": "${dir}",
      "args": []
    }
  }
}
EOF
    scan_mcp_paths "$cfg"
    rm -f "$cfg"
    rm -rf "$dir"
    # Should have added exactly one mount entry ("-v" + "<path>:<path>:ro")
    [ "${#MOUNTS[@]}" -eq 2 ]
    [ "${MOUNTS[0]}" = "-v" ]
    [[ "${MOUNTS[1]}" == "${dir}:${dir}:ro" ]]
}

@test "scan_mcp_paths: mounts directory referenced in 'args'" {
    local cfg dir
    dir="$(mktemp -d)"
    cfg="$(mktemp)"
    cat > "$cfg" <<EOF
{
  "mcpServers": {
    "my-server": {
      "command": "some-cmd",
      "args": ["${dir}"]
    }
  }
}
EOF
    scan_mcp_paths "$cfg"
    rm -f "$cfg"
    rm -rf "$dir"
    [ "${#MOUNTS[@]}" -eq 2 ]
    [[ "${MOUNTS[1]}" == "${dir}:${dir}:ro" ]]
}

@test "scan_mcp_paths: skips non-existent paths silently" {
    local cfg
    cfg="$(mktemp)"
    cat > "$cfg" <<'EOF'
{
  "mcpServers": {
    "ghost": {
      "command": "/no/such/binary"
    }
  }
}
EOF
    scan_mcp_paths "$cfg"
    rm -f "$cfg"
    [ "${#MOUNTS[@]}" -eq 0 ]
}

@test "scan_mcp_paths: deduplicates identical paths" {
    local cfg dir
    dir="$(mktemp -d)"
    cfg="$(mktemp)"
    cat > "$cfg" <<EOF
{
  "mcpServers": {
    "server-a": { "command": "${dir}" },
    "server-b": { "command": "${dir}" }
  }
}
EOF
    scan_mcp_paths "$cfg"
    rm -f "$cfg"
    rm -rf "$dir"
    # Still only one mount despite two references
    [ "${#MOUNTS[@]}" -eq 2 ]
}

@test "scan_mcp_paths: supports legacy 'servers' key" {
    local cfg dir
    dir="$(mktemp -d)"
    cfg="$(mktemp)"
    cat > "$cfg" <<EOF
{
  "servers": {
    "legacy": { "command": "${dir}" }
  }
}
EOF
    scan_mcp_paths "$cfg"
    rm -f "$cfg"
    rm -rf "$dir"
    [ "${#MOUNTS[@]}" -eq 2 ]
}

@test "scan_mcp_paths: hoists file in .venv to project root" {
    local cfg project venv file
    project="$(mktemp -d)"
    venv="${project}/.venv"
    mkdir -p "${venv}/bin"
    file="${venv}/bin/python3"
    touch "$file"
    cfg="$(mktemp)"
    cat > "$cfg" <<EOF
{
  "mcpServers": {
    "pyserver": { "command": "${file}" }
  }
}
EOF
    scan_mcp_paths "$cfg"
    rm -f "$cfg"
    rm -rf "$project"
    [ "${#MOUNTS[@]}" -eq 2 ]
    [[ "${MOUNTS[1]}" == "${project}:${project}:ro" ]]
}
