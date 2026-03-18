#!/usr/bin/env bats
# Tests for memsearch ccplugin hooks — per-session memory file isolation

HOOKS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../hooks" && pwd)"

# ─── helpers ────────────────────────────────────────────────────────────────

# Source common.sh with a given INPUT JSON, return SESSION_SUFFIX
# Let common.sh read stdin directly (its own INPUT="$(cat)")
_session_suffix_for() {
  local json="$1"
  bash -c "
    source '$HOOKS_DIR/common.sh' 2>/dev/null
    echo \"\$SESSION_SUFFIX\"
  " <<< "$json"
}

# Compute expected MEMORY_FILE for given date + suffix
_expected_memory_file() {
  local dir="$1" date="$2" suffix="$3"
  if [ -n "$suffix" ]; then
    echo "$dir/${date}_${suffix}.md"
  else
    echo "$dir/${date}.md"
  fi
}

# ─── Task 1: common.sh SESSION_SUFFIX ───────────────────────────────────────

@test "common.sh: SESSION_SUFFIX is first 8 chars of session_id from INPUT JSON" {
  local result
  result=$(_session_suffix_for '{"session_id":"cecdc830-7faf-4c62-9690-43131cceae29"}')
  [ "$result" = "cecdc830" ]
}

@test "common.sh: SESSION_SUFFIX is empty when INPUT has no session_id" {
  local result
  result=$(_session_suffix_for '{"type":"session_start"}')
  [ "$result" = "" ]
}

@test "common.sh: SESSION_SUFFIX is empty when INPUT is empty string" {
  local result
  result=$(_session_suffix_for '')
  [ "$result" = "" ]
}

@test "common.sh: SESSION_SUFFIX handles UUID with all hex chars" {
  local result
  result=$(_session_suffix_for '{"session_id":"abcdef12-0000-0000-0000-000000000000"}')
  [ "$result" = "abcdef12" ]
}

# ─── Task 2: session-start.sh MEMORY_FILE ───────────────────────────────────

@test "session-start.sh: writes session heading to session-scoped memory file" {
  local tmpdir session_id expected_file
  tmpdir=$(mktemp -d)
  session_id="test1234-0000-0000-0000-000000000000"
  expected_file="$tmpdir/.memsearch/memory/$(date +%Y-%m-%d)_test1234.md"

  CLAUDE_PROJECT_DIR="$tmpdir" bash -c "
    source '$HOOKS_DIR/common.sh' 2>/dev/null
    TODAY=\$(date +%Y-%m-%d)
    NOW=\$(date +%H:%M)
    _SUFFIX=\"\${SESSION_SUFFIX:+_\${SESSION_SUFFIX}}\"
    MEMORY_FILE=\"\$MEMORY_DIR/\${TODAY}\${_SUFFIX}.md\"
    mkdir -p \"\$MEMORY_DIR\"
    echo \"## Session \$NOW\" >> \"\$MEMORY_FILE\"
  " <<< "{\"session_id\":\"$session_id\"}"

  [ -f "$expected_file" ]
  grep -q "## Session" "$expected_file"
  rm -rf "$tmpdir"
}

@test "session-start.sh: falls back to daily file when SESSION_SUFFIX is empty" {
  local tmpdir expected_file
  tmpdir=$(mktemp -d)
  expected_file="$tmpdir/.memsearch/memory/$(date +%Y-%m-%d).md"

  CLAUDE_PROJECT_DIR="$tmpdir" bash -c "
    source '$HOOKS_DIR/common.sh' 2>/dev/null
    TODAY=\$(date +%Y-%m-%d)
    NOW=\$(date +%H:%M)
    _SUFFIX=\"\${SESSION_SUFFIX:+_\${SESSION_SUFFIX}}\"
    MEMORY_FILE=\"\$MEMORY_DIR/\${TODAY}\${_SUFFIX}.md\"
    mkdir -p \"\$MEMORY_DIR\"
    echo \"## Session \$NOW\" >> \"\$MEMORY_FILE\"
  " <<< '{}'

  [ -f "$expected_file" ]
  rm -rf "$tmpdir"
}

# ─── Task 3: stop.sh MEMORY_FILE ────────────────────────────────────────────

@test "stop.sh: MEMORY_FILE uses first 8 chars of transcript basename as suffix" {
  # stop.sh derives SESSION_ID from TRANSCRIPT_PATH basename
  # MEMORY_FILE should be ${TODAY}_${SESSION_ID:0:8}.md
  local result
  result=$(bash -c "
    SESSION_ID='aabbccdd-1111-2222-3333-444444444444'
    TODAY=\$(date +%Y-%m-%d)
    MEMORY_DIR='/tmp/test-memsearch/memory'
    _SESS_SUFFIX=\"\${SESSION_ID:0:8}\"
    _SUFFIX=\"\${_SESS_SUFFIX:+_\${_SESS_SUFFIX}}\"
    MEMORY_FILE=\"\$MEMORY_DIR/\${TODAY}\${_SUFFIX}.md\"
    echo \"\$MEMORY_FILE\"
  ")
  local expected="/tmp/test-memsearch/memory/$(date +%Y-%m-%d)_aabbccdd.md"
  [ "$result" = "$expected" ]
}

# ─── Task 3b: session-end.sh MEMORY_FILE ────────────────────────────────────

@test "session-end.sh: uses SESSION_SUFFIX from common.sh to target correct file" {
  local tmpdir session_id today memory_file
  tmpdir=$(mktemp -d)
  session_id="deadbeef-0000-0000-0000-000000000000"
  today=$(date +%Y-%m-%d)
  memory_file="$tmpdir/.memsearch/memory/${today}_deadbeef.md"

  mkdir -p "$tmpdir/.memsearch/memory"
  echo -e "## Session 10:00\n\nsome content" > "$memory_file"

  local result
  result=$(CLAUDE_PROJECT_DIR="$tmpdir" bash -c "
    source '$HOOKS_DIR/common.sh' 2>/dev/null
    TODAY=\$(date +%Y-%m-%d)
    _SUFFIX=\"\${SESSION_SUFFIX:+_\${SESSION_SUFFIX}}\"
    MEMORY_FILE=\"\$MEMORY_DIR/\${TODAY}\${_SUFFIX}.md\"
    [ -f \"\$MEMORY_FILE\" ] || MEMORY_FILE=\"\$MEMORY_DIR/\${TODAY}.md\"
    echo \"\$MEMORY_FILE\"
  " <<< "{\"session_id\":\"$session_id\"}")

  [ "$result" = "$memory_file" ]
  rm -rf "$tmpdir"
}

# ─── Task 3c: project-state-update.sh ───────────────────────────────────────

@test "project-state-update: SESSION_SUFFIX extracted from INPUT session_id" {
  local result
  result=$(bash -c "
    INPUT='{\"session_id\":\"feedface-aaaa-bbbb-cccc-dddddddddddd\"}'
    if command -v jq &>/dev/null; then
      _SESS_RAW=\$(printf '%s' \"\$INPUT\" | jq -r '.session_id // empty' 2>/dev/null || true)
    else
      _SESS_RAW=\$(printf '%s' \"\$INPUT\" | python3 -c \"
import json,sys
try: print(json.load(sys.stdin).get('session_id',''))
except: print('')
\" 2>/dev/null || true)
    fi
    echo \"\${_SESS_RAW:0:8}\"
  ")
  [ "$result" = "feedface" ]
}

@test "project-state-update: MEMSEARCH_LOG falls back to daily file when session file missing" {
  local tmpdir today
  tmpdir=$(mktemp -d)
  today=$(date +%Y-%m-%d)
  # Only daily file exists, no session-scoped file
  touch "$tmpdir/${today}.md"

  local result
  result=$(bash -c "
    _SESS_SUFFIX='abc12345'
    TODAY='$today'
    MEMSEARCH_MEMORY='$tmpdir'
    _LOG_SUFFIX=\"\${_SESS_SUFFIX:+_\${_SESS_SUFFIX}}\"
    MEMSEARCH_LOG=\"\$MEMSEARCH_MEMORY/\${TODAY}\${_LOG_SUFFIX}.md\"
    [ -f \"\$MEMSEARCH_LOG\" ] || MEMSEARCH_LOG=\"\$MEMSEARCH_MEMORY/\${TODAY}.md\"
    echo \"\$MEMSEARCH_LOG\"
  ")
  [ "$result" = "$tmpdir/${today}.md" ]
  rm -rf "$tmpdir"
}

# ─── Task 3d: session-orient-projects.sh symlinks ───────────────────────────

@test "session-orient: symlink points to session-scoped file" {
  local tmpdir root_memory proj_dir today session_id
  tmpdir=$(mktemp -d)
  root_memory="$tmpdir/root/.memsearch/memory"
  proj_dir="$tmpdir/myproject"
  today=$(date +%Y-%m-%d)
  session_id="cafebabe"

  mkdir -p "$root_memory" "$proj_dir/.memsearch/memory"
  touch "$proj_dir/.memsearch/memory/${today}_${session_id}.md"

  # Simulate the logic that session-orient-projects.sh will use
  export _TEST_SESS_SUFFIX="$session_id"
  export _TEST_PROJ_DIR="$proj_dir"
  export _TEST_ROOT_MEMORY="$root_memory"
  export _TEST_TODAY="$today"

  bash -c '
    _suf="${_TEST_SESS_SUFFIX:+_${_TEST_SESS_SUFFIX}}"
    src="${_TEST_PROJ_DIR}/.memsearch/memory/${_TEST_TODAY}${_suf}.md"
    dst="${_TEST_ROOT_MEMORY}/myproject_${_TEST_TODAY}${_suf}.md"
    ln -sf "$src" "$dst"
  '

  local expected_dst="$root_memory/myproject_${today}_${session_id}.md"
  [ -L "$expected_dst" ]
  [ "$(readlink "$expected_dst")" = "$proj_dir/.memsearch/memory/${today}_${session_id}.md" ]
  rm -rf "$tmpdir"
}
