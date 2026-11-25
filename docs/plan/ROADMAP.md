# Lumen v0.4 Spotlight Parity Roadmap

Status legend: `pending` | `in_progress` | `done`

---

## Milestone 1: P0 Stop-the-Bleeding (`done`)

### `T01` Hotkey & Search Panel Behavior (`done`)
- **Worktree**: `m1-panel-ime`
- **Allowed files**: `app/LauncherHotKey.swift`, `app/LumenApp.swift`, `app/LauncherViews.swift`, `app/MacInlinePreviewView.swift`, `app/LauncherInlinePreview.swift`
- **Scope**:
  - Remove hardcoded bans on `⌘Space`, `⌘⌥Space`, `⌘⇧Space`, `⌃Space`, `⌃⌥Space` in `LauncherHotKey.swift` (keep `⌘,` conflict check and `CopySymbolicHotKeys` / Carbon registration check).
  - Toggle search panel on repeat hotkey press (`if searchPresented && panel.isKeyWindow { dismissSearch() } else { showSearch() }`).
  - Add `.nonactivatingPanel` to `SearchPanel` with `[.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`.
  - Position panel in the upper-third of the mouse-active screen (`NSScreen`), keeping the top edge anchored when height changes.
- **Non-Goals**: No Rust changes; no edits to `LauncherEngine.swift`, `LauncherModel.swift`, or `LauncherActions.swift`.

### `T02` IME Guard, Preview Session & PDF Open (`done`)
- **Worktree**: `m1-panel-ime`
- **Allowed files**: same as `T01`
- **Scope**:
  - Guard `controlTextDidChange` / `searchFieldAction()` with `!hasMarkedText()` so Chinese Pinyin IME composition never fires live searches or command card switches mid-composition.
  - Keep search session alive when `LocalPreviewPanel` becomes key (`windowDidResignKey` must not dismiss/clear when preview opens).
  - Allow explicit Open (`↵` / `⌘K → Open`) on PDF hits to open in the user's default PDF app instead of hijacking to the read-only preview panel (`⌘Y` / explicit Preview still opens preview).
  - Call `updatePresentation()` when closing inline preview; cache decoded preview `NSImage` off SwiftUI `body`; eliminate single-click row selection delay caused by stacked tap gestures.
- **Non-Goals**: Same as `T01`.

### `T03` App Search Icons, Symlinks, Fuzzy Match & Frecency (`done`)
- **Worktree**: `m1-apps-concurrency`
- **Allowed files**: `app/LauncherActions.swift`, `app/LauncherEngine.swift`, `app/LauncherModel.swift`, `app/LauncherShortcuts.swift`, `app/TranslationClient.swift`, `app/TranslationModel.swift`, `app/TranslationPanel.swift`
- **Scope**:
  - Use `NSWorkspace.shared.icon(forFile:)` with bounded cache for app icons.
  - Allow 1-level symlinked `.app` bundles in `discoverApplications` while preserving cloud dataless safety.
  - Support 1-char prefix and subsequence fuzzy matching (`"vsc"` -> Visual Studio Code, `"s"` -> Safari) in `LaunchCatalog.matches`.
  - Add lightweight persistent Frecency ranking for apps and files; remove synchronous pre-launch `mtime/ctime` check on `.app` bundles.
- **Non-Goals**: No Rust changes; no edits to `LumenApp.swift`, `LauncherViews.swift`, or `LauncherHotKey.swift`.

### `T04` Swift Concurrency, `serve` Timeout, Error Visibility & Proxy Fix (`done`)
- **Worktree**: `m1-apps-concurrency`
- **Allowed files**: same as `T03`
- **Scope**:
  - Move blocking pipe/stderr `availableData` reads out of Swift Concurrency `Task.detached` onto dedicated `DispatchQueue`s or `readabilityHandler`.
  - Add active per-request timeout on `lumen serve` independent of `idleTimeout == nil`.
  - Fix silently swallowed name-search errors when `text` is `.success([])`.
  - Track/cancel `img` `validate-hit` subprocesses and synchronize `confirmed` Set updates on `MainActor`.
  - Fix startup race where `watch --cached-start` starts before `status` fails.
  - Remove `connectionProxyDictionary = [:]` in `TranslationClient.swift`, accept `"length"` / `"end_turn"` finish reasons, support `"translate <text>"` / `"翻译 <text>"`, and allow deleting saved translation providers in Settings.
- **Non-Goals**: Same as `T03`.

### `T05` Rust Hot-Path & Correctness Fixes (`done`)
- **Worktree**: `m1-rust-hotpath`
- **Allowed files**: `src/lib.rs`, `src/index.rs`, `src/name_fast.rs`, `src/query.rs`, `src/content.rs`, `src/watch.rs`, `src/watch/resume.rs`, `src/image_search.rs`, `src/diagnose.rs`, `src/platform.rs`, `src/main.rs`, `tests/cli.rs`
- **Scope**:
  - In `open_write()`, only run `PRAGMA application_id` / `user_version` / DDL when schema is uninitialized/migrating; track `name_generation` in `info` incremented only when `item` changes, and key `NameFast` invalidation on `name_generation` instead of DB-wide `data_version`. Add exponential/long backoff on over-budget `NameFast`.
  - Reuse scratch buffer across `bulk_children()`; run filesystem walk outside the long `IMMEDIATE` transaction and commit writes in bounded batches (5k–10k items). Fix `is_index_path()` not to skip unrelated `"Lumen"` directories.
  - Fix `Mode::All` multi-word early return skipping semantic search; fix bare extension token parsing so single-word queries like `json` do not drop `words`.
  - Retry read snapshots (up to 3x) on concurrent `data_version` bump in `ImageSearchSession` and `validate_catalog_hit`. Do not permanently stamp transient `PermissionDenied` or PDF timeout errors in `index_content()`.
  - Fix `watch --cached-start` so `resume::verify_access` still reconciles revoked TCC permissions; over-fetch before `verify_cached_access()` applies `LIMIT`; set `pending_recovery = true` when live loop sees `entries_unreadable != 0`.
- **Non-Goals**: No full SoA rewrite yet (`T08`); no Swift changes.

### `T06` Default Scope Hygiene (`done`)
- **Worktree**: `m1-rust-hotpath`
- **Allowed files**: same as `T05`
- **Scope**:
  - Treat macOS bundle/package extensions (`.app`, `.framework`, `.bundle`, `.xcodeproj`, `.xcworkspace`, `.photoslibrary`, `.musiclibrary`, `.fcpbundle`, `.imovielibrary`, `.playground`, `.xcarchive`, `.dsym`, `.lproj`, `.kext`, `.plugin`, `.appex`, `.xpc`) as opaque (index package itself, skip descending inside by default).
  - Exclude standard dev/system noise by default (`node_modules`, `target`, `DerivedData`, `.venv`, `venv`, `__pycache__`, `Pods`, `.gradle`, `.cargo`, `.rustup`, `.npm`, `.pnpm-store`, `.yarn`, `.next`, `.nuxt`, `.build`, `.swiftpm`, `bower_components`, `CMakeFiles`, `/Library`, `/usr`, `/bin`, `/sbin`, `/opt`, `~/Library` except `Mobile Documents` & `CloudStorage`; keep `/Applications` and `/System/Applications`).
  - Preserve cloud `SF_DATALESS` protections and explicit custom-root indexing behavior for tests/explicitly added roots.
- **Non-Goals**: Same as `T05`.

---

## Milestone 2: P1 Architecture Convergence & Spotlight Parity (`done`)

### `T07` Unified `serve` Protocol & Eliminate Swift Process Storms (`done`)
- **Worktrees**: `m2-engine-serve-soa` (Rust) + `m2-ux-spotlight-parity` (Swift)
- **Scope**:
  - Rust: Support `mode: "text"` directly in `lumen serve` and add lightweight in-session `validate` / batch-check request. Fix duplicate `deny_rules`/`mounted()` calls in `src/external.rs`.
  - Swift: Route full-text search through persistent `lumen serve`; remove per-keystroke `textProcess` and `nameBypassProcess`; stop permanent `--check-access` once `watch` emits `ready`; remove per-hit `validate-hit` fanout.

### `T08` Compact In-Memory SoA Name Index (`done`)
- **Worktree**: `m2-engine-serve-soa`
- **Scope**:
  - Upgrade `src/name_fast.rs` to compact Structure-of-Arrays (SoA) byte-pool scaling past 1,000,000 entries within <=150 MiB RAM.
  - Serve single-word, multi-word, `ext:`/`.pdf`, `kind:`, path prefix, and pinyin queries directly from RAM.
  - Rank by composite score: match quality + cleanliness (`user_area && !noise`) + recency (`mtime`) + kind priority.

### `T09` Native File UX: Spacebar Quick Look, Drag & Drop, Query Filters (`done`)
- **Worktree**: `m2-ux-spotlight-parity`
- **Scope**:
  - Spacebar Quick Look in browse state (typing state inserts space; `⌘Y` always toggles; never materialize `SF_DATALESS`).
  - Drag & Drop local file URLs from result rows.
  - Query filter hints & support for `kind:` / `ext:` / path prefixes.

### `T10` Out-of-the-Box Readiness, System Actions & Unified Frecency (`done`)
- **Worktree**: `m2-ux-spotlight-parity`
- **Scope**:
  - Launch at Login (`SMAppService.mainApp`) in Settings → General.
  - Automatic quiet initial background name indexing on first launch without dismissing the panel.
  - High-frequency native macOS system actions (Lock Screen, Sleep, Empty Trash with confirm, Toggle Dark Mode, Mute/Unmute, Eject External Volume, Dictionary Lookup via `DCSCopyTextDefinition`).
  - Unified Frecency ranking across apps, actions, and files.

### `T11` End-to-End Benchmarks (`done`)
- **Worktree**: `m2-engine-serve-soa`
- **Scope**:
  - Run `scripts/benchmark.py` on 100k and 1M synthetic entries (Chinese + pinyin + multi-word + concurrent updates) and record results in `benchmarks/v0.4-baseline.md`.

---

## Milestone 3: P2 Simplification + Semantic/Multimodal Moat (`done`)

### `T12` UI Cleanup, Streaming Translation/QA & Built-in Quicklinks (`done`)
- **Worktree**: `m3-cleanup-polish`
- **Scope**:
  - Retire misleading "Raycast Extensions" UI entry from the primary macOS app (keep `extensions/` crate and tests intact).
  - Add SSE streaming (`stream: true`) with Esc cancellation and non-streaming fallback in `TranslationClient.swift`.
  - Expose built-in optional web quicklinks (`gh`, `wiki`, `map`) in Settings → Quicklinks.
  - Update `README.md`, `README.en.md`, `CHANGELOG.md`.

### `T13` Semantic Engine Upgrade (`done`)
- **Worktree**: `m3-semantic-multimodal`
- **Scope**:
  - Store new/rebuilt vectors in `f16` (backward-compatible `f32` reader).
  - Cache contiguous vector matrix in RAM inside `GemmaSearchSession` and `ImageSearchSession` with tight dot-product loop.
  - Per-query z-score + minimum-cosine adaptive gating to replace fixed `0.0` / `0.65` thresholds.
  - Cache verified `(path, size, mtime, sha256)` metadata so Gemma assets aren't re-hashed via `/usr/bin/openssl` on every batch.

### `T14` Multimodal Expansion: HEIC/WebP + Apple Vision OCR (`done`)
- **Worktree**: `m3-semantic-multimodal`
- **Scope**:
  - Support `.heic`, `.heif`, and `.webp` in `image_decode.rs` / `image_search.rs` (keeping `NoMaterialization` / `SF_DATALESS` / 12 MiB / 32MP limits).
  - Add local Apple Vision OCR extraction for indexed local images/screenshots into `content_fts` (opt-in within scope, never touching `SF_DATALESS`).
