#!/usr/bin/env python3
"""Run the real updater against a loopback-only signed release, with isolated app copies."""

from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from threading import Thread
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).with_name('smoke-install-app.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
command = fixtures.command
BUILT = Path(__file__).resolve().parents[1] / 'target/Lumen.app'


def info(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())


def build_copy(app, version, build, signer, keychain):
    command('/usr/bin/ditto', BUILT, app)
    metadata = app / 'Contents/Info.plist'
    plist = info(app)
    plist.update(CFBundleVersion=build, CFBundleShortVersionString=version)
    metadata.write_bytes(plistlib.dumps(plist))
    with patch.dict(os.environ, LUMEN_SIGN_IDENTITY=signer, LUMEN_SIGN_KEYCHAIN=str(keychain)):
        fixtures.installer.sign_build(app)
    return app


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/redirect.zip':
            self.send_response(302)
            self.send_header('Location', '/upgrade.zip')
            self.end_headers()
        elif self.path == '/outside.zip':
            self.send_response(302)
            self.send_header('Location', 'http://example.invalid/upgrade.zip')
            self.end_headers()
        else:
            super().do_GET()


def exercise(work, keychain, password):
    a, b = (fixtures.test_identity(work, keychain, tag) for tag in ('a', 'b'))
    command('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, keychain)
    baseline = build_copy(work / 'base/Lumen.app', '0.4.0', '20', a, keychain)
    public = work / 'public'
    public.mkdir()
    for name, signer in [('upgrade', a), ('other', b)]:
        source = build_copy(work / name / 'Lumen.app', '0.5.0', '21', signer, keychain)
        with zipfile.ZipFile(public / f'{name}.zip', 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in [source, *sorted(source.rglob('*'))]:
                archive.write(path, path.relative_to(source.parent))

    with ThreadingHTTPServer(('127.0.0.1', 0), partial(Handler, directory=str(public))) as server:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        digest = lambda filename: hashlib.sha256((public / filename).read_bytes()).hexdigest()

        def manifest(name, url, sha256, signer='a', build='21'):
            payload = dict(version='0.5.0', build=build, url=f'{base}/{url}', sha256=sha256, notes='Synthetic release')
            command('/usr/bin/openssl', 'cms', '-sign', '-binary', '-nodetach', '-md', 'sha256', '-outform', 'DER',
                    '-signer', work / f'identity-{signer}.crt', '-inkey', work / f'identity-{signer}.key',
                    '-out', public / f'{name}.cms', data=json.dumps(payload).encode())

        sha = digest('upgrade.zip')
        manifest('good', 'redirect.zip', sha)
        manifest('bad-digest', 'upgrade.zip', '0' * 64)
        manifest('bad-app-signer', 'other.zip', digest('other.zip'))
        manifest('bad-feed-signer', 'upgrade.zip', sha, signer='b')
        manifest('bad-version', 'upgrade.zip', sha, build='22')
        manifest('bad-redirect', 'outside.zip', sha)
        tampered = (public / 'good.cms').read_bytes().replace(b'Synthetic release', b'Synthetic Release')
        (public / 'tampered.cms').write_bytes(tampered)

        def run(app, name, *options, host=base):
            result = subprocess.run([app / 'Contents/MacOS/Lumen', '--updater-smoke', f'{host}/{name}.cms', *options],
                                    text=True, capture_output=True, timeout=30)
            return result.returncode, result.stdout + result.stderr

        def transaction(case, expected, *options):
            app = work / case / 'Applications/Lumen.app'
            command('/usr/bin/ditto', baseline, app)
            inode = app.stat().st_ino
            result, output = run(app, 'good' if case.startswith('good') else case, *options)
            assert expected in output, (case, result, output)
            backups = list(app.parent.glob('.Lumen-backup-*'))
            if case in ('good', 'good-relaunch'):
                assert result == 0 and info(app)['CFBundleVersion'] == '21', output
                [backup] = backups
                previous = backup / 'Lumen.app'
                assert previous.stat().st_ino == inode and info(previous) == info(baseline)
                fixtures.installer.verify_bundle(previous)
                assert run(app, 'good', host=base.replace('127.0.0.1', 'localhost')) == (0, 'No newer release\n')
            else:
                assert result == 1 and app.stat().st_ino == inode and info(app) == info(baseline), output
                assert not backups, backups
            fixtures.installer.verify_bundle(app)
            print(f'PASS: {case} — {expected}')

        try:
            transaction('good', 'Installed 0.5.0 (build 21)')
            transaction('good-relaunch', 'relaunched:', 'relaunch-hook')
            transaction('bad-digest', 'SHA-256 does not match')
            transaction('bad-app-signer', "does not satisfy this installation's signing requirement")
            transaction('bad-feed-signer', "manifest's signature does not match")
            transaction('tampered', "manifest's signature does not match")
            transaction('bad-version', 'signed app version does not match')
            transaction('bad-redirect', 'server did not return a download')
            transaction('good-rollback', 'previous app was restored. Simulated post-swap failure', 'fail-after-swap')
        finally:
            server.shutdown()
            thread.join()


if __name__ == '__main__':
    settings = fixtures.keychain_settings()
    with tempfile.TemporaryDirectory(prefix='lumen-updater-smoke-') as directory:
        work = Path(directory).resolve()
        keychain, password = fixtures.create_keychain(work, settings)
        try:
            exercise(work, keychain, password)
        finally:
            command('/usr/bin/security', 'delete-keychain', keychain)
            assert fixtures.keychain_settings() == settings, 'Default keychain or search list changed'
