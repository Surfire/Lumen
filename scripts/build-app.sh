#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
SWIFT_TARGET="$(uname -m)-apple-macosx14.0"
# Match the bundled SQLite C object to the app without changing Rust host proc-macro builds.
RUST_TARGET="$(rustc --print host-tuple)"
C_FLAGS="$(printenv "CFLAGS_$RUST_TARGET" || printenv "CFLAGS_$(printf '%s' "$RUST_TARGET" | tr '-' '_')" || :)"
env "CFLAGS_$RUST_TARGET=$C_FLAGS -mmacosx-version-min=14.0" cargo build --locked --release "$@"
APP="${LUMEN_BUILD_APP_DIR:-$PWD/target/Lumen.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp target/release/lumen "$APP/Contents/Resources/lumen"
# An incremental rebuild may still contain retired helpers.
rm -f "$APP/Contents/Resources/lumen-extensions" "$APP/Contents/Resources/LumenLocalEmbedding" "$APP/Contents/Resources/local-bge.py"
if [ ! -f "$APP/Contents/Resources/gemma-assets.json" ] || [ scripts/gemma-assets.json -nt "$APP/Contents/Resources/gemma-assets.json" ]; then
    cp scripts/gemma-assets.json "$APP/Contents/Resources/gemma-assets.json"
fi
if [ ! -f "$APP/Contents/Resources/Lumen.icns" ] || [ app/Assets/Lumen-1024.png -nt "$APP/Contents/Resources/Lumen.icns" ]; then
    iconwork="$(mktemp -d "${TMPDIR:-/tmp}/lumen-icon.XXXXXXXX")"
    iconset="$iconwork/Lumen.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        /usr/bin/sips --resampleHeightWidth "$size" "$size" app/Assets/Lumen-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        pixels=$((size * 2))
        /usr/bin/sips --resampleHeightWidth "$pixels" "$pixels" app/Assets/Lumen-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    /usr/bin/iconutil -c icns -o "$APP/Contents/Resources/Lumen.icns" "$iconset"
    rm -rf "$iconwork"
fi
SMOKE_FLAG=
SMOKE_SOURCE=
if [ "${LUMEN_SMOKE:-0}" = "1" ]; then
    SMOKE_FLAG=-DLUMEN_SMOKE
    SMOKE_SOURCE=app/LauncherSmoke.swift
fi
# The archive supplies SQLite for Rust and Swift's SQLite3 calls. Strip unused
# archive code and dylibs (including the SQLite3 module's system autolink).
xcrun swiftc -O -j "$(sysctl -n hw.ncpu)" -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" -parse-as-library \
    -import-objc-header include/lumen_core.h target/release/liblumen.a -larchive \
    -Xlinker -dead_strip -Xlinker -dead_strip_dylibs \
    -framework DiskArbitration -framework IOKit \
    $SMOKE_FLAG \
    app/LumenApp.swift app/LauncherUpdater.swift app/LauncherEngine.swift app/LauncherHotKey.swift app/LauncherModel.swift \
    app/WindowAccess.swift app/WindowManagement.swift \
    app/LauncherViews.swift app/LauncherSettingsViews.swift app/LauncherHighlight.swift app/LauncherActions.swift app/LauncherSystemActions.swift app/LauncherFileQuery.swift app/LauncherPreview.swift app/LauncherShortcuts.swift app/LauncherCalculation.swift $SMOKE_SOURCE \
    app/LumenCommandCatalog.swift app/LumenQuickAnswer.swift app/LauncherCommands.swift app/LauncherScripts.swift app/LauncherImageSearch.swift \
    app/ClipboardStore.swift app/ClipboardManager.swift app/ClipboardViews.swift \
    app/InlinePreview.swift app/MacPreview.swift app/MacInlinePreviewView.swift app/LauncherInlinePreview.swift \
    app/TranslationClient.swift app/TranslationModel.swift app/TranslationPanel.swift app/LauncherExternalVolumes.swift app/GemmaAssetManager.swift -o "$APP/Contents/MacOS/Lumen"
if [ ! -x "$APP/Contents/Resources/LumenPdfExtractor" ] || [ app/ExtractPdf.swift -nt "$APP/Contents/Resources/LumenPdfExtractor" ]; then
    xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" app/ExtractPdf.swift -o "$APP/Contents/Resources/LumenPdfExtractor"
fi
if [ ! -x "$APP/Contents/Resources/LumenImageOcrExtractor" ] || [ app/ExtractImageOcr.swift -nt "$APP/Contents/Resources/LumenImageOcrExtractor" ]; then
    xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" app/ExtractImageOcr.swift -o "$APP/Contents/Resources/LumenImageOcrExtractor"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
 <key>CFBundleExecutable</key><string>Lumen</string>
 <key>CFBundleIdentifier</key><string>io.github.surfire.lumen</string>
 <key>CFBundleName</key><string>Lumen</string>
 <key>CFBundleIconFile</key><string>Lumen.icns</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>0.5.4</string>
 <key>CFBundleVersion</key><string>36</string>
 <key>LSMinimumSystemVersion</key><string>14.0</string>
 <key>LSUIElement</key><true/>
 <key>NSAppleEventsUsageDescription</key><string>Lumen uses macOS automation only when you run a system action such as Empty Trash or Toggle Dark Mode.</string>
 <key>NSAppTransportSecurity</key>
 <dict>
  <key>NSExceptionDomains</key>
  <dict>
   <key>127.0.0.1</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
   <key>localhost</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
   <key>::1</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
  </dict>
 </dict>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
/usr/bin/python3 scripts/install-app.py sign-build "$APP"
printf '%s\n' "$APP"
