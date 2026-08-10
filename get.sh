#!/usr/bin/env bash
# One-command remote installer. Downloads this tool from GitHub into a fixed
# local folder and runs install.sh -- so using it never requires manually
# git-cloning the repo first. Safe to re-run later to upgrade: an existing
# config.env (your sound/timeout choices) is kept, not overwritten.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tirth-godhani/claude-code-permission-alarm/master/get.sh | bash
set -euo pipefail

REPO="tirth-godhani/claude-code-permission-alarm"
BRANCH="master"
INSTALL_DIR="${CLAUDE_ALARM_INSTALL_DIR:-$HOME/.claude-code-permission-alarm}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this tool is macOS-only." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required. Install it first: brew install jq" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading claude-code-permission-alarm..."
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" -o "$TMP_DIR/src.tar.gz"
tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR"
SRC_DIR="$(find "$TMP_DIR" -maxdepth 1 -type d -name "*-$BRANCH")"

if [[ -z "$SRC_DIR" || ! -f "$SRC_DIR/install.sh" ]]; then
  echo "error: download didn't extract as expected." >&2
  exit 1
fi

# Keep an existing config.env across re-runs/upgrades instead of clobbering it.
KEPT_CONFIG=""
if [[ -f "$INSTALL_DIR/config.env" ]]; then
  KEPT_CONFIG="$TMP_DIR/config.env.keep"
  cp "$INSTALL_DIR/config.env" "$KEPT_CONFIG"
fi

mkdir -p "$INSTALL_DIR"
cp -R "$SRC_DIR"/. "$INSTALL_DIR"/

if [[ -n "$KEPT_CONFIG" ]]; then
  cp "$KEPT_CONFIG" "$INSTALL_DIR/config.env"
  echo "Kept your existing config.env (sound/timeout settings preserved)."
fi

chmod +x "$INSTALL_DIR"/install.sh "$INSTALL_DIR"/uninstall.sh "$INSTALL_DIR"/bin/*.sh "$INSTALL_DIR"/tests/*.sh 2>/dev/null || true

echo "Installed to $INSTALL_DIR"
echo ""
"$INSTALL_DIR/install.sh"

echo ""
echo "Edit $INSTALL_DIR/config.env any time to change the sound or timeout."
echo "To uninstall later: $INSTALL_DIR/uninstall.sh && rm -rf $INSTALL_DIR"
