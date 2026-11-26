# Lumen Engineering & Anti-Over-Defense Guidelines

This repository implements **Lumen** (`v0.3.3` -> `v0.4`), a native macOS search launcher and local file/document/multimodal index built with Rust (`src/`) and AppKit/SwiftUI (`app/`).

## 6 Anti-Over-Defense Red Lines (Mandatory)

1. **Trust standard macOS APIs; never hand-roll paranoid checks.**
   - Use `NSWorkspace.shared.icon(forFile:)` for application icons instead of manually parsing `.icns`/`.png` files inside `Resources/`.
   - Allow 1-level symlinked `.app` bundles (Homebrew Cask, Setapp, Nix, JetBrains Toolbox).
   - Do not re-stat `.app` `mtime`/`ctime` before launching an application.
   - Do not hardcode-ban `⌘Space` or other shortcuts before letting Carbon registration (`RegisterEventHotKey` / `CopySymbolicHotKeys`) test whether a shortcut is actually bound by the system.
   - Respect macOS system network proxies (`URLSessionConfiguration.default` without clearing `connectionProxyDictionary`).

2. **Guard ONLY real security/privacy boundaries; zero paranoid hot-path tax.**
   - The non-negotiable boundary is: **never materialize iCloud / OneDrive / File Provider `SF_DATALESS` cloud-only files** (`IOPOL_VFS_MATERIALIZE_DATALESS_FILES_OFF` + `SF_DATALESS` checks + `O_NOFOLLOW_ANY` + no private user file leaks).
   - Outside that boundary, NEVER add per-keystroke or per-click subprocesses (`validate-hit`), per-hit full-path `openat` walks, or fail-closed empty returns on benign concurrent writes.

3. **Converge processes; never add new child processes or bypasses.**
   - Architectural direction is fewer, persistent engines (not spawning short-lived CLIs per keystroke or click). Never introduce new bypass subprocesses, cooldown timers, or redundant JSON protocols to paper over bugs.

4. **Obey task file allowlists and Non-Goals strictly.**
   - Only edit files explicitly listed in your assigned task card.
   - Do NOT add unrequested user settings, CLI flags, environment variables, or schema migrations outside your task scope.

5. **Deletion and simplification are encouraged.**
   - Removing dead defense paths, redundant subprocess spawns, duplicate queries, and brittle workarounds is preferred over wrapping them in more guards.

6. **Real regression tests only.**
   - Every bug fix must include a regression test that fails without the fix and asserts real observable behavior. Never weaken existing assertions, add arbitrary sleeps to hide races, or mock out the unit under test.

## Verification Gates

Run all relevant checks before reporting `worker_done`:

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
scripts/build-app.sh                # pure release build (without smoke tests)
LUMEN_SMOKE=1 scripts/build-app.sh  # build with smoke tests enabled
python3 scripts/smoke-app.py
python3 scripts/smoke-launcher.py
python3 scripts/smoke-relaunch.py target/Lumen.app
python3 scripts/smoke-translation.py
```

- Keep all existing comments/docstrings unrelated to your changes intact.
- Never `git push` or touch unrelated branches (`lumen/*`).
