#!/bin/bash
set -euo pipefail

plist_path="$HOME/Library/LaunchAgents/com.local.apple-translation-tunnel.plist"
state_dir="${APPLE_TRANSLATION_STATE_DIR:-$HOME/.local/state/apple-translation-bridge}"

if [[ $# -eq 1 && "$1" == --remove ]]; then
  launchctl bootout "gui/$(id -u)/com.local.apple-translation-tunnel" 2>/dev/null || true
  if [[ -f "$plist_path" ]]; then rm "$plist_path"; fi
  echo "Removed the SSH tunnel service."
  exit 0
fi

dry_run=false
if [[ $# -ge 1 && "$1" == --dry-run ]]; then
  if [[ $# -lt 3 ]]; then
    echo "Usage: $0 --dry-run output.plist SSH_HOST [LOCAL_PORT] [REMOTE_PORT]" >&2
    exit 2
  fi
  dry_run=true
  plist_path="$2"
  shift 2
fi

if [[ $# -lt 1 || $# -gt 3 || "$1" == -* ]]; then
  echo "Usage: $0 SSH_HOST [LOCAL_PORT] [REMOTE_PORT] | --remove" >&2
  exit 2
fi

ssh_host="$1"
local_port="${2:-3210}"
remote_port="${3:-3210}"
python3 - "$plist_path" "$state_dir" "$ssh_host" "$local_port" "$remote_port" <<'PY'
import pathlib, plistlib, sys
plist_path, state_dir, host, local_port, remote_port = sys.argv[1:]
for port in (local_port, remote_port):
    try:
        if not 1 <= int(port) <= 65535:
            raise ValueError()
    except ValueError:
        raise SystemExit("Ports must be between 1 and 65535")
value = {
    "Label": "com.local.apple-translation-tunnel",
    "ProgramArguments": [
        "/usr/bin/ssh", "-N", "-T", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
        "-o", "ConnectTimeout=10", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3", "-L", f"127.0.0.1:{local_port}:127.0.0.1:{remote_port}", host,
    ],
    "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
    "StandardOutPath": str(pathlib.Path(state_dir) / "tunnel.log"),
    "StandardErrorPath": str(pathlib.Path(state_dir) / "tunnel-error.log"),
}
path = pathlib.Path(plist_path)
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("wb") as output:
    plistlib.dump(value, output)
PY

if [[ "$dry_run" == true ]]; then
  echo "Wrote SSH tunnel preview: $plist_path"
  exit 0
fi

mkdir -p "$state_dir"
launchctl bootout "gui/$(id -u)/com.local.apple-translation-tunnel" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist_path"
echo "SSH tunnel installed: 127.0.0.1:$local_port -> $ssh_host:127.0.0.1:$remote_port"
