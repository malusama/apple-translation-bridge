#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${APPLE_TRANSLATION_BUILD_DIR:-$repo_dir/.build}"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Build requires an Apple silicon Mac with macOS 26.4 or later." >&2
  exit 1
fi

sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
python3 - "$sdk_version" "$(sw_vers -productVersion)" <<'PY'
import re, sys
for name, raw in zip(("macOS SDK", "macOS"), sys.argv[1:]):
    parts = tuple(int(part) for part in re.findall(r"\d+", raw)[:2])
    if parts < (26, 4):
        raise SystemExit(f"{name} 26.4 or later is required; found {raw}")
PY

mkdir -p "$build_dir/AppleTranslationSetup.app/Contents/MacOS"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -O \
  -target arm64-apple-macos26.4 "$repo_dir/Sources/TranslationWorker.swift" "$repo_dir/Sources/TranslationProcessor.swift" \
  -o "$build_dir/translation-worker.next"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -O \
  -target arm64-apple-macos26.4 "$repo_dir/Sources/LanguageSetup.swift" \
  -o "$build_dir/AppleTranslationSetup.app/Contents/MacOS/AppleTranslationSetup.next"
mv "$build_dir/translation-worker.next" "$build_dir/translation-worker"
mv "$build_dir/AppleTranslationSetup.app/Contents/MacOS/AppleTranslationSetup.next" \
  "$build_dir/AppleTranslationSetup.app/Contents/MacOS/AppleTranslationSetup"
cp "$repo_dir/Setup-Info.plist" "$build_dir/AppleTranslationSetup.app/Contents/Info.plist"
codesign --force --sign - "$build_dir/AppleTranslationSetup.app"
cp "$repo_dir/server.py" "$repo_dir/index.html" "$build_dir/"
echo "Built: $build_dir"
