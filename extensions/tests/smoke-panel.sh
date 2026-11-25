#!/bin/sh
set -eu

EXTENSIONS="$(cd "$(dirname "$0")/.." && pwd -P)"
SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/lumen-extension-panel.XXXXXX")"
trap 'rm -rf "$SMOKE"' EXIT
SMOKE="$(cd "$SMOKE" && pwd -P)"
APP="$SMOKE/Sample Lumen.app"

export PATH="$HOME/.cargo/bin:$PATH"
cargo build --locked --offline --manifest-path "$EXTENSIONS/Cargo.toml" --target-dir "$EXTENSIONS/target"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXTENSIONS/target/debug/lumen-extensions" "$APP/Contents/Resources/lumen-extensions"
cp -R "$EXTENSIONS/examples/search-notes" "$SMOKE/Synthetic Package"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ExtensionPanelSmoke</string>
  <key>CFBundleIdentifier</key><string>io.github.surfire.lumen.extensions-smoke</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST

xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    "$EXTENSIONS/LumenExtensionPanel.swift" "$EXTENSIONS/tests/ExtensionPanelSmoke.swift" \
    -o "$APP/Contents/MacOS/ExtensionPanelSmoke"
"$APP/Contents/MacOS/ExtensionPanelSmoke" "$SMOKE/Synthetic Package"
