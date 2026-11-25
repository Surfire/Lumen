#!/usr/bin/env python3
"""Verify and install a locally built Lumen without changing application data."""

import argparse
import ctypes
import fcntl
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass


BUNDLE_ID = "io.github.surfire.lumen"
HELPERS = {
    "lumen": f"{BUNDLE_ID}.engine",
    "LumenLocalEmbedding": f"{BUNDLE_ID}.embedding",
    "LumenPdfExtractor": f"{BUNDLE_ID}.pdf",
    "LumenImageOcrExtractor": f"{BUNDLE_ID}.image-ocr",
}
DEFAULT_SOURCE = Path(__file__).resolve().parents[1] / "target/Lumen.app"
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004


class InstallError(Exception):
    pass


@dataclass(frozen=True)
class Signature:
    path: Path
    identifier: str
    cdhash: str
    requirement: str
    certificate: str


def checked(*args):
    result = subprocess.run(
        args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace"
    )
    if result.returncode:
        raise InstallError(result.stdout.strip() or f"{args[0]} exited with status {result.returncode}")
    return result.stdout


def code_layout(bundle, *, allow_missing_ocr=False):
    metadata = bundle / "Contents/Info.plist"
    executable = bundle / "Contents/MacOS/Lumen"
    resources = bundle / "Contents/Resources"
    helpers = [(resources / name, identifier) for name, identifier in HELPERS.items()
               if not (allow_missing_ocr and name == "LumenImageOcrExtractor"
                       and not os.path.lexists(resources / name))]
    for path in (bundle, bundle / "Contents", executable.parent, resources):
        if path.is_symlink() or not path.is_dir():
            raise InstallError(f"Expected a bundle directory at {path}")
    for path in [metadata, executable, *(path for path, _ in helpers)]:
        if path.is_symlink() or not path.is_file():
            raise InstallError(f"Expected a regular bundle file at {path}")
    with metadata.open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or (
        info.get("CFBundleIdentifier"), info.get("CFBundleExecutable")
    ) != (BUNDLE_ID, "Lumen"):
        raise InstallError(f"Not a Lumen bundle at {bundle}")
    return [*helpers, (bundle, BUNDLE_ID)]


def inspect_signature(path):
    with tempfile.TemporaryDirectory(prefix="lumen-certs-") as work:
        prefix = Path(work) / "certificate-"
        details = checked(
            "/usr/bin/codesign", "--display", "--verbose=4", "--requirements", "-",
            f"--extract-certificates={prefix}", path,
        )
        identifiers = re.findall(r"^Identifier=(.+)$", details, re.MULTILINE)
        cdhashes = re.findall(r"^CDHash=([0-9a-fA-F]+)$", details, re.MULTILINE)
        requirements = re.findall(r"^(?:# )?designated => (.+)$", details, re.MULTILINE)
        cert = prefix.with_name(prefix.name + "0")
        ad_hoc = "Signature=adhoc" in details.splitlines()
        if not len(identifiers) == len(cdhashes) == len(requirements) == 1 or ad_hoc == cert.is_file():
            raise InstallError(f"Cannot determine the signature identity of {path}")
        certificate = "" if ad_hoc else hashlib.sha256(cert.read_bytes()).hexdigest()
        return Signature(path, identifiers[0], cdhashes[0], requirements[0], certificate)


def verify_bundle(bundle, *, legacy_ad_hoc=False):
    # Accept signed bundles from before OCR for upgrades and backup restores.
    # A helper that is present still has to pass every verification check.
    layout = code_layout(bundle, allow_missing_ocr=True)
    checked("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", bundle)
    for path, _ in layout[:-1]:
        checked("/usr/bin/codesign", "--verify", "--strict", "--all-architectures", path)

    signatures = [inspect_signature(path) for path, _ in layout]
    outer = signatures[-1]
    for signature, (_, expected) in zip(signatures, layout):
        # Older ad-hoc Lumen builds let codesign infer the helper identifiers.
        if signature.identifier != expected and not (
            legacy_ad_hoc and not outer.certificate and expected != BUNDLE_ID
        ):
            raise InstallError(f"Unexpected code identifier for {signature.path}. Expected {expected}")
        if signature.certificate != outer.certificate:
            raise InstallError(f"Signing identity differs inside the bundle at {signature.path}")
    return signatures


def sign_build(bundle):
    identity = os.environ.get("LUMEN_SIGN_IDENTITY")
    if identity is not None and (not identity.strip() or identity == "-"):
        raise InstallError("Set LUMEN_SIGN_IDENTITY to a named code-signing identity or unset it for development.")
    keychain = os.environ.get("LUMEN_SIGN_KEYCHAIN")
    if keychain and identity is None:
        raise InstallError("A signing keychain requires LUMEN_SIGN_IDENTITY.")
    keychain_options = ["--keychain", str(Path(keychain).expanduser().absolute())] if keychain else []
    for path, identifier in code_layout(bundle):
        checked(
            "/usr/bin/codesign", "--force", "--sign", identity or "-",
            "--timestamp=none", "--identifier", identifier, *keychain_options, path,
        )
    signing = verify_bundle(bundle)
    if bool(signing[-1].certificate) != (identity is not None):
        raise InstallError("The resulting signature does not match the requested signing mode.")
    if identity is None:
        print("Ad-hoc development build. Use a reusable signing identity for installed upgrades.", file=sys.stderr)


def check_upgrade(previous, candidate, migrate_ad_hoc):
    if previous is None:
        if migrate_ad_hoc:
            raise InstallError("--migrate-ad-hoc requires an existing ad-hoc Lumen installation.")
        return
    if not previous[-1].certificate:
        if not migrate_ad_hoc:
            raise InstallError("Existing Lumen is ad hoc. Use --migrate-ad-hoc for the one-time move to a signed build.")
        print(
            "One-time signing migration. macOS may ask again for folder permissions.",
            file=sys.stderr, flush=True,
        )
        return
    if migrate_ad_hoc:
        raise InstallError("--migrate-ad-hoc cannot replace an already named-signed build.")
    # verify_bundle has already verified each candidate helper, including new ones.
    previous_by_id = {signature.identifier: signature for signature in previous}
    for new in candidate:
        old = previous_by_id.get(new.identifier)
        if old is None:
            continue
        if old.certificate != new.certificate:
            raise InstallError(f"Signing identity changed for {new.identifier}. Existing Lumen was preserved.")
        for code, requirement in ((old.path, new.requirement), (new.path, old.requirement)):
            try:
                checked("/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
                        f"-R={requirement}", code)
            except InstallError as exc:
                raise InstallError(f"Incompatible designated requirement for {new.identifier}\n{exc}") from exc


def check_not_running():
    active = checked("/usr/bin/lsappinfo", "find", f"bundleID={BUNDLE_ID}")
    if active.strip():
        raise InstallError("Lumen is running. Quit it from its menu, then run this installer again.")


def rename(source, destination, operation):
    # Atomic directory exchange or exclusive first placement on the destination volume.
    renamex = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True).renamex_np
    renamex.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    renamex.restype = ctypes.c_int
    if renamex(os.fsencode(source), os.fsencode(destination), operation):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def signature_content(signatures):
    return [(s.identifier, s.cdhash, s.certificate, s.requirement) for s in signatures]


def install(source, destination, migrate_ad_hoc):
    if os.geteuid() == 0:
        raise InstallError("Run the installer as the user who will run Lumen.")
    source = source.expanduser().absolute()
    destination = destination.expanduser().absolute()
    if destination.suffix != ".app" or destination.is_symlink():
        raise InstallError("The destination must be a regular .app path.")
    destination = destination.parent.resolve() / destination.name
    real_source = source.resolve()
    if real_source == destination or real_source in destination.parents or destination in real_source.parents:
        raise InstallError("Choose a source bundle distinct from the installation path.")

    source_signatures = verify_bundle(source)
    if not source_signatures[-1].certificate:
        raise InstallError("Ad-hoc builds are for development. Choose a bundle signed with a reusable identity.")

    check_not_running()
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock_path = destination.with_name(f".{destination.name}.install.lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, "rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return install_locked(source, source_signatures, destination, migrate_ad_hoc)


def install_locked(source, source_signatures, destination, migrate_ad_hoc):
    previous = verify_bundle(destination, legacy_ad_hoc=True) if os.path.lexists(destination) else None
    work = Path(tempfile.mkdtemp(prefix=f".{destination.stem}-backup-", dir=destination.parent))
    staged = work / destination.name
    keep = False
    try:
        checked("/usr/bin/ditto", source, staged)
        incoming = verify_bundle(staged)
        if signature_content(incoming) != signature_content(source_signatures):
            raise InstallError("The source bundle changed while copying.")
        check_upgrade(previous, incoming, migrate_ad_hoc)
        if previous and signature_content(verify_bundle(destination, legacy_ad_hoc=True)) != signature_content(previous):
            raise InstallError("The installed bundle changed during preparation.")
        check_not_running()
        # If interrupted after exchange, retain the original bundle at the printed backup path.
        if previous:
            print(f"Previous app will be saved at {staged}", flush=True)
            keep = True
        try:
            rename(staged, destination, RENAME_SWAP if previous else RENAME_EXCL)
        except OSError:
            keep = False
            raise
        try:
            if signature_content(verify_bundle(destination)) != signature_content(incoming):
                raise InstallError("The installed bundle differs from the verified copy.")
        except (InstallError, OSError, plistlib.InvalidFileException) as verification_error:
            try:
                if previous:
                    rename(staged, destination, RENAME_SWAP)
                    keep = False
                else:
                    rename(destination, staged, RENAME_EXCL)
            except OSError as rollback_error:
                recovery = f" The previous app is at {staged}." if previous else ""
                raise InstallError(f"Installation verification and rollback failed.{recovery}\n"
                                   f"{verification_error}\n{rollback_error}") from rollback_error
            message = "The previous app was restored." if previous else "The new app was removed."
            raise InstallError(f"Installation verification failed. {message}\n{verification_error}") from verification_error
        return staged if previous else None
    finally:
        if not keep:
            shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    sign_parser = subcommands.add_parser("sign-build", help="sign and verify a local build bundle")
    sign_parser.add_argument("bundle", type=Path)
    install_parser = subcommands.add_parser("install", help="install, update, or restore a signed bundle")
    install_parser.add_argument("source", type=Path, nargs="?", default=DEFAULT_SOURCE)
    install_parser.add_argument(
        "--destination", type=Path, default=Path.home() / "Applications/Lumen.app"
    )
    install_parser.add_argument("--migrate-ad-hoc", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "sign-build":
            sign_build(args.bundle.absolute())
        else:
            backup = install(args.source, args.destination, args.migrate_ad_hoc)
            print(f"Verified Lumen installed at {args.destination.expanduser().absolute()}")
            if backup is not None:
                print(f"Previous app retained at {backup}")
    except (InstallError, OSError, plistlib.InvalidFileException) as exc:
        parser.exit(1, f"Lumen packaging: {exc}\n")


if __name__ == "__main__":
    main()
