<img src="assets/readme/lumen-hero.svg" width="100%" alt="Lumen, local search for Mac. An illustration shows one search box finding files.">

# Lumen

**Find files, open apps, and jump to System Settings from one keyboard shortcut.** The same search box matches names, paths, pinyin, and indexed document text. It also accepts commands for translation, model questions, and image search.

[Quick start](#quick-start) · [Features and limits](#features-and-limits) · [Development](#development) · [简体中文](README.md)

**v0.3.3** · **Apple Silicon** · **macOS 14+** · **Rust + native macOS UI**

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

Open Lumen from the menu bar or press **Control–Shift–Space**. Record or disable the shortcut in **Settings → General & Shortcuts**. Apps and System Settings are searchable immediately. For files, select **Build Index in Background** from the menu bar, or first choose a scope in **Index & Privacy**. The menu bar shows the current phase, scanned item count, and elapsed time.

When you reopen Lumen, eligible results from the saved index can appear while the watcher catches up with changes made since you closed it.

### Use the same launcher field

| Type or press | Action |
| :--- | :--- |
| `?` | Browse commands. Use the arrow keys to select one and Return to fill it in. |
| `tr` | Type `tr:zh Meeting postponed` and press Return to translate. You can also enter `tr text` or `translate`. |
| `qa` | Type `qa How do I plan a reading list?` and press Return to ask the selected model. Press Return again to copy the answer, or Esc to cancel the request. Q&A has no web search, file attachments, or clipboard access. |
| `g` | Type `g macOS shortcuts` and press Return to open Google Search in your default browser. Add custom HTTPS query aliases under **Quicklinks**. |
| `img` | Type `img red sailboat` to find indexed local images by what they show. |
| Return / ⌘Return / ⌘K | Open the selected item, reveal the file in Finder, or open the result actions. |
| ⌘Y / Esc | Preview a local image, PDF, or indexed excerpt in the launcher. A PDF can jump to a known match page. Esc dismisses the preview first. |
| ⇧⌘C / ⌥⌘C | Copy the file name or path. |
| ⌘, | Open Settings. |

Q&A and translation share the provider and model selected under **Settings → Translation**. Use a local oMLX instance or another OpenAI-compatible endpoint. Only text you submit is sent to the provider shown in the launcher. [Provider setup](docs/TRANSLATION.md)

**Enable image content search.** Under **Settings → Index & Privacy → Image Content**, choose one local folder already covered by the name index and a matching local projector. Then select **Build or Refresh Image Index**. PNG and JPEG search uses the local EmbeddingGemma 2 model and a separately staged vision projector. [Model, projector, and file limits](docs/offline-image-search.md)

## Features and limits

- **Separate scopes for names, documents, and images.** Name indexing defaults to accessible locations on the startup disk, skipping system, private, cache, and hidden locations. Choose folders or add exclusions, which take priority. Scope and document changes take effect on **Apply**. Add an external volume's name index under **Index & Privacy**. Its results are hidden when disconnected.
- **Opt-in document and semantic search.** In selected folders, Lumen reads local TXT and Markdown, paragraphs and tables in the main DOCX document, and the native PDF text layer. OCR and DOCX page numbers are outside the current scope. Encrypted, oversized, or unsupported documents remain searchable by name. An optional local model can surface related excerpts. Name search requires no model. [Offline semantic search](docs/offline-gemma.md)
- **Cloud files are indexed by visible metadata.** For recognized iCloud, OneDrive, and other File Provider locations, Lumen records names and paths the system exposes. Indexing and previewing do not download cloud placeholders. Search indexes and offline inference stay on the Mac. Model weights are provisioned separately.
- **Check progress and diagnose missing files.** **Advanced & Diagnostics** shows file watching and semantic indexing separately. Use **File Diagnostics → Choose File** to check name, document, and semantic coverage for a file. This check neither reads document content nor downloads a placeholder.
- **Pin frequently used items.** Pinned items appear with an empty query. Save apps, project folders, or web pages as quicklinks or aliases.
- **Limited Raycast compatibility.** Add a local directory under **Extensions** for the [supported no-view commands](extensions/README.md), including text notifications and copying with confirmation. The Raycast Store, arbitrary JavaScript, and TypeScript/React interfaces are outside that subset.

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
python3 scripts/smoke-app.py
python3 scripts/smoke-launcher.py
python3 scripts/smoke-relaunch.py target/Lumen.app
python3 scripts/smoke-translation.py
extensions/tests/smoke-panel.sh
```

Use synthetic fixtures. Tests for AppKit and FSEvents depend on native macOS services. Simulated or skipped tests do not establish coverage on physical external drives or live third-party services.

</details>

Original source is released under the [MIT License](LICENSE). Lumen is independently implemented, with product inspiration from Tinycast, Oil Find, DigUp, and Luminator Index.
