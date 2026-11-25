# Lumen v0.5 Roadmap — The Last 20% to Best-in-Class macOS Launcher

v0.4 (`M1`–`M3`, `T01`–`T14`) established Lumen's core moat: native Spotlight-style UX, persistent `lumen serve` pipeline, 1M+ entry SoA Chinese/pinyin/prefix file index (<1 ms p95 hot queries, ~138 MiB RSS), iCloud/OneDrive `SF_DATALESS` non-materialization boundary, SSE streaming `tr`/`qa`, `f16` vector engine with adaptive z-score gating, and HEIC/WebP + local Apple Vision OCR.

v0.5 targets the remaining 20% across **3 Milestones (`M4`–`M6`, `T15`–`T20`)** so heavy macOS users can uninstall Spotlight and replace day-to-day Alfred/Raycast core workflows without bloating Lumen into an extension runtime.

All milestones follow [AGENTS.md](../../AGENTS.md) anti-over-defense rules and execute via **Orca** worktrees using `openai-codex` `gpt-6.2-sol` (builder) + read-only `gpt-6.2-astra` (reviewer).

---

## Non-Goals (Guardrails)

- No React/Node/Electron/third-party Raycast plugin store host in the launcher app.
- No cloud telemetry, cloud clipboard sync, or remote vector/LLM dependencies.
- Never violate `IOPOL_VFS_MATERIALIZE_DATALESS_FILES_OFF` / `SF_DATALESS` / `O_NOFOLLOW_ANY` boundaries.
- Never add per-keystroke child processes or arbitrary delays to smoke tests.

---

## Milestone 4: Visual/Highlight Polish & Local Clipboard History (`pending`)

### `T15` Native Visual Hierarchy, Match Highlighting & Motion Polish (`pending`)
- **Worktree**: `m4-visual-clipboard`
- **Scope**:
  - **Matched-substring highlighting**: Pass/compute safe Unicode-aware character/pinyin/token highlight ranges in result rows (filename, subtitle path, and snippet excerpts) using SwiftUI `AttributedString` with accent tinting, handling CJK/combining-mark boundaries accurately without allocating per-cell heavy formatters.
  - **Information hierarchy & theme polish**: Tighten typographic hierarchy across Apps / System Actions / Quicklinks / Filename hits / Body snippets / Semantic candidates, tune vibrancy (`NSVisualEffectView` `.hudWindow` / `.popover`) and light/dark contrast, and smooth panel reveal/resize transitions without triggering spurious `NSWindow.didResizeNotification` regressions in `LauncherSmoke`.
  - **Real verification**: Unit tests for Unicode/CJK/pinyin highlight span computation + snapshot visual captures (`--snapshots`) visually inspected at desktop and dark/light contrast.

### `T16` Privacy-First Local Clipboard History (`pending`)
- **Worktree**: `m4-visual-clipboard`
- **Scope**:
  - **Dedicated local store**: Separate encrypted-at-rest-or-private SQLite table / store under Application Support (`0o700` dir, `0o600` files, strictly excluded from indexer and diagnostics dumps) capturing text (bounded size) and image thumbnails/entries (bounded item count & disk budget, e.g. 200 entries / 7–30 day retention configurable in Settings).
  - **Sensitive pasteboard exclusion**: Honor macOS password manager & browser markers (`org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `com.apple.is-sensitive`), pause polling during fast-user-switching `sessionDidResignActiveNotification`, and tag internal paste writes so Lumen does not re-capture its own pastes.
  - **UX**: `cb` / `clip` verb or dedicated hotkey / context menu: fuzzy + substring search across history, instant inline preview for long text and images, `Return` copies & optionally pastes cleanly, one-click pin, Delete single item, and "Clear History".
  - **Regression tests**: Synthetic `NSPasteboard.withUniqueName()` tests verifying capture, concealed/transient skipping, bounds pruning, search, and clear without side-effecting the user's real system clipboard in tests.

---

## Milestone 5: Window Management & Lightweight Script Commands (`pending`)

### `T17` Native Accessibility Window Management (`pending`)
- **Worktree**: `m5-windows-scripts`
- **Scope**:
  - Single shared `AXWindowAccess` layer (`AXUIElementSetMessagingTimeout` per element so hung apps never stall main): act on focused/main eligible standard window (excluding sheets/popovers/fullscreen/minimized unless unminimizing on switch).
  - Core commands (bilingual CN/EN + Frecency aliases): Left Half, Right Half, Top Half, Bottom Half, Maximize, Center, Almost Maximize, Reasonable Size, Next/Previous Display (`NSScreen`), and Restore Previous Frame.
  - Explicit macOS Accessibility (`AXIsProcessTrusted`) onboarding banner + deep-link to System Settings → Privacy & Security → Accessibility when not yet granted; zero silent background prompt loops.
  - Geometry/layout planner pure Swift unit tests across multi-display/notch/`visibleFrame` coordinate conversions (`AppKit` bottom-left vs `AXUIElement` top-left).

### `T18` Local Script Commands & Apple Shortcuts (`pending`)
- **Worktree**: `m5-windows-scripts`
- **Scope**:
  - Opt-in local user scripts folder (e.g. `~/Library/Application Support/Lumen/Scripts` or user-selected folder under Settings) parsed for simple comment headers (`@lumen.title`, `@lumen.alias`, `@lumen.mode` = `compact` / `fullOutput` / `silent` / `inline`, `@lumen.argument1`), strictly non-recursive/non-symlinked regular executable files with explicit user consent on folder selection.
  - Read-only discovery of installed macOS **Apple Shortcuts** (`/usr/bin/shortcuts list`, cached on demand) launchable directly from Lumen search (`Return` runs with bounded timeout / background feedback).
  - Bounded process execution (timeout, truncated output card, Esc cancellation) reusing existing command card UI.
  - Security & regression tests: symlink rejection, header parser fuzz/edge cases, bounded output & timeout kill verification.

---

## Milestone 6: Static Core Engine & Zero-Friction Distribution (`pending`)

### `T19` Static `liblumen.a` In-Process Core Search (`pending`)
- **Worktree**: `m6-static-engine`
- **Scope**:
  - Expose a minimal C-ABI static library target (`liblumen.a` + `include/lumen_core.h`) for hot in-process Read/Name-SoA/FTS queries and cached hit validation directly inside `Lumen.app`, cutting idle RSS below ~100 MiB and eliminating pipe serialization overhead for the keystroke hot path while preserving `lumen` CLI binary for scripting and `tests/cli.rs`.
  - Keep heavy/untrusted extractors and native runtimes (`LumenPdfExtractor`, `LumenImageOcrExtractor`, `llama-server`) isolated in on-demand, timeout-guarded child processes so crashes or OOM in extractors/models can never take down the launcher UI.
  - Maintain full ABI/memory-safety verification (`cargo test`, ASan/leak smoke check across repeated open/search/close cycles).

### `T20` Signed In-App Updater & Homebrew Cask Distribution (`pending`)
- **Worktree**: `m6-release-updater`
- **Scope**:
  - In-app lightweight update checker (opt-in / manual + quiet periodic HTTPS check against signed GitHub Releases manifest, zero third-party frameworks) verified with SHA-256 + Apple Designated Requirement (`SecStaticCodeCheckValidity` against the running app's DR before touching the installed bundle).
  - Atomic bundle swap (`renamex_np` `RENAME_SWAP` + backup + automatic rollback on post-swap verification failure), reusing and converging with [scripts/install-app.py](../../scripts/install-app.py).
  - Add release packaging script + Homebrew Cask template (`Formula` / `Casks/lumen.rb`) and end-to-end local HTTP mock update/rollback smoke suite.
