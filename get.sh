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

# Prefer a formal GitHub Release's tag; if none exists yet, fall back to the
# most recently pushed git tag; if there are no tags at all (or the API is
# unreachable/rate-limited), fall back to master. curl/jq failures are
# swallowed with `|| true` throughout so a flaky API call degrades one step
# rather than aborting the whole install.
REF="refs/heads/master"
LATEST_TAG="$(curl -fsSL --max-time 5 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)" || true
if [[ -z "$LATEST_TAG" ]]; then
  LATEST_TAG="$(curl -fsSL --max-time 5 "https://api.github.com/repos/$REPO/tags" 2>/dev/null | jq -r '.[0].name // empty' 2>/dev/null)" || true
fi
if [[ -n "$LATEST_TAG" ]]; then
  REF="refs/tags/$LATEST_TAG"
  echo "Downloading claude-code-permission-alarm $LATEST_TAG..."
else
  echo "Downloading claude-code-permission-alarm (no tags found, using master)..."
fi

curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" -o "$TMP_DIR/src.tar.gz"
tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR"
SRC_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

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
echo "To uninstall later: curl -fsSL https://raw.githubusercontent.com/$REPO/master/get-uninstall.sh | bash"
