#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --locked --release "$@"
SWIFT_TARGET="$(uname -m)-apple-macosx14.0"
APP="${LUMEN_BUILD_APP_DIR:-$PWD/target/Lumen.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp target/release/lumen "$APP/Contents/Resources/lumen"
cp scripts/local-bge.py "$APP/Contents/Resources/local-bge.py"
# An incremental rebuild may still contain the retired helper.
rm -f "$APP/Contents/Resources/lumen-extensions"
iconwork="$(mktemp -d "${TMPDIR:-/tmp}/lumen-icon.XXXXXXXX")"
trap 'rm -rf "$iconwork"' EXIT
iconset="$iconwork/Lumen.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips --resampleHeightWidth "$size" "$size" app/Assets/Lumen-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    /usr/bin/sips --resampleHeightWidth "$pixels" "$pixels" app/Assets/Lumen-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns -o "$APP/Contents/Resources/Lumen.icns" "$iconset"
# macOS ships libarchive, but the SDK exposes no headers. Import only the ZIP reader ABI used by the updater.
archive_header="$iconwork/LumenArchive.h"
cat > "$archive_header" <<'HEADER'
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, unsigned long);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_extract(struct archive *, struct archive_entry *, int);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_EXTRACT_NO_OVERWRITE 0x0008
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS 0x0100
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT 0x0200
HEADER
xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" -parse-as-library \
    -import-objc-header "$archive_header" -larchive \
    app/LumenApp.swift app/LauncherUpdater.swift app/LauncherEngine.swift app/LauncherHotKey.swift app/LauncherModel.swift \
    app/WindowAccess.swift app/WindowManagement.swift \
    app/LauncherViews.swift app/LauncherHighlight.swift app/LauncherActions.swift app/LauncherSystemActions.swift app/LauncherFileQuery.swift app/LauncherPreview.swift app/LauncherShortcuts.swift app/LauncherCalculation.swift app/LauncherSmoke.swift \
    app/LumenCommandCatalog.swift app/LumenQuickAnswer.swift app/LauncherCommands.swift app/LauncherScripts.swift app/LauncherImageSearch.swift \
    app/ClipboardStore.swift app/ClipboardManager.swift app/ClipboardViews.swift \
    app/InlinePreview.swift app/MacPreview.swift app/MacInlinePreviewView.swift app/LauncherInlinePreview.swift \
    app/TranslationClient.swift app/TranslationModel.swift app/TranslationPanel.swift app/LauncherExternalVolumes.swift -o "$APP/Contents/MacOS/Lumen"
xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" app/LocalEmbedding.swift -o "$APP/Contents/Resources/LumenLocalEmbedding"
xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" app/ExtractPdf.swift -o "$APP/Contents/Resources/LumenPdfExtractor"
xcrun swiftc -O -swift-version 5 -target "$SWIFT_TARGET" -module-cache-path "$PWD/target/SwiftModuleCache" app/ExtractImageOcr.swift -o "$APP/Contents/Resources/LumenImageOcrExtractor"
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
 <key>CFBundleShortVersionString</key><string>0.4.0</string>
 <key>CFBundleVersion</key><string>20</string>
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
