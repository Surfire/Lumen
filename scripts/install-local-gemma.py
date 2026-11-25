#!/usr/bin/env python3
"""Install verified local EmbeddingGemma 2 inputs into a private resource directory."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import tarfile
import tempfile


def copy_verified(source, destination, expected):
    digest = hashlib.sha256()
    remaining = expected['size']
    with destination.open('xb') as output:
        while remaining:
            block = source.read(min(remaining, 1024 * 1024))
            if not block:
                raise ValueError(f'truncated input for {destination.name}')
            output.write(block)
            digest.update(block)
            remaining -= len(block)
    if source.read(1) or digest.hexdigest() != expected['sha256']:
        raise ValueError(f'unexpected size or SHA-256 for {destination.name}')


def install_exclusively(source, destination):
    # Darwin's RENAME_EXCL prevents even a concurrently created empty directory
    # from being replaced while the install is being verified.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Library/Application Support/Lumen/Gemma2')
    args = parser.parse_args()
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        parser.error('this runtime requires Apple Silicon macOS')
    manifest = json.loads(Path(__file__).with_name('gemma-assets.json').read_text())
    destination = args.destination.absolute()
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.path.lexists(destination):
        parser.error('the destination already exists, choose a new private directory')
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.lumen-gemma-') as staging:
        staging = Path(staging)
        assets = staging / 'assets'
        runtime = assets / 'runtime'
        assets.mkdir(mode=0o700)
        runtime.mkdir(mode=0o700)
        with args.model.open('rb') as source:
            copy_verified(source, assets / manifest['model']['name'], manifest['model'])
        verified_archive = staging / 'runtime.tar.gz'
        with args.archive.open('rb') as source:
            copy_verified(source, verified_archive, manifest['archive'])
        with tarfile.open(verified_archive, 'r:gz') as archive:
            for name, spec in manifest['runtime'].items():
                member = archive.getmember(f"{manifest['archive']['directory']}/{spec['member']}")
                if not member.isfile() or member.size != spec['size']:
                    raise ValueError(f'invalid archive member for {name}')
                with archive.extractfile(member) as source:
                    copy_verified(source, runtime / name, spec)
        (runtime / 'llama-server').chmod(0o700)
        for item in runtime.iterdir():
            if item.name != 'llama-server':
                item.chmod(0o400)
        (assets / manifest['model']['name']).chmod(0o400)
        # The parent is user-selected and the staging directory is on the same volume.
        install_exclusively(assets, destination)
    print(json.dumps({'backend': 'gemma_candidate', 'destination': str(destination)}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        raise SystemExit(str(error)) from None
