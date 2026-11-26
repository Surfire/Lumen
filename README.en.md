<img src="assets/readme/lumen-hero.svg" width="100%" alt="Lumen, local search for Mac. An illustration shows one search box finding files.">

# Lumen

**Find files, open apps, and jump to System Settings from one keyboard shortcut.** The same search box matches names, paths, pinyin, and indexed document text. It also accepts commands for translation, model questions, and image search.

[Quick start](#quick-start) · [Features and limits](#features-and-limits) · [Development](#development) · [简体中文](README.md)

**v0.4** · **Apple Silicon** · **macOS 14+** · **Rust + native macOS UI**

| Try typing | What happens |
| :--- | :--- |
| `Q4 plan pdf` | Find PDFs matching both terms. Quote an exact phrase. |
| `luming` / `lm` | Finds a file named 鹿鸣 using full pinyin or initials. |
| `Bluetooth` | Find the macOS settings page without a file index. |

## Quick start

Build from the repository root on an Apple Silicon Mac with macOS 14 or later, the Xcode command-line tools, and Rust.

```sh
scripts/build-app.sh
open target/Lumen.app
```

This creates an ad hoc signed development build. For daily use, build with an existing named signing identity and update the installed app in place. macOS may request folder access again when you migrate from an ad hoc build. [Local signing, installation, and rollback](docs/UPGRADING.md)

Open Lumen from the menu bar or press **Control–Shift–Space**. Record or disable the shortcut in **Settings → General & Shortcuts**. Apps and System Settings are searchable immediately. The first eligible name scan starts quietly in the background. Adjust the folder scope in **Index & Privacy**, or start a scan from the menu bar, which shows the current phase, scanned item count, and elapsed time.

When you reopen Lumen, eligible results from the saved index can appear while the watcher catches up with changes made since you closed it.

### Signed releases and Homebrew

For a release-signed copy in a writable Applications folder, open **Settings → Advanced & Diagnostics → Check for Updates**. Checks are manual. Lumen verifies the signed GitHub release manifest, ZIP checksum, and app signature before replacing the app. Quit and reopen after installation; Lumen shows where it saved the previous app. Ad hoc builds cannot use the updater. If the release signing certificate changes, install the first build with the new certificate manually.

If you installed from a Homebrew tap, use `brew upgrade --cask lumen` instead. Normal uninstall keeps your data; `--zap` also removes Lumen’s preferences and Application Support, including scripts and clipboard history.

### Use the same launcher field

| Type or press | Action |
| :--- | :--- |
| `?` | Browse commands. Use the arrow keys to select one and Return to fill it in. |
| `tr` | Type `tr:zh Meeting postponed` and press Return to translate. You can also enter `tr text` or `translate`. |
| `qa` | Type `qa How do I plan a reading list?` and press Return to ask the selected model. Q&A has no web search, file attachments, or clipboard access. |
| `g` | Type `g macOS shortcuts` and press Return to open Google Search in your default browser. Under **Settings → Quicklinks**, enable the optional `gh` (GitHub), `wiki` (Chinese Wikipedia), and `map` (Google Maps) commands, or add custom HTTPS query aliases. |
| `img` | Type `img red sailboat` to find indexed local images by what they show. |
| Return / ⌘Return / ⌘K | Open the selected item, reveal the file in Finder, or open the result actions. |
| Space / ⌘Y / Esc | Space opens Quick Look on the selected local file while browsing; it still inserts a space while typing. ⌘Y toggles preview, and Esc dismisses it first. A PDF preview can jump to a known match page. |
| ⇧⌘C / ⌥⌘C | Copy the file name or path. |
| ⌘, | Open Settings. |

Q&A and translation share the provider and model selected under **Settings → Translation**. Use a local oMLX instance or another OpenAI-compatible endpoint. Results appear incrementally over Server-Sent Events (SSE); a provider that responds with ordinary JSON still works. Esc or editing the query cancels the request. Press Return again after completion to copy. Only text you submit is sent to the provider shown in the launcher. [Provider setup](docs/TRANSLATION.md)

**Enable image content search.** Under **Settings → Index & Privacy → Image Content**, choose one local folder already covered by the name index and a matching local projector. Then select **Build or Refresh Image Index**. PNG and JPEG search uses the local EmbeddingGemma 2 model and a separately staged vision projector. [Model, projector, and file limits](docs/offline-image-search.md)

## Features and limits

- **Separate scopes for names, documents, and images.** Name indexing defaults to accessible locations on the startup disk, skipping system, private, cache, and hidden locations. Choose folders or add exclusions, which take priority. Scope and document changes take effect on **Apply**. Add an external volume's name index under **Index & Privacy**. Its results are hidden when disconnected.
- **Opt-in document and semantic search.** In selected folders, Lumen reads local TXT and Markdown, paragraphs and tables in the main DOCX document, and the native PDF text layer. OCR and DOCX page numbers are outside the current scope. Encrypted, oversized, or unsupported documents remain searchable by name. An optional local model can surface related excerpts. Name search requires no model. [Offline semantic search](docs/offline-gemma.md)
- **Cloud files are indexed by visible metadata.** For recognized iCloud, OneDrive, and other File Provider locations, Lumen records names and paths the system exposes. Indexing and previewing do not download cloud placeholders. Search indexes and offline inference stay on the Mac. Model weights are provisioned separately.
- **Check progress and diagnose missing files.** **Advanced & Diagnostics** shows file watching and semantic indexing separately. Use **File Diagnostics → Choose File** to check name, document, and semantic coverage for a file. This check neither reads document content nor downloads a placeholder.
- **Pin frequently used items.** Pinned items appear with an empty query. Save apps, project folders, or web pages as quicklinks or aliases.

## Planned for v0.5

- Sharper visual hierarchy and match highlighting, plus opt-in private local clipboard history.
- Native Accessibility window management, opt-in local script commands, and Apple Shortcuts.
- A static, in-process core for hot search, with heavy extractors still isolated.
- Signed in-app updates and a Homebrew Cask.

## What’s new in v0.4

- **M1 — Reliability.** The search panel stays out of the way of other apps, follows the pointer’s display, and respects IME composition. App lookup adds fuzzy matching; ranking learns from successful opens. Indexing skips common development caches and treats app bundles as packages by default.
- **M2 — Spotlight-style interactions and one search process.** Drag local files from results, filter with `kind:`, `ext:`, and path prefixes, and use Space for Quick Look while browsing. Settings offers Launch at Login; the launcher supports actions such as Lock Screen, Sleep, and Mute. A persistent `lumen serve` session handles name search, full-text search, and batch result validation without launching a process for each query or hit.
- **M3 — Streaming and simpler settings.** `tr` and `qa` stream in the launcher, and the optional web commands are off by default. The main app no longer ships an Extensions settings page or helper; the standalone Rust crate remains.
- **M3 — Separate semantic and multimodal work for the integrated release.** T13 covers compact f16 vector storage for new/rebuilt embeddings while retaining f32 reads. T14 covers HEIC/HEIF and WebP image search and opt-in, on-device Apple Vision OCR for local images and screenshots. These are not part of the launcher cleanup worktree; cloud-only placeholders must not be downloaded for indexing.

### Million-file name-index benchmark

On an Apple M5 Max, the compact structure-of-arrays (SoA) index scanned 1,000,000 synthetic files in **45,503.66 ms** and the warm `lumen serve` process used **140,880 KiB (137.58 MiB)**. After checking update visibility it used **146,960 KiB (143.52 MiB)**. All 4,000 hot queries returned the expected path in the top 20.

| Hot query class | p50 (ms) | p95 (ms) | p99 (ms) |
| :--- | ---: | ---: | ---: |
| Latin name | 0.253 | 0.328 | 0.357 |
| Chinese name | 0.495 | 1.195 | 1.368 |
| Pinyin | 0.477 | 0.961 | 1.079 |
| Multiword | 0.264 | 0.342 | 0.402 |

These are selective, warm name queries over persistent CLI transport, including JSONL round-trip time—not launch, UI, full-text, or Spotlight comparison timings. See the [v0.4 baseline](benchmarks/v0.4-baseline.md) for the 100k run, concurrent rescan results, and methodology.

## Development

Rust handles scanning, indexing, and retrieval. AppKit and SwiftUI provide the native interface.

[Changelog](CHANGELOG.md) · [Architecture](docs/ARCHITECTURE.md) · [Compatibility](docs/COMPATIBILITY.md) · [Benchmark protocol](docs/BENCHMARK.md) · [Third-party dependencies](THIRD_PARTY.md)

<details>
<summary>Build and regression checks</summary>

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo test --locked --manifest-path extensions/Cargo.toml
scripts/build-app.sh
python3 scripts/smoke-updater.py
python3 scripts/smoke-app.py
python3 scripts/smoke-launcher.py
python3 scripts/smoke-relaunch.py target/Lumen.app
python3 scripts/smoke-translation.py
```

Use synthetic fixtures. Tests for AppKit and FSEvents depend on native macOS services. Simulated or skipped tests do not establish coverage on physical external drives or live third-party services.

</details>

**Packaging a release:** Set `LUMEN_SIGN_IDENTITY` to the named Keychain identity and `LUMEN_MANIFEST_KEY` to a protected PEM of the same private key, kept outside the repository. Set `LUMEN_NOTARY_PROFILE` to a `notarytool` profile for public Developer ID releases. Run `scripts/package-release.sh OUTPUT_DIR RELEASE_NOTES.txt` and upload the ZIP and `lumen-update.json.cms` to the GitHub release tagged `v<version>`. Increment the bundle build number for every release. Use `version` and `sha256` from the emitted `lumen-update.json` to fill the [Cask template](packaging/homebrew/Casks/lumen.rb) before publishing it in a tap.

Original source is released under the [MIT License](LICENSE). Lumen is independently implemented, with product inspiration from Tinycast, Oil Find, DigUp, and Luminator Index.
