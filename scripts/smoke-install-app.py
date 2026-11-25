#!/usr/bin/env python3
"""Exercise the installer with generated apps and certificates in one temporary directory."""

from contextlib import redirect_stderr
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from unittest import mock


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install-app.py"))
installer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = installer
spec.loader.exec_module(installer)


def command(*args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, timeout=25, check=False)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed\n{result.stderr.decode(errors='replace')}")
    return result.stdout


def keychain_settings():
    return tuple(
        command("/usr/bin/security", operation, "-d", "user")
        for operation in ("list-keychains", "default-keychain")
    )


def create_keychain(work, expected_settings):
    keychain = work / "temporary-packaging-test.keychain"
    password = "temporary synthetic keychain"
    command("/usr/bin/security", "create-keychain", "-p", password, keychain)
    assert keychain_settings() == expected_settings
    command("/usr/bin/security", "unlock-keychain", "-p", password, keychain)
    return keychain, password


def test_identity(work, keychain, tag):
    private_key, certificate, archive = [work / f"identity-{tag}.{ext}" for ext in ("key", "crt", "p12")]
    command(
        "/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-days", "2", "-keyout", private_key, "-out", certificate,
        "-subj", "/CN=Lumen Temporary Packaging Test",
        "-addext", "keyUsage=critical,digitalSignature", "-addext", "extendedKeyUsage=codeSigning",
    )
    command(
        "/usr/bin/openssl", "pkcs12", "-export", "-inkey", private_key, "-in", certificate,
        "-out", archive, "-passout", "pass:temporary",
    )
    command(
        "/usr/bin/security", "import", archive, "-k", keychain, "-P", "temporary", "-T", "/usr/bin/codesign",
    )
    der = command("/usr/bin/openssl", "x509", "-in", certificate, "-outform", "der")
    return hashlib.sha1(der).hexdigest()


def bundle(work, version, identity=None, keychain=None):
    app = work / f"Build {version}.app"
    executable = app / "Contents/MacOS/Lumen"
    resources = app / "Contents/Resources"
    executable.parent.mkdir(parents=True)
    resources.mkdir()
    command("/usr/bin/xcrun", "clang", "-x", "c", "-", "-o", executable,
            data=f"int main(void) {{return {version};}}\n".encode())
    for helper in installer.HELPERS:
        shutil.copy2(executable, resources / helper)
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleIdentifier": installer.BUNDLE_ID,
            "CFBundleExecutable": "Lumen",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": str(version),
        }, file)
    with mock.patch.dict(os.environ):
        os.environ.pop("LUMEN_SIGN_IDENTITY", None)
        os.environ.pop("LUMEN_SIGN_KEYCHAIN", None)
        if identity:
            os.environ["LUMEN_SIGN_IDENTITY"] = identity
            os.environ["LUMEN_SIGN_KEYCHAIN"] = str(keychain)
        installer.sign_build(app)
    return app


def build_version(app):
    with (app / "Contents/Info.plist").open("rb") as file:
        return plistlib.load(file)["CFBundleVersion"]


def rejects(action, text):
    try:
        action()
    except installer.InstallError as error:
        assert text in str(error), f"Expected {text!r} in {error!r}"
    else:
        raise AssertionError(f"Expected rejection mentioning {text}")


def exercise(work, settings):
    keychain, password = create_keychain(work, settings)
    identity_a = test_identity(work, keychain, "a")
    identity_b = test_identity(work, keychain, "b")
    command(
        "/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain
    )
    development = bundle(work, 1)
    first = bundle(work, 2, identity_a, keychain)
    upgrade = bundle(work, 3, identity_a, keychain)
    mismatch = bundle(work, 4, identity_b, keychain)
    restricted = work / "Restricted Build.app"
    command("/usr/bin/ditto", upgrade, restricted)
    requirement = f'designated => identifier "{installer.BUNDLE_ID}" and info[CFBundleVersion] = "3"'
    command("/usr/bin/codesign", "--force", "--sign", identity_a, "--keychain", keychain,
            "--timestamp=none", "--identifier", installer.BUNDLE_ID, f"-r={requirement}", restricted)
    assert keychain_settings() == settings

    index = work / "Library/Application Support/Lumen/index.sqlite"
    index.parent.mkdir(parents=True)
    index.write_bytes(b"synthetic index sentinel")
    destination = work / "Applications/Lumen.app"

    # Simulate Launch Services in isolated transactions. No installer test opens an app.
    def install(source, migrate=False):
        with mock.patch.object(installer, "check_not_running"):
            return installer.install(source, destination, migrate)

    rejects(lambda: install(development), "Ad-hoc builds are for development")
    assert not destination.parent.exists()
    with mock.patch.object(installer, "check_not_running",
                           side_effect=installer.InstallError("Lumen is running")):
        rejects(lambda: installer.install(first, destination, False), "Lumen is running")
    assert not destination.parent.exists()

    assert install(first) is None
    assert build_version(destination) == "2"
    assert installer.verify_bundle(destination)[-1].certificate
    rejects(lambda: install(mismatch), "Signing identity changed")
    rejects(lambda: install(restricted), "Incompatible designated requirement")
    rejects(lambda: install(upgrade, migrate=True), "cannot replace an already named-signed build")
    assert build_version(destination) == "2"

    backup = install(upgrade)
    assert build_version(destination) == "3" and build_version(backup) == "2"
    previous_new = install(backup)
    assert build_version(destination) == "2" and build_version(previous_new) == "3"

    real_verify = installer.verify_bundle

    def fail_post_swap(app, **options):
        if app == destination and build_version(app) == "3":
            raise installer.InstallError("synthetic post-swap verification failure")
        return real_verify(app, **options)

    with mock.patch.object(installer, "verify_bundle", side_effect=fail_post_swap):
        rejects(lambda: install(upgrade), "post-swap verification failure")
    assert build_version(destination) == "2"

    legacy = work / "Test migration/Lumen.app"
    legacy.parent.mkdir()
    command("/usr/bin/ditto", development, legacy)
    with mock.patch.object(installer, "check_not_running"):
        rejects(lambda: installer.install(first, legacy, False), "Existing Lumen is ad hoc")
        diagnostics = io.StringIO()
        with redirect_stderr(diagnostics):
            archive = installer.install(first, legacy, True)
        assert "macOS may ask again" in diagnostics.getvalue()
    assert build_version(legacy) == "2" and build_version(archive) == "1"
    assert index.read_bytes() == b"synthetic index sentinel"


if __name__ == "__main__":
    settings = keychain_settings()
    try:
        with tempfile.TemporaryDirectory(prefix="lumen-upgrade-smoke-") as directory:
            exercise(Path(directory).resolve(), settings)
    finally:
        assert keychain_settings() == settings, "Keychain settings changed"
    print("PASS: real test signatures, same-identity upgrade and rollback, identity rejection, ad-hoc migration, active-app refusal, data preservation")
