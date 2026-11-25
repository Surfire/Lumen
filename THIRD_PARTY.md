# Third-party dependencies

Lumen's original source is MIT-licensed. Tinycast, Oil Find, DigUp, and the earlier Luminator Index were design references only; this repository does not bundle their source, assets, or binaries.

Rust dependencies are pinned in `Cargo.lock` and retain their own licenses. To inspect the licenses for the current Apple Silicon build:

```sh
cargo metadata --locked --filter-platform aarch64-apple-darwin --format-version 1
```

The macOS bundle links Apple system frameworks such as CoreFoundation, AppKit, SwiftUI, PDFKit, and NaturalLanguage. The application uses the system's available sentence embeddings; it does not redistribute Apple frameworks or model weights. Source publication is separate from redistributing a prebuilt application, which requires preserving the applicable dependency notices.
