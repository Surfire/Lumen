import AppKit
import SwiftUI

struct ExternalVolume: Decodable, Identifiable {
    let uuid: String
    let path: String
    let available: Bool
    let indexed: Bool
    let needs_refresh: Bool

    var id: String { uuid }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor
final class ExternalVolumeCatalog: ObservableObject {
    @Published private(set) var volumes: [ExternalVolume] = []
    @Published private(set) var refreshing = false
    @Published private(set) var editing: String?
    @Published private(set) var progress: IndexProgress?
    @Published private(set) var failed = false
    private let engine: LauncherEngine
    private var reloadRevision = 0
    private var operation: Process?

    init(engine: LauncherEngine) { self.engine = engine }

    func reload(keepingFailure: Bool = false) {
        reloadRevision += 1
        let revision = reloadRevision
        refreshing = true
        if !keepingFailure { failed = false }
        _ = engine.run(["volumes"]) { [weak self] response in
            guard let self, self.reloadRevision == revision else { return }
            self.refreshing = false
            guard response.succeeded,
                  let volumes = try? JSONDecoder().decode([ExternalVolume].self, from: response.output)
            else {
                self.failed = true
                self.volumes = []
                return
            }
            self.volumes = volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func index(_ volume: ExternalVolume, changed: @escaping () -> Void) {
        guard volume.available else { return }
        execute(["index-volume", "--progress", "--uuid", volume.uuid, "--", volume.path],
                volume: volume, reportsProgress: true, changed: changed)
    }

    func forget(_ volume: ExternalVolume, changed: @escaping () -> Void) {
        execute(["forget-volume", "--", volume.uuid], volume: volume, reportsProgress: false, changed: changed)
    }

    private func execute(_ command: [String], volume: ExternalVolume, reportsProgress: Bool, changed: @escaping () -> Void) {
        guard editing == nil, !refreshing else { return }
        editing = volume.id
        progress = nil
        failed = false
        let report: (IndexProgress) -> Void = { [weak self] in self?.progress = $0 }
        operation = engine.run(command, onProgress: reportsProgress ? report : nil) { [weak self] response in
            guard let self else { return }
            self.operation = nil
            self.editing = nil
            self.progress = nil
            self.failed = !response.succeeded
            self.reload(keepingFailure: self.failed)
            changed()
        }
    }

    func stop() {
        if operation?.isRunning == true { operation?.terminate() }
    }
}

struct LauncherExternalVolumes: View {
    @ObservedObject var launcher: Launcher
    @ObservedObject var catalog: ExternalVolumeCatalog
    let changed: () -> Void

    private var canIndex: Bool {
        launcher.indexPhase == .ready && !launcher.scopePending && !launcher.isIndexing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(launcher.t(
                "选择要搜索的本机外置卷。Lumen 只索引文件名，文件有变化时可手动更新。",
                "Choose a local external volume to search. Lumen indexes file names. Refresh the index when files change."
            ))
            .foregroundStyle(.secondary)
            if !canIndex {
                Text(launcher.t("主索引就绪后可添加或更新外置卷。", "You can add or refresh volumes when the main index is ready."))
                    .foregroundStyle(.secondary)
            }
            if catalog.failed {
                Text(launcher.t("外置卷操作失败。请检查连接或系统授权，然后重试。", "The volume operation failed. Check the connection or system permissions and try again."))
                    .foregroundStyle(.red)
            }
            if catalog.volumes.isEmpty {
                if catalog.refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text(launcher.t("没有可用的外置卷。", "No external volumes available."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(catalog.volumes) { volume in row(volume) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 240)
    }

    private func row(_ volume: ExternalVolume) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name).lineLimit(1).truncationMode(.middle).help(volume.path)
                Text(label(volume)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if volume.available {
                Button(volume.indexed || volume.needs_refresh ? launcher.t("更新", "Refresh") : launcher.t("添加索引", "Add Index")) {
                    catalog.index(volume, changed: changed)
                }
                .disabled(!canIndex || catalog.editing != nil || catalog.refreshing)
            }
            if volume.indexed || volume.needs_refresh {
                Button(launcher.t("移除索引", "Remove Index")) {
                    catalog.forget(volume, changed: changed)
                }
                .disabled(catalog.editing != nil || catalog.refreshing)
            }
        }
    }

    private func label(_ volume: ExternalVolume) -> String {
        if catalog.editing == volume.id {
            if let progress = catalog.progress { return "\(launcher.t("已检查", "Checked")) \(progress.entries.formatted())" }
            return launcher.t("正在处理…", "Working…")
        }
        if !volume.available { return launcher.t("已断开", "Disconnected") }
        if volume.indexed { return launcher.t("可搜索", "Searchable") }
        if volume.needs_refresh { return launcher.t("需要更新", "Refresh needed") }
        return launcher.t("未加入搜索", "Available to add")
    }
}
