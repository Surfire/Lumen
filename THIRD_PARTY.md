# Third-party dependencies

Lumen's original source is MIT-licensed. Tinycast, Oil Find, DigUp, and the earlier Luminator Index were design references only; this repository does not bundle their source, assets, or binaries.

Rust dependencies are pinned in `Cargo.lock` and retain their own licenses. To inspect the licenses for the current Apple Silicon build:

```sh
cargo metadata --locked --filter-platform aarch64-apple-darwin --format-version 1
```

The macOS bundle links Apple system frameworks such as CoreFoundation, AppKit, SwiftUI, PDFKit, and NaturalLanguage. The optional local semantic panel uses separately provisioned BGE model resources and an isolated Python runtime. The legacy CLI smoke adapter can also use the system's sentence embeddings. The source repository and local bundle do not redistribute Apple frameworks, Python runtimes or model weights. The offline model manifest and license references are described in [offline semantic setup](docs/offline-semantics.md). Source publication is separate from redistributing a prebuilt application, which requires preserving the applicable dependency notices.
