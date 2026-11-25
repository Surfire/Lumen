#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --locked --release "$@"
APP="$PWD/target/Lumen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp target/release/lumen "$APP/Contents/Resources/lumen"
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/target/SwiftModuleCache" -parse-as-library app/LumenApp.swift -o "$APP/Contents/MacOS/Lumen"
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/target/SwiftModuleCache" app/LocalEmbedding.swift -o "$APP/Contents/Resources/LumenLocalEmbedding"
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/target/SwiftModuleCache" app/ExtractPdf.swift -o "$APP/Contents/Resources/LumenPdfExtractor"
codesign --force --sign - "$APP/Contents/Resources/LumenPdfExtractor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
 <key>CFBundleExecutable</key><string>Lumen</string>
 <key>CFBundleIdentifier</key><string>io.github.surfire.lumen</string>
 <key>CFBundleName</key><string>Lumen</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>0.1.0</string>
 <key>CFBundleVersion</key><string>1</string>
 <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/Resources/lumen"
codesign --force --sign - "$APP/Contents/Resources/LumenLocalEmbedding"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
