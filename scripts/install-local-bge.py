"""Install explicit, already-local BGE assets into an isolated per-user directory."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

WORKER = Path(__file__).resolve().with_name("local-bge.py")
DEFAULT_ROOT = Path.home() / "Library/Application Support/Lumen/Semantic"
DEPENDENCIES = (
    "torch==2.12.0", "transformers==4.57.3",
    "tokenizers==0.22.2", "safetensors==0.7.0",
)


def verify(python, directory, language):
    output = subprocess.check_output(
        [python, "-I", WORKER, "--model-dir", directory, "--language", language],
        input=b"", timeout=30,
    )
    ready = json.loads(output)
    if ready["protocol"] != 1 or ready["language"] != language:
        raise RuntimeError(f"unexpected worker status for {language}")


def install(args, chosen):
    destination = args.destination.expanduser().resolve()
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    runtime = destination / "runtime"
    models = destination / "models"
    models.mkdir(mode=0o700, exist_ok=True)
    with (destination / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix=".install-", dir=destination) as stage:
            staging = Path(stage)
            new_runtime = not (runtime.exists() or runtime.is_symlink())
            if new_runtime:
                staged_runtime = staging / "runtime"
                subprocess.run(
                    ["uv", "--no-config", "venv", "--offline", "--no-project",
                     "--no-python-downloads", "--relocatable", "--python", args.python, staged_runtime],
                    check=True,
                )
                python = staged_runtime / "bin/python3"
                subprocess.run(
                    ["uv", "--no-config", "pip", "install", "--offline", "--only-binary", ":all:",
                     "--python", python, *DEPENDENCIES],
                    check=True,
                )
            else:
                python = runtime / "bin/python3"
            definitions = runpy.run_path(str(WORKER))
            staged_profiles = []
            for language, source in chosen.items():
                target = models / language
                if target.exists() or target.is_symlink():
                    verify(python, target, language)
                    continue
                profile = staging / language
                profile.mkdir()
                for name, expected in definitions["PROFILES"][language]["assets"].items():
                    (profile / name).write_bytes(definitions["read_asset"](source, name, expected))
                verify(python, profile, language)
                staged_profiles.append((profile, target))
            if new_runtime:
                staged_runtime.rename(runtime)
            for profile, target in staged_profiles:
                profile.rename(target)
        for language in chosen:
            verify(runtime / "bin/python3", models / language, language)
    print(json.dumps({"installed_profiles": list(chosen)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--python", default="3.12", help="existing local CPython path or version")
    parser.add_argument("--zh-model", type=Path, help="directory containing the pinned Chinese snapshot")
    parser.add_argument("--en-model", type=Path, help="directory containing the pinned English snapshot")
    args = parser.parse_args()
    chosen = {language: source for language, source in
              (("zh", args.zh_model), ("en", args.en_model)) if source is not None}
    if not chosen:
        parser.error("supply --zh-model or --en-model")
    os.umask(0o077)
    install(args, chosen)


if __name__ == "__main__":
    main()
