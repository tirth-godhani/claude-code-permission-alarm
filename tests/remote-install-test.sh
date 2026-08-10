#!/usr/bin/env bash
# Smoke test for get.sh: runs the real one-command installer end-to-end
# against an isolated $HOME and install dir, so it never touches the real
# environment. This tests whatever is currently published on GitHub (a
# tagged release if one exists, master otherwise) -- it cannot see local,
# unpushed changes to get.sh or the rest of the repo, since that's exactly
# what get.sh itself downloads from.
#
# Requires network access to GitHub; skips (not fails) if GitHub is
# unreachable, so CI doesn't flake on a transient network issue.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

echo "=== get.sh smoke test ==="

if ! curl -fsSL --max-time 5 -o /dev/null "https://codeload.github.com"; then
  echo "SKIP: GitHub unreachable, skipping get.sh smoke test"
  exit 0
fi

HOME_DIR="$TEST_TMP/home"
mkdir -p "$HOME_DIR/.claude"
INSTALL_DIR="$TEST_TMP/install"

if HOME="$HOME_DIR" CLAUDE_ALARM_INSTALL_DIR="$INSTALL_DIR" bash "$ROOT/get.sh" >"$TEST_TMP/out.log" 2>&1; then
  ok=1
else
  ok=0
fi

fail=0
if [[ "$ok" -ne 1 ]]; then
  echo "  FAIL: get.sh exited non-zero"
  cat "$TEST_TMP/out.log"
  fail=1
fi
if [[ ! -x "$INSTALL_DIR/bin/permission-hook.sh" ]]; then
  echo "  FAIL: hook script was not installed at $INSTALL_DIR/bin/permission-hook.sh"
  fail=1
fi
cmd="$(jq -r '.hooks.PermissionRequest[0].hooks[0].command // empty' "$HOME_DIR/.claude/settings.json" 2>/dev/null)"
if [[ "$cmd" != "$INSTALL_DIR/bin/permission-hook.sh" ]]; then
  echo "  FAIL: settings.json not wired to the installed copy (got: '$cmd')"
  fail=1
fi

# Clean up the hook registration this test just created.
HOME="$HOME_DIR" "$INSTALL_DIR/uninstall.sh" >/dev/null 2>&1 || true

if [[ "$fail" -eq 0 ]]; then
  echo "  PASS: get_sh_end_to_end_install"
  echo ""
  echo "=== Results: 1 passed, 0 failed ==="
  exit 0
else
  echo ""
  echo "=== Results: 0 passed, 1 failed ==="
  exit 1
fi
