import SwiftUI

struct ImageSearchScope: Decodable {
    let root: String?
    /// Present once image indexing follows the unified `content_roots` scope.
    let roots: [String]?
    let vectors: Int

    var hasFolders: Bool { root != nil || !(roots ?? []).isEmpty }
}

@MainActor
final class LauncherImageSearch: ObservableObject {
    private struct Batch: Decodable {
        let indexed: Int
        let reused: Int
        let limited: Bool
        let next_after: String?
    }

    @Published private(set) var scope: ImageSearchScope?
    @Published private(set) var projector: URL?
    @Published private(set) var loading = false
    @Published private(set) var building = false
    @Published private(set) var checked = 0
    @Published private(set) var limited = false
    @Published private(set) var failed = false

    private let engine: LauncherEngine
    private let defaults: UserDefaults?
    /// True only when the user picked a projector; the installed default is detected instead of stored.
    private(set) var customProjector = false
    private var readAttempted = false
    private var process: Process?
    private var generation = 0

    init(engine: LauncherEngine, defaults: UserDefaults?) {
        self.engine = engine
        self.defaults = defaults
        projector = defaults?.string(forKey: "launcher.imageProjector.v1").map { URL(fileURLWithPath: $0) }
        customProjector = projector != nil
        adoptInstalledProjector()
    }

    // Vectors exist only for folders inside the unified content scope, so they alone mark readiness.
    var readyProjector: URL? { !loading && (scope?.vectors ?? 0) > 0 ? projector : nil }

    /// Uses the one-click installed `Gemma2/mmproj-embeddinggemma-2-Q8_0.gguf` unless the user picked another file.
    func adoptInstalledProjector() {
        guard !customProjector, !building, let home = engine.installedGemmaHome else { return }
        let installed = GemmaAssetManager.installedProjector(home: home)
        guard installed != projector else { return }
        if projector != nil { engine.closeImages() }
        projector = installed
    }

    func ensureStatus() {
        guard !readAttempted else { return }
        adoptInstalledProjector()
        refresh()
    }

    private func refresh() {
        guard engine.hasDatabase, !loading else { return }
        readAttempted = true
        loading = true
        _ = engine.run(["image-status"]) { [weak self] response in
            guard let self else { return }
            self.loading = false
            if response.succeeded { self.scope = try? JSONDecoder().decode(ImageSearchScope.self, from: response.output) }
        }
    }

    func setProjector(_ url: URL) {
        guard !building, url.isFileURL else { return }
        engine.closeImages()
        projector = url
        customProjector = true
        failed = false
        defaults?.set(url.path, forKey: "launcher.imageProjector.v1")
    }

    func setFolder(_ url: URL?) {
        guard !loading, !building, engine.hasDatabase else { return }
        engine.closeImages()
        loading = true
        failed = false
        let command = url.map { ["image-scope", "--", IndexScope.folderPath($0)] } ?? ["image-scope", "--clear"]
        _ = engine.run(command) { [weak self] response in
            guard let self else { return }
            self.loading = false
            guard response.succeeded, let scope = try? JSONDecoder().decode(ImageSearchScope.self, from: response.output)
            else { self.failed = true; return }
            self.scope = scope
            self.readAttempted = true
            self.checked = 0
            self.limited = false
        }
    }

    func build() {
        guard let projector, !loading, !building else { return }
        generation += 1
        building = true
        checked = 0
        limited = false
        failed = false
        if engine.supportsStreamingBatches {
            streamBuild(projector: projector, generation: generation)
        } else {
            batch(after: nil, projector: projector, generation: generation)
        }
    }

    func stop(refreshStatus: Bool = true) {
        guard building else { return }
        generation += 1
        if process?.isRunning == true { process?.terminate() }
        process = nil
        building = false
        if refreshStatus { refresh() }
    }

    private func streamBuild(projector: URL, generation: Int) {
        let args = ["image-index", "--projector", projector.path, "--stream", "--max", "16"] + engine.gemmaOptions
        var sawBatch = false
        process = engine.run(args, onLine: { [weak self] line in
            guard let self, self.generation == generation,
                  let batch = try? JSONDecoder().decode(Batch.self, from: line) else { return }
            sawBatch = true
            self.checked += batch.indexed + batch.reused
            self.limited = batch.limited
        }, priority: .background) { [weak self] response in
            guard let self, self.generation == generation else { return }
            self.process = nil
            self.building = false
            if !response.succeeded || !sawBatch {
                self.failed = true
            }
            self.refresh()
        }
    }

    private func batch(after cursor: String?, projector: URL, generation: Int) {
        let args = ["image-index", "--projector", projector.path, "--max", "16"] + engine.gemmaOptions
            + (cursor.map { ["--after", $0] } ?? [])
        process = engine.run(args, priority: .background) { [weak self] response in
            guard let self, self.generation == generation else { return }
            self.process = nil
            guard response.succeeded, let batch = try? JSONDecoder().decode(Batch.self, from: response.output) else {
                self.building = false
                self.failed = true
                self.refresh()
                return
            }
            self.checked += batch.indexed + batch.reused
            self.limited = batch.limited
            if !batch.limited, let next = batch.next_after, next != cursor {
                self.batch(after: next, projector: projector, generation: generation)
            } else {
                self.building = false
                self.refresh()
            }
        }
    }
}

/// Image-embedding status inside the unified Semantic & Content Index card; folders come from `content_roots`.
struct LauncherImageSettings: View {
    @ObservedObject var launcher: Launcher
    @ObservedObject var images: LauncherImageSearch

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(launcher.t("图像画面", "Image Pixels")) {
                if images.building {
                    Text(launcher.t("已处理 \(images.checked) 张", "Prepared \(images.checked) images"))
                } else if images.projector == nil {
                    Text(launcher.t("需要图像多模态模型", "Needs the image multimodal model")).foregroundStyle(.secondary)
                } else {
                    Text(launcher.t("已索引 \(images.scope?.vectors ?? 0) 张", "Indexed \(images.scope?.vectors ?? 0) images"))
                        .foregroundStyle(.secondary)
                }
            }
            if images.failed { Text(launcher.t("图像索引失败。请检查目录和图像模型。", "Image indexing failed. Check the folders and image model, then retry.")).foregroundStyle(.secondary) }
            if images.limited { Text(launcher.t("已达图像索引容量上限。", "The image index is at its storage limit.")).foregroundStyle(.secondary) }
        }
    }
}
