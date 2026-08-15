#!/usr/bin/env bash
# One-command remote uninstaller -- the counterpart to get.sh. Runs the
# uninstall.sh already sitting in the installed copy (put there by get.sh),
# then deletes the install folder. Lets people who installed with the
# one-line curl command uninstall the same way, without having to remember
# where it was installed or type out `rm -rf` themselves.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tirth-godhani/claude-code-permission-alarm/master/get-uninstall.sh | bash
set -euo pipefail

INSTALL_DIR="${CLAUDE_ALARM_INSTALL_DIR:-$HOME/.claude-code-permission-alarm}"

if [[ ! -f "$INSTALL_DIR/uninstall.sh" ]]; then
  echo "Nothing installed at $INSTALL_DIR -- nothing to do."
  exit 0
fi

"$INSTALL_DIR/uninstall.sh" "$@"
rm -rf "$INSTALL_DIR"

echo "Removed $INSTALL_DIR"
