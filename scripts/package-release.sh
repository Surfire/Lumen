#!/bin/sh
# Package a clean, named-signed macOS build and its authenticated update feed.
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: LUMEN_SIGN_IDENTITY=... LUMEN_MANIFEST_KEY=... $0 OUTPUT_DIRECTORY RELEASE_NOTES.txt" >&2
    exit 2
fi
: "${LUMEN_SIGN_IDENTITY:?Set LUMEN_SIGN_IDENTITY to the release signing identity}"
: "${LUMEN_MANIFEST_KEY:?Set LUMEN_MANIFEST_KEY to the PEM private key of the app signing identity}"
mkdir -p "$1"
out=$(cd "$1" && pwd -P)
absolute_path() { /usr/bin/python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve(strict=True))' "$1"; }
notes=$(absolute_path "$2")
key=$(absolute_path "$LUMEN_MANIFEST_KEY")
cd "$(dirname "$0")/.."
[ "$(uname -m)" = arm64 ] || { echo "Package releases on Apple Silicon." >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/lumen-release.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
app="$work/Lumen.app"
LUMEN_SMOKE=0 LUMEN_BUILD_APP_DIR="$app" scripts/build-app.sh

# Notarize public Developer ID releases before computing the published digest.
if [ -n "${LUMEN_NOTARY_PROFILE:-}" ]; then
    /usr/bin/python3 - "$app" <<'PY'
import os
from pathlib import Path
import runpy
import sys

installer = runpy.run_path('scripts/install-app.py')
keychain = os.environ.get('LUMEN_SIGN_KEYCHAIN')
options = ['--keychain', str(Path(keychain).expanduser().resolve())] if keychain else []
app = Path(sys.argv[1])
for path, _ in installer['code_layout'](app):
    installer['checked']('/usr/bin/codesign', '--force', '--sign', os.environ['LUMEN_SIGN_IDENTITY'],
                         '--options', 'runtime', '--timestamp', '--preserve-metadata=identifier', *options, path)
installer['verify_bundle'](app)
PY
    /usr/bin/ditto -c -k --keepParent "$app" "$work/notarize.zip"
    xcrun notarytool submit "$work/notarize.zip" --keychain-profile "$LUMEN_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
fi

/usr/bin/python3 - "$work" "$notes" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import zipfile

work, notes = map(Path, sys.argv[1:])
app = work / 'Lumen.app'
archive = work / 'Lumen-macos-arm64.zip'
with zipfile.ZipFile(archive, 'w') as zip:
    # Fixed timestamps, sorted UTF-8 paths, no host xattrs; preserve modes and symlinks.
    for path in [app, *sorted(app.rglob('*'))]:
        mode = path.lstat().st_mode
        entry = zipfile.ZipInfo(path.relative_to(work).as_posix() + ('/' if stat.S_ISDIR(mode) else ''))
        entry.create_system = 3  # UNIX
        entry.external_attr = mode << 16
        if stat.S_ISLNK(mode):
            zip.writestr(entry, os.fsencode(os.readlink(path)))
        elif stat.S_ISDIR(mode):
            zip.writestr(entry, b'')
        else:
            entry.compress_type = zipfile.ZIP_DEFLATED
            with path.open('rb') as source, zip.open(entry, 'w') as target:
                shutil.copyfileobj(source, target)
with archive.open('rb') as stream:
    hash = hashlib.sha256()
    for block in iter(lambda: stream.read(1 << 20), b''):
        hash.update(block)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
manifest = dict(version=version, build=build, sha256=hash.hexdigest(),
                url=f'https://github.com/Surfire/Lumen/releases/download/v{version}/{archive.name}',
                notes=notes.read_text(encoding='utf-8').strip())
(work / 'lumen-update.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(f'{archive.name} SHA-256: {manifest["sha256"]}')
PY

# OpenSSL rejects keys that do not match the leaf certificate of the actual signed bundle.
/usr/bin/codesign -d --extract-certificates="$work/cert-" "$app"
/usr/bin/openssl x509 -inform DER -in "$work/cert-0" -out "$work/leaf.pem"
/usr/bin/openssl cms -sign -binary -nodetach -md sha256 -outform DER \
    -signer "$work/leaf.pem" -inkey "$key" -in "$work/lumen-update.json" -out "$work/lumen-update.json.cms"
for asset in Lumen-macos-arm64.zip lumen-update.json lumen-update.json.cms; do
    mv -f "$work/$asset" "$out/$asset"
done
printf 'Release assets: %s\n' "$out"
