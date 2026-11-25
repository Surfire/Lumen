import SwiftUI

struct ImageSearchScope: Decodable {
    let root: String?
    let vectors: Int
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
    private var readAttempted = false
    private var process: Process?
    private var generation = 0

    init(engine: LauncherEngine, defaults: UserDefaults?) {
        self.engine = engine
        self.defaults = defaults
        projector = defaults?.string(forKey: "launcher.imageProjector.v1").map { URL(fileURLWithPath: $0) }
    }

    var readyProjector: URL? { !loading && scope?.root != nil && (scope?.vectors ?? 0) > 0 ? projector : nil }

    func ensureStatus() {
        guard !readAttempted else { return }
        readAttempted = true
        refresh()
    }

    private func refresh() {
        guard engine.hasDatabase, !loading else { return }
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
        guard let projector, scope?.root != nil, !loading, !building else { return }
        generation += 1
        building = true
        checked = 0
        limited = false
        failed = false
        batch(after: nil, projector: projector, generation: generation)
    }

    func stop(refreshStatus: Bool = true) {
        guard building else { return }
        generation += 1
        if process?.isRunning == true { process?.terminate() }
        process = nil
        building = false
        if refreshStatus { refresh() }
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

struct LauncherImageSettings: View {
    @ObservedObject var launcher: Launcher
    @ObservedObject var images: LauncherImageSearch
    let chooseFolder: () -> Void
    let chooseProjector: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(launcher.t("仅在所选本地目录为 PNG 和 JPEG 建立画面索引。输入「img 画面描述」搜索。",
                            "Index PNG and JPEG pixels in one local folder. Search with “img description”."))
                .foregroundStyle(.secondary)
            LabeledContent(launcher.t("目录", "Folder")) {
                if let root = images.scope?.root {
                    Text((root as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(launcher.t("未选择", "Not selected")).foregroundStyle(.secondary)
                }
            }
            LabeledContent(launcher.t("本地图像投影器", "Local Image Projector")) {
                Text(images.projector?.lastPathComponent ?? launcher.t("未选择", "Not selected"))
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button(launcher.t("选目录…", "Choose Folder…"), action: chooseFolder)
                Button(launcher.t("选投影器…", "Choose Projector…"), action: chooseProjector)
                if images.scope?.root != nil {
                    Button(launcher.t("移除", "Remove")) { images.setFolder(nil) }
                }
            }
            .disabled(images.loading || images.building || !launcher.canSearch || launcher.scopePending)
            HStack {
                if images.building {
                    ProgressView().controlSize(.small)
                    Text(launcher.t("已处理 \(images.checked) 张", "Prepared \(images.checked) images"))
                    Button(launcher.t("停止", "Stop")) { images.stop() }
                } else {
                    Text(launcher.t("已索引 \(images.scope?.vectors ?? 0) 张", "Indexed \(images.scope?.vectors ?? 0) images"))
                        .foregroundStyle(.secondary)
                    Button(launcher.t("建立或刷新图像索引", "Build or Refresh Image Index")) { images.build() }
                        .disabled(images.scope?.root == nil || images.projector == nil || images.loading ||
                                  !launcher.canSearch || launcher.scopePending || launcher.indexWork != nil)
                }
            }
            if images.failed { Text(launcher.t("操作失败。检查目录、模型和投影器。", "Check the folder, model, and projector, then retry.")).foregroundStyle(.secondary) }
            if images.limited { Text(launcher.t("已达图像索引容量上限。", "The image index is at its storage limit.")).foregroundStyle(.secondary) }
        }
    }
}
