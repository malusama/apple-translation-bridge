#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${APPLE_TRANSLATION_BUILD_DIR:-$repo_dir/.build}"
data_dir="${APPLE_TRANSLATION_DATA_DIR:-$HOME/.local/share/apple-translation-bridge}"
state_dir="${APPLE_TRANSLATION_STATE_DIR:-$HOME/.local/state/apple-translation-bridge}"
port="${APPLE_TRANSLATION_PORT:-3210}"
plist_path="$HOME/Library/LaunchAgents/com.local.apple-translation-bridge.plist"
dry_run=false

if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != --dry-run ]]; then
    echo "Usage: $0 [--dry-run output.plist]" >&2
    exit 2
  fi
  dry_run=true
  plist_path="$2"
fi

python3 - "$port" <<'PY'
import sys
try:
    if not 1 <= int(sys.argv[1]) <= 65535:
        raise ValueError()
except ValueError:
    raise SystemExit("APPLE_TRANSLATION_PORT must be between 1 and 65535")
PY

if [[ "$dry_run" == false ]]; then
  "$repo_dir/scripts/build.sh"
  launchctl bootout "gui/$(id -u)/com.local.apple-translation-bridge" 2>/dev/null || true
  mkdir -p "$data_dir" "$state_dir" "$(dirname "$plist_path")"
  cp "$build_dir/translation-worker" "$build_dir/server.py" "$build_dir/index.html" "$data_dir/"
  mkdir -p "$data_dir/AppleTranslationSetup.app/Contents/MacOS"
  cp "$build_dir/AppleTranslationSetup.app/Contents/MacOS/AppleTranslationSetup" "$data_dir/AppleTranslationSetup.app/Contents/MacOS/"
  cp "$build_dir/AppleTranslationSetup.app/Contents/Info.plist" "$data_dir/AppleTranslationSetup.app/Contents/"
  codesign --force --sign - "$data_dir/AppleTranslationSetup.app"
fi

python3 - "$plist_path" "$data_dir" "$state_dir" "$port" "$(python3 -c 'import sys; print(sys.executable)')" <<'PY'
import pathlib, plistlib, sys
plist_path, data_dir, state_dir, port, python = sys.argv[1:]
value = {
    "Label": "com.local.apple-translation-bridge",
    "ProgramArguments": [python, str(pathlib.Path(data_dir) / "server.py"), "--port", port, "--state-dir", state_dir],
    "WorkingDirectory": data_dir,
    "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
    "ProcessType": "Interactive",
    "EnvironmentVariables": {"PYTHONUNBUFFERED": "1", "LANG": "en_US.UTF-8"},
    "StandardOutPath": str(pathlib.Path(state_dir) / "server.log"),
    "StandardErrorPath": str(pathlib.Path(state_dir) / "server-error.log"),
}
path = pathlib.Path(plist_path)
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("wb") as output:
    plistlib.dump(value, output)
PY

if [[ "$dry_run" == true ]]; then
  echo "Wrote launchd preview: $plist_path"
  exit 0
fi

launchctl bootstrap "gui/$(id -u)" "$plist_path"
echo "Installed: http://127.0.0.1:$port/imme"
echo "Language setup: open '$data_dir/AppleTranslationSetup.app'"
