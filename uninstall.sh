#!/usr/bin/env bash
# Removes all bin/permission-hook.sh entries from Claude Code's settings.json,
# leaving every other hook untouched. Backs up first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="$SCRIPT_DIR/bin/permission-hook.sh"

SCOPE="user"
if [[ "${1:-}" == "--project" ]]; then
  SCOPE="project"
fi

if [[ "$SCOPE" == "project" ]]; then
  SETTINGS_FILE="$SCRIPT_DIR/.claude/settings.json"
else
  SETTINGS_FILE="$HOME/.claude/settings.json"
fi

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "No settings file at $SETTINGS_FILE, nothing to uninstall."
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not found on PATH" >&2
  exit 1
fi

BACKUP_FILE="${SETTINGS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS_FILE" "$BACKUP_FILE"
echo "Backed up existing settings to $BACKUP_FILE"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

jq \
  --arg cmd "$HOOK_PATH" \
  '
  .hooks = ((.hooks // {}) | with_entries(
    .value = (.value | map(
      .hooks = ((.hooks // []) | map(select(.command != $cmd)))
    ) | map(select((.hooks // []) | length > 0)))
  ) | with_entries(select((.value // []) | length > 0)))
  | if (.hooks // {}) == {} then del(.hooks) else . end
  ' \
  "$SETTINGS_FILE" >"$TMP_FILE"

if ! jq empty "$TMP_FILE" 2>/dev/null; then
  echo "error: generated settings.json is invalid JSON, aborting (original untouched)" >&2
  exit 1
fi

mv "$TMP_FILE" "$SETTINGS_FILE"
trap - EXIT

echo "Removed permission-timeout hooks from $SETTINGS_FILE (scope: $SCOPE)"
