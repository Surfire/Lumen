<p align="center">
  <img src="assets/readme/lumen-hero-en.png" width="100%" alt="Lumen for macOS: Instant local search, matched-page PDF preview highlighting, and on-device semantic retrieval">
</p>

<p align="center">
  <img src="assets/readme/lumen-logo.png" width="68" alt="Lumen Origami Stag Logo">
</p>

<h1 align="center">Lumen</h1>

<p align="center">
  <strong>Find files, launch apps, jump to System Settings, and preview exact answers inside documents from one shortcut.</strong><br>
  Powered by a compact zero-posting SoA + AArch64 NEON Rust engine and a native AppKit / SwiftUI interface.<br>
  Combines millisecond disk-wide filename &amp; pinyin search, matched-page PDF highlighting, unified multimodal Gemma retrieval, SMB/NFS share indexing, smart window tiling, and zero-download cloud boundaries.
</p>

<p align="center">
  <a href="#interface-gallery">Interface</a> ·
  <a href="#why-lumen">Why Lumen</a> ·
  <a href="#comparison-with-alternatives">Comparison</a> ·
  <a href="#verified-benchmarks">Benchmarks</a> ·
  <a href="#quick-start--installation">Quick Start</a> ·
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <code>v0.5.1</code> · <code>Apple Silicon</code> · <code>macOS 14+</code> · <code>Rust + AppKit / SwiftUI</code> · <a href="LICENSE"><code>MIT License</code></a>
</p>

---

| Try typing | What happens |
| :--- | :--- |
| `Q4 plan pdf` | Matches multiple keywords and filters by real PDF extension; quote for exact phrases |
| `luming` / `lm` | Finds files named 鹿鸣 via full pinyin or initials |
| `Bluetooth` / `25 km in mi` | Jump straight to System Settings or convert units locally—no file index required |
| `tr:zh Meeting postponed` | Streams translation inside the launcher (`Return` copies output; supports local oMLX or OpenAI-compatible endpoints) |
| `qa How to structure a review?` | Sends only your explicit prompt to the selected model; `Esc` cancels cleanly with no web or file leakage |
| `img sailboat` | Searches indexed local photos and documents semantically with on-device multimodal embeddings |
| `?` / `win` | Browse all built-in commands & Accessibility window tiling (portrait thirds, smart auto-tile, batch restore) |

---

## Interface Gallery

### Search & Visual-First Matched-Page Preview (Light & Dark)

> Press **`Space`** (while browsing) or **`⌘Y`** on a PDF hit: inline preview puts the rendered matched page with translucent amber passage highlights **above** the extracted text context, while the standalone Quick Look window scales automatically to match the true aspect ratio and rotation of PDFs, images, docs, or media.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/search-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/search-light.png">
    <img src="assets/readme/search-light.png" width="90%" alt="Lumen search results with visual-first inline PDF match-page preview">
  </picture>
</p>

### Native macOS Settings & Tactile Shortcuts

> Native `.switch` toggles, keycap shortcut capture, isolated include/exclude indexing rules, and offline diagnostics without waking cloud placeholders.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/settings-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/settings-light.png">
    <img src="assets/readme/settings-light.png" width="90%" alt="Lumen native macOS settings window">
  </picture>
</p>

---

## Why Lumen

- **~1 ms Disk-Wide Filename Search in ~145 MiB Resident RAM**
  Instead of duplicating large inverted posting tables across search lanes, Lumen runs one compact structure-of-arrays (SoA) table scanned in parallel with **AArch64 NEON SIMD**. On a real Apple Silicon index of **1,667,692 disk items**, warm name, pinyin, and path queries finish in **0.79–1.75 ms** inside a **144.7 MiB** resident worker.
- **Visual-First Document Preview With Unified Space & `⌘Y`**
  Lumen extracts local TXT, Markdown, DOCX paragraphs/tables, and native PDF text layers on demand. PDF hits jump straight to the matched page with amber passage highlights. Both **`Space`** (inline preview while browsing) and **`⌘Y`** (content-proportional Quick Look window) share one cloud-safe hydration path with progress indication and `Esc` cancellation.
- **Unified Multimodal Semantic Index, Smart Filters & 1-Click Gemma Downloader**
  Documents and images share a unified **Semantic & Content Index** setup with batched EmbeddingGemma inference, pre-Apply folder breakdowns, default build-noise skipping (`node_modules`, `target`, `dist`, lockfiles), code files off by default, and a 1-click SHA-256 verified downloader (**HuggingFace / HF-Mirror**) plus local file import.
- **Physical External Drives, SMB / NFS Shares & Cloud-Safe Boundaries**
  Every scan, preview, and diagnostic call enforces thread-scoped `IOPOL_VFS_MATERIALIZE_DATALESS_FILES_OFF` and `SF_DATALESS` checks so iCloud/OneDrive placeholders never auto-download. Physical drives and SMB/NFS network shares are cleanly separated (credential-free deterministic mount identities and kernel `f_fstypename`-anchored preview checks).
- **Unified Native macOS Workflow & Smart Window Tiling**
  Pin favorites, calculate/convert units, trigger quicklinks, browse rich clipboard history (images, files, URLs, colors), switch Light / Dark / System appearance, run scripts & Shortcuts, auto-tile or position windows across portrait and landscape screens (discoverable via `?`), and stream `tr` / `qa` answers.

---

## Comparison with Alternatives

| Capability | **Lumen** | **macOS Spotlight** | **Raycast / Alfred** | **Oil Find** | **DigUp** |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Focus** | Whole-disk fast search + page-level doc preview + native launcher | System search | Extensible workflow launcher | Dedicated fast file finder | Multimodal local content retrieval |
| **Filename Engine** | Custom Rust zero-posting SoA + parallel NEON | macOS `mds` / `mdimporter` | Delegates file lookup to Spotlight (`mdfind`) | Custom C + NEON scan & filter | Chunk-level semantic index rather than full-disk filename launcher |
| **Million-File Footprint** | **~145 MiB** (measured on 1.67M real items) | Managed by background OS daemons | Lightweight UI + relies on OS Spotlight | Very low-memory filename residency | Scales with local model & content vector store |
| **Doc FTS & Local Semantic** | Built-in FTS + local **EmbeddingGemma** (free, open-source) | Keyword/metadata only; no local Gemma retrieval | Extensions / Spotlight / optional Pro AI | Free filename & external drive; Pro paid for text/image content | Free open-source **EmbeddingGemma 2** multimodal search |
| **Matched PDF Page + Highlight** | Jumps to matched page & highlights inline + Quick Look | Standard Quick Look preview | Standard Quick Look / extensions | Focused on fast file paths & basic preview | Passage excerpt & match locations |
| **Chinese Pinyin & Initials** | Built-in full pinyin & initials (`luming` / `lm`) | Partial OS support | Requires community workflows | Built-in pinyin & multi-mode matching | — |
| **Launcher Workflows** | Apps, System Settings, calc/units, clipboard, Accessibility windows, scripts/Shortcuts, `tr`/`qa` | Apps, calc, web suggestions | **Strength**: huge extension marketplace | File finding only (no apps/clipboard/window tiling) | Focused on media & doc search |
| **Zero Cloud Materialization** | Thread-level `IOPOL` + `SF_DATALESS` isolation | Depends on importer & provider | Relies on Spotlight or workflow scripts | Checks cloud flags on placeholder files | Operates on chosen local folders |
| **License** | **MIT Open Source (Free)** | Proprietary macOS component | Free core (optional paid Pro tiers) | MIT for filenames/external drives; paid Pro for content search | **Free Open Source** |

---

## Verified Benchmarks

### 1. Real 1,667,692-Item Apple Silicon Disk Index (Warm `lumen serve`)

Measured directly against a real disk database holding **1,667,692 items**, **2,370 documents**, and **43,690 EmbeddingGemma vectors** (single `NameFast` instance on `nameLane`, zero duplicate copy on `textLane`):

| Query Type | Measured Latency / RSS | Notes |
| :--- | ---: | :--- |
| Pinyin initials (`lm`) | **0.79 ms** | `mode=name`, warm Top 60 |
| Chinese 2-character (`临床` / `项目` / `工作` / `报告`) | **0.85–0.93 ms** | Parallel AArch64 NEON zero-posting scan |
| Latin name (`readme`) | **1.10 ms** | `mode=name`, warm |
| High-frequency / single-Han (`方案` / `方`) | **1.54–1.61 ms** | Full 1.67M scan without timeout or degradation |
| Negative miss (`哈基米`) | **1.75 ms** | Fast miss without stalling UI |
| `lumen serve` resident memory (RSS) | **144.7 MiB** | Single resident `NameFast` + SQLite handle |
| Document full-text (`方案` / FTS miss `哈基米`) | **46.61 ms** / **0.16 ms** | `mode=text` + FTS5 |
| Local EmbeddingGemma semantic queries (14-query sweep) | **~18–25 ms** | 7/7 in-domain queries hit cleanly; 7/7 noise queries return **0 hits** |

### 2. 1,000,000-File Synthetic Baseline (Apple M5 Max)

Scanning 1,000,000 synthetic files took **45,503.66 ms**, warm `lumen serve` used **140,880 KiB (137.58 MiB)** (**146,960 KiB / 143.52 MiB** after visibility check hardening), and all 4,000 warm queries returned the expected path in the top 20:

| Hot Query Class | p50 (ms) | p95 (ms) | p99 (ms) |
| :--- | ---: | ---: | ---: |
| Latin name | 0.253 | 0.328 | 0.357 |
| Chinese name | 0.495 | 1.195 | 1.368 |
| Pinyin | 0.477 | 0.961 | 1.079 |
| Multiword | 0.264 | 0.342 | 0.402 |

> Note: Timings measure core engine / persistent CLI round-trip execution and resident RSS; end-to-end GUI latency also includes debounce and SwiftUI presentation. See [benchmarks/v0.4-baseline.md](benchmarks/v0.4-baseline.md) and [docs/BENCHMARK.md](docs/BENCHMARK.md) for methodology.

---

## Keyboard Shortcuts & Commands

| Input or Shortcut | Action |
| :--- | :--- |
| **`⌃⇧Space`** (configurable) | Toggle Lumen non-activating search panel from anywhere |
| **`?`** | Browse built-in commands with arrow keys and `Return` |
| **`tr` / `qa` / `img`** | Streaming translation, on-prompt model Q&A, semantic image search |
| **`g`** / `gh` / `wiki` / `map` | Web search shortcuts (configure aliases under **Settings → Quicklinks**) |
| **`Return` / `⌘Return` / `⌘K`** | Open item, reveal in Finder, or open Context Actions menu |
| **`Space` / `⌘Y` / `Esc`** | `Space` previews while browsing (types space normally while editing); `⌘Y` toggles preview; `Esc` closes preview first |
| **`⇧⌘C` / `⌥⌘C`** | Copy file name or full path |
| **`⌘,`** | Open native Settings |

- Provider configuration: [docs/TRANSLATION.md](docs/TRANSLATION.md)
- Offline models & vision setup: [docs/offline-gemma.md](docs/offline-gemma.md) · [docs/offline-image-search.md](docs/offline-image-search.md)

---

## Quick Start & Installation

### Direct Download (Recommended for Early Testers)

Requires an **Apple Silicon Mac** and **macOS 14+**. Download **`Lumen-macos-arm64.dmg`** (or `.zip`) from [GitHub Releases](https://github.com/Surfire/Lumen/releases/latest), optionally verify via `shasum -a 256 -c SHA256SUMS.txt`, and drag `Lumen.app` to `/Applications`.

> For community ad-hoc GitHub Actions builds (Path B without Apple notarization), run once in Terminal if macOS Gatekeeper blocks first launch:
> ```sh
> xattr -dr com.apple.quarantine /Applications/Lumen.app
> ```

### Build from Source

Requires an **Apple Silicon Mac**, **macOS 14+**, Xcode Command Line Tools, and Rust:

```sh
scripts/build-app.sh
open target/Lumen.app
```

For daily use without repeated permission prompts, build with a persistent Keychain signing identity and install atomically in place:

```sh
LUMEN_SIGN_IDENTITY="Lumen Local Code Signing" scripts/build-app.sh
python3 scripts/install-app.py install target/Lumen.app
open -a "$HOME/Applications/Lumen.app"
```

### Automatic Update Checks & Homebrew

- **24-hour Auto-Check & Install & Relaunch**: Available in the status menu and **Settings → Advanced & Diagnostics**. Release-signed builds verify CMS manifest signature, ZIP SHA-256, and code signature before atomic swap + automatic relaunch (with backup rollback); ad-hoc community builds prompt and open the release download page without unsigned self-replacement.
- **Homebrew & Releasing**: Cask template at [`packaging/homebrew/Casks/lumen.rb`](packaging/homebrew/Casks/lumen.rb) (`brew upgrade --cask lumen`; `--zap` wipes preferences and history). See [docs/RELEASING.md](docs/RELEASING.md) and [docs/UPGRADING.md](docs/UPGRADING.md).

---

## Development & Verification

[Architecture](docs/ARCHITECTURE.md) · [Compatibility](docs/COMPATIBILITY.md) · [Releasing](docs/RELEASING.md) · [Changelog](CHANGELOG.md) · [Third-Party Dependencies](THIRD_PARTY.md)

<details>
<summary>Build, lint, unit, and smoke verification gates</summary>

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
scripts/build-app.sh
LUMEN_SMOKE=1 scripts/build-app.sh
python3 scripts/smoke-app.py
python3 scripts/smoke-launcher.py
python3 scripts/smoke-relaunch.py target/Lumen.app
python3 scripts/smoke-translation.py
python3 scripts/smoke-install-app.py
python3 scripts/smoke-updater.py
```

Synthetic fixtures are used across tests; AppKit and FSEvents verification requires an unlocked interactive macOS desktop session.

</details>

Released under the [MIT License](LICENSE). Independently implemented with product inspiration from Tinycast, Oil Find, DigUp, and Luminator Index.
