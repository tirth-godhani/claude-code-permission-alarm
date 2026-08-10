#!/usr/bin/env bash
# Registers bin/permission-hook.sh against Claude Code's PermissionRequest,
# Notification, PreToolUse, UserPromptSubmit, and Stop hooks. Idempotent:
# strips any prior entry for this tool before re-adding -- matched by
# *basename* (any command ending in /bin/permission-hook.sh), not exact
# path, so installing from a second location (e.g. get.sh into
# ~/.claude-code-permission-alarm after previously cloning the repo
# elsewhere) replaces the old registration instead of running both side by
# side and double-firing the alarm on every prompt. Backs up settings.json
# first and validates the result before writing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="$SCRIPT_DIR/bin/permission-hook.sh"

SCOPE="user"
if [[ "${1:-}" == "--project" ]]; then
  SCOPE="project"
fi

if [[ "$SCOPE" == "project" ]]; then
  SETTINGS_FILE="$SCRIPT_DIR/.claude/settings.json"
  mkdir -p "$SCRIPT_DIR/.claude"
else
  SETTINGS_FILE="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not found on PATH" >&2
  exit 1
fi

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo '{}' >"$SETTINGS_FILE"
fi

BACKUP_FILE="${SETTINGS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS_FILE" "$BACKUP_FILE"
echo "Backed up existing settings to $BACKUP_FILE"

OLD_PATHS="$(jq -r --arg cmd "$HOOK_PATH" '
  [(.hooks // {}) | to_entries[].value[]?.hooks[]?.command
   | select(. != null and (endswith("/bin/permission-hook.sh")) and . != $cmd)] | unique | .[]
' "$SETTINGS_FILE" 2>/dev/null || true)"
if [[ -n "$OLD_PATHS" ]]; then
  echo "Replacing a previous install found at:"
  echo "$OLD_PATHS" | sed 's/^/  /'
fi

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

jq \
  --arg cmd "$HOOK_PATH" \
  '
  def strip_ours($events):
    reduce $events[] as $e (.;
      .hooks[$e] = ((.hooks[$e] // []) | map(
        .hooks = ((.hooks // []) | map(select((.command // "") | endswith("/bin/permission-hook.sh") | not)))
      ) | map(select((.hooks // []) | length > 0)))
    );

  def add_ours($event; $matcher):
    .hooks[$event] = ((.hooks[$event] // []) + [
      ({hooks: [{type: "command", command: $cmd, timeout: 5}]}
        + (if $matcher != "" then {matcher: $matcher} else {} end))
    ]);

  strip_ours(["PermissionRequest","PermissionDenied","Notification","PreToolUse","PostToolUse","UserPromptSubmit","Stop","SubagentStop"])
  | add_ours("PermissionRequest"; "")
  | add_ours("PermissionDenied"; "")
  | add_ours("Notification"; "permission_prompt")
  | add_ours("PreToolUse"; "")
  | add_ours("PostToolUse"; "")
  | add_ours("UserPromptSubmit"; "")
  | add_ours("Stop"; "")
  | add_ours("SubagentStop"; "")
  ' \
  "$SETTINGS_FILE" >"$TMP_FILE"

if ! jq empty "$TMP_FILE" 2>/dev/null; then
  echo "error: generated settings.json is invalid JSON, aborting (original untouched)" >&2
  exit 1
fi

mv "$TMP_FILE" "$SETTINGS_FILE"
trap - EXIT

echo "Installed permission-timeout hooks into $SETTINGS_FILE (scope: $SCOPE)"
echo "Edit $SCRIPT_DIR/config.env to configure timeout, sound, and attention command."
echo "Run tests/run-tests.sh to verify."
