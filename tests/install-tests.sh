#!/usr/bin/env bash
# Tests for install.sh / uninstall.sh: verifies the settings.json merge/strip
# logic preserves unrelated hooks, is idempotent, and de-duplicates across
# install locations. Runs the real scripts against an isolated $HOME so the
# machine's actual ~/.claude/settings.json is never touched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL: $1 -- $2"; }

new_home() {
  local n="$1"
  local h="$TEST_TMP/$n"
  mkdir -p "$h/.claude"
  echo "$h"
}

echo "=== install.sh / uninstall.sh test suite ==="

# 1. Fresh install registers every expected hook event
{
  name="fresh_install_registers_all_events"
  h="$(new_home "$name")"
  HOME="$h" "$ROOT/install.sh" >/dev/null
  events="$(jq -r '.hooks | keys | sort | join(",")' "$h/.claude/settings.json")"
  expected="Notification,PermissionDenied,PermissionRequest,PostToolUse,PreToolUse,Stop,SubagentStop,UserPromptSubmit"
  if [[ "$events" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected [$expected], got [$events]"
  fi
}

# 2. A pre-existing, unrelated hook survives install
{
  name="unrelated_hook_survives_install"
  h="$(new_home "$name")"
  jq -n '{hooks: {SessionStart: [{hooks: [{type:"command", command:"/some/other/hook.sh"}]}]}}' \
    >"$h/.claude/settings.json"
  HOME="$h" "$ROOT/install.sh" >/dev/null
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$h/.claude/settings.json")"
  if [[ "$cmd" == "/some/other/hook.sh" ]]; then
    pass "$name"
  else
    fail "$name" "unrelated SessionStart hook was lost"
  fi
}

# 3. The same unrelated hook survives uninstall, and our hooks are gone
{
  name="unrelated_hook_survives_uninstall"
  h="$(new_home "$name")"
  jq -n '{hooks: {SessionStart: [{hooks: [{type:"command", command:"/some/other/hook.sh"}]}]}}' \
    >"$h/.claude/settings.json"
  HOME="$h" "$ROOT/install.sh" >/dev/null
  HOME="$h" "$ROOT/uninstall.sh" >/dev/null
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$h/.claude/settings.json")"
  our_count="$(jq -r '.hooks.PermissionRequest // [] | length' "$h/.claude/settings.json")"
  if [[ "$cmd" == "/some/other/hook.sh" && "$our_count" -eq 0 ]]; then
    pass "$name"
  else
    fail "$name" "expected unrelated hook kept and our hooks removed, got cmd=$cmd our_count=$our_count"
  fi
}

# 4. Re-running install.sh is idempotent -- no duplicate entries
{
  name="reinstall_is_idempotent"
  h="$(new_home "$name")"
  HOME="$h" "$ROOT/install.sh" >/dev/null
  HOME="$h" "$ROOT/install.sh" >/dev/null
  count="$(jq -r '.hooks.PermissionRequest | length' "$h/.claude/settings.json")"
  if [[ "$count" -eq 1 ]]; then
    pass "$name"
  else
    fail "$name" "expected exactly 1 entry after reinstalling, got $count"
  fi
}

# 5. A different install location is replaced, not duplicated (regression
# test for the verified double-alarm bug: installing from two locations used
# to register two independent hooks, firing the alarm twice per prompt).
{
  name="different_install_location_deduplicated"
  h="$(new_home "$name")"
  jq -n --arg cmd "/some/other/path/bin/permission-hook.sh" \
    '{hooks: {PermissionRequest: [{hooks: [{type:"command", command:$cmd, timeout:5}]}]}}' \
    >"$h/.claude/settings.json"
  HOME="$h" "$ROOT/install.sh" >/dev/null
  count="$(jq -r '.hooks.PermissionRequest | length' "$h/.claude/settings.json")"
  cmd="$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$h/.claude/settings.json")"
  if [[ "$count" -eq 1 && "$cmd" == "$ROOT/bin/permission-hook.sh" ]]; then
    pass "$name"
  else
    fail "$name" "expected old install location replaced by this one, got count=$count cmd=$cmd"
  fi
}

# 6. uninstall.sh also removes an entry registered from a different location
{
  name="uninstall_removes_any_install_location"
  h="$(new_home "$name")"
  jq -n --arg cmd "/some/other/path/bin/permission-hook.sh" \
    '{hooks: {PermissionRequest: [{hooks: [{type:"command", command:$cmd, timeout:5}]}]}}' \
    >"$h/.claude/settings.json"
  HOME="$h" "$ROOT/uninstall.sh" >/dev/null
  count="$(jq -r '.hooks.PermissionRequest // [] | length' "$h/.claude/settings.json")"
  if [[ "$count" -eq 0 ]]; then
    pass "$name"
  else
    fail "$name" "expected the other-location entry to be removed, got count=$count"
  fi
}

# 7. Invalid pre-existing settings.json aborts safely, no partial write
{
  name="corrupt_settings_json_aborts_safely"
  h="$(new_home "$name")"
  printf '{not valid json' >"$h/.claude/settings.json"
  if HOME="$h" "$ROOT/install.sh" >/dev/null 2>&1; then
    fail "$name" "expected install.sh to fail on invalid pre-existing JSON"
  else
    pass "$name"
  fi
}

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
