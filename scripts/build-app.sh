#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --locked --release "$@"
cargo build --manifest-path extensions/Cargo.toml --locked --release "$@"
SWIFT_TARGET="$(uname -m)-apple-macosx14.0"
APP="$PWD/target/Lumen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp target/release/lumen "$APP/Contents/Resources/lumen"
cp scripts/local-bge.py "$APP/Contents/Resources/local-bge.py"
cp extensions/target/release/lumen-extensions "$APP/Contents/Resources/lumen-extensions"
xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" -parse-as-library -D LUMEN_EXTENSIONS \
    app/LumenApp.swift app/LauncherEngine.swift app/LauncherHotKey.swift app/LauncherModel.swift \
    app/LauncherViews.swift app/LauncherSmoke.swift extensions/LumenExtensionPanel.swift -o "$APP/Contents/MacOS/Lumen"
xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" app/LocalEmbedding.swift -o "$APP/Contents/Resources/LumenLocalEmbedding"
xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" app/ExtractPdf.swift -o "$APP/Contents/Resources/LumenPdfExtractor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
 <key>CFBundleExecutable</key><string>Lumen</string>
 <key>CFBundleIdentifier</key><string>io.github.surfire.lumen</string>
 <key>CFBundleName</key><string>Lumen</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>0.2.4</string>
 <key>CFBundleVersion</key><string>6</string>
 <key>LSMinimumSystemVersion</key><string>14.0</string>
 <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
/usr/bin/python3 scripts/install-app.py sign-build "$APP"
printf '%s\n' "$APP"
