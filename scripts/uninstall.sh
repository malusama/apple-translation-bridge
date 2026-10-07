#!/bin/bash
set -euo pipefail

plist_path="$HOME/Library/LaunchAgents/com.local.apple-translation-bridge.plist"
launchctl bootout "gui/$(id -u)/com.local.apple-translation-bridge" 2>/dev/null || true
if [[ -f "$plist_path" ]]; then
  rm "$plist_path"
fi
echo "Removed the launchd service. Installed files, logs and Apple language packs are retained."
