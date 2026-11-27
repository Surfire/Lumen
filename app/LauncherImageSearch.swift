import Darwin
import SwiftUI

struct ImageSearchScope: Decodable {
    let root: String?
    /// Present once image indexing follows the unified `content_roots` scope.
    let roots: [String]?
    let vectors: Int

    init(root: String?, roots: [String]? = nil, vectors: Int) {
        self.root = root
        self.roots = roots
        self.vectors = vectors
    }

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
    private var indexedInCurrentBuild = 0
    private(set) var noProgressExhausted = false
    var onBuildFinished: (() -> Void)?

    init(engine: LauncherEngine, defaults: UserDefaults?) {
        self.engine = engine
        self.defaults = defaults
        projector = defaults?.string(forKey: "launcher.imageProjector.v1").map { URL(fileURLWithPath: $0) }
        customProjector = projector != nil
        adoptInstalledProjector()
    }

    // Vectors exist only for folders inside the unified content scope, so they alone mark readiness.
    var readyProjector: URL? { !loading && (scope?.vectors ?? 0) > 0 ? projector : nil }
    var canAutoBuild: Bool {
        projector != nil && !customProjector && !loading && !building && !failed && !noProgressExhausted
    }

    func clearFailure() {
        failed = false
        noProgressExhausted = false
    }

    /// Synchronizes image scope from unified `lumen status` coverage without overwriting legacy `image-scope` picks.
    func applyCoverage(_ coverage: ImageCoverage?, contentRoots: [String]) {
        guard !building, let coverage else { return }
        guard coverage.enabled || scope?.root == nil else { return }
        let roots = coverage.enabled ? contentRoots : []
        if roots != (scope?.roots ?? []) || coverage.vectors != (scope?.vectors ?? 0) || !coverage.pending {
            noProgressExhausted = false
        }
        scope = ImageSearchScope(root: roots.first, roots: roots, vectors: coverage.vectors)
        limited = coverage.limited
        readAttempted = true
    }

    /// Uses the one-click installed `Gemma2/mmproj-embeddinggemma-2-Q8_0.gguf` unless the user picked another file.
    func adoptInstalledProjector() {
        guard !customProjector, !building, let home = engine.installedGemmaHome else { return }
        let installed = GemmaAssetManager.installedProjector(home: home)
        guard installed != projector else { return }
        if projector != nil { engine.closeImages() }
        projector = installed
        failed = false
        noProgressExhausted = false
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
        noProgressExhausted = false
        defaults?.set(url.path, forKey: "launcher.imageProjector.v1")
    }

    func setFolder(_ url: URL?) {
        guard !loading, !building, engine.hasDatabase else { return }
        engine.closeImages()
        loading = true
        failed = false
        noProgressExhausted = false
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
        indexedInCurrentBuild = 0
        noProgressExhausted = false
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

    private func finishBuild(succeeded: Bool) {
        if succeeded, indexedInCurrentBuild == 0, !limited {
            noProgressExhausted = true
        }
        if let onBuildFinished {
            onBuildFinished()
        } else {
            refresh()
        }
    }

    private func streamBuild(projector: URL, generation: Int) {
        let args = ["image-index", "--projector", projector.path, "--stream", "--max", "16"] + engine.gemmaOptions
        var sawBatch = false
        process = engine.run(args, onLine: { [weak self] line in
            guard let self, self.generation == generation,
                  let batch = try? JSONDecoder().decode(Batch.self, from: line) else { return }
            sawBatch = true
            self.indexedInCurrentBuild += batch.indexed
            self.checked += batch.indexed + batch.reused
            self.limited = batch.limited
        }, priority: .background) { [weak self] response in
            guard let self, self.generation == generation else { return }
            self.process = nil
            self.building = false
            let ok = response.succeeded && sawBatch
            if !ok {
                self.failed = true
            }
            self.finishBuild(succeeded: ok)
        }
        if let process { _ = setpriority(PRIO_PROCESS, UInt32(process.processIdentifier), 10) }
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
                self.finishBuild(succeeded: false)
                return
            }
            self.indexedInCurrentBuild += batch.indexed
            self.checked += batch.indexed + batch.reused
            self.limited = batch.limited
            if !batch.limited, let next = batch.next_after, next != cursor {
                self.batch(after: next, projector: projector, generation: generation)
            } else {
                self.building = false
                self.finishBuild(succeeded: true)
            }
        }
        if let process { _ = setpriority(PRIO_PROCESS, UInt32(process.processIdentifier), 10) }
    }
}

/// Image-embedding status inside the unified Semantic & Content Index card; folders come from `content_roots`.
struct LauncherImageSettings: View {
    @ObservedObject var launcher: Launcher
    @ObservedObject private var indexStatus: IndexStatusState
    @ObservedObject var images: LauncherImageSearch

    init(launcher: Launcher, images: LauncherImageSearch) {
        self.launcher = launcher
        _indexStatus = ObservedObject(wrappedValue: launcher.indexStatus)
        self.images = images
    }

    var body: some View {
        let coverage = indexStatus.imageCoverage
        let vectors = coverage?.enabled == true ? (coverage?.vectors ?? 0) : (images.scope?.vectors ?? coverage?.vectors ?? 0)
        let isLimited = coverage?.limited == true || images.limited
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(launcher.t("图像画面", "Image Pixels")) {
                if images.building {
                    Text(launcher.t("已处理 \(images.checked) 张", "Prepared \(images.checked) images"))
                } else if images.projector == nil {
                    Text(launcher.t("需要图像多模态模型", "Needs the image multimodal model")).foregroundStyle(.secondary)
                } else if let coverage, coverage.enabled, coverage.vectors > 0, coverage.pending, !isLimited {
                    Text(launcher.t("已索引 \(vectors) 张 · 后台队列待处理", "Indexed \(vectors) images · more pending"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(launcher.t("已索引 \(vectors) 张", "Indexed \(vectors) images"))
                        .foregroundStyle(.secondary)
                }
            }
            if images.failed { Text(launcher.t("图像索引失败。请检查目录和图像模型。", "Image indexing failed. Check the folders and image model, then retry.")).foregroundStyle(.secondary) }
            if let coverage, isLimited, coverage.vector_limit > 0 {
                Text(launcher.t("已达图像索引容量上限（\(coverage.vector_limit) 张）", "Image index limit reached (\(coverage.vector_limit) images)")).foregroundStyle(.secondary)
            } else if isLimited {
                Text(launcher.t("已达图像索引容量上限。", "The image index is at its storage limit.")).foregroundStyle(.secondary)
            }
        }
    }
}
