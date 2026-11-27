import AppKit
import SwiftUI

struct ExternalVolume: Decodable, Identifiable {
    let uuid: String
    let path: String
    let available: Bool
    let indexed: Bool
    let needs_refresh: Bool
    /// `"external"` or `"network"`; absent from older engines.
    let kind: String?
    let `protocol`: String?

    var id: String { uuid }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var isNetwork: Bool { kind == "network" }

    var protocolBadge: String? {
        switch `protocol`?.lowercased() {
        case "smb", "smbfs": return "SMB"
        case "nfs": return "NFS"
        case "afp", "afpfs": return "AFP"
        case "webdav": return "WebDAV"
        case let other?: return other.isEmpty ? nil : other.uppercased()
        case nil: return isNetwork ? "NET" : nil
        }
    }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(launcher.t(
                    "选择要搜索的外置卷或网络共享（SMB、NFS、AFP、WebDAV）。Lumen 只索引文件名，文件有变化时可手动更新。",
                    "Choose an external volume or network share (SMB, NFS, AFP, WebDAV) to search. Lumen indexes file names. Refresh the index when files change."
                ))
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    catalog.reload()
                } label: {
                    Label(launcher.t("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(LumenSecondaryButtonStyle())
                .disabled(catalog.refreshing || catalog.editing != nil)
                .accessibilityIdentifier("settings.external-volumes.refresh")
            }

            if !canIndex {
                Text(launcher.t("主索引就绪后可添加或更新外置卷。", "You can add or refresh volumes when the main index is ready."))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textTertiary)
            }
            if catalog.failed {
                Text(launcher.t("外置卷操作失败。请检查连接或系统授权，然后重试。", "The volume operation failed. Check the connection or system permissions and try again."))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.red)
            }

            LumenSettingsWell(padding: 10) {
                if catalog.volumes.isEmpty {
                    HStack(spacing: 8) {
                        if catalog.refreshing {
                            ProgressView().controlSize(.small)
                            Text(launcher.t("正在扫描外置卷…", "Scanning volumes…"))
                                .font(.system(size: 12))
                                .foregroundStyle(SettingsTheme.textSecondary)
                        } else {
                            Image(systemName: "externaldrive.badge.questionmark")
                                .foregroundStyle(SettingsTheme.textTertiary)
                                .accessibilityHidden(true)
                            Text(launcher.t("没有可用的外置卷或网络共享。", "No external volumes or network shares available."))
                                .font(.system(size: 12))
                                .foregroundStyle(SettingsTheme.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(catalog.volumes.enumerated()), id: \.element.id) { index, volume in
                            if index > 0 { LumenSettingsHairline() }
                            row(volume)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ volume: ExternalVolume) -> some View {
        HStack(spacing: 12) {
            Image(systemName: volume.isNetwork ? "externaldrive.connected.to.line.below" : "externaldrive")
                .foregroundStyle(volume.indexed ? SettingsTheme.amber : SettingsTheme.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SettingsTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(volume.path)
                    if let badge = volume.protocolBadge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(SettingsTheme.cardBackground, in: Capsule())
                            .foregroundStyle(SettingsTheme.textSecondary)
                    }
                }
                Text(label(volume))
                    .font(.system(size: 11.5))
                    .foregroundStyle(statusColor(volume))
            }
            Spacer(minLength: 8)
            if volume.available {
                Button(volume.indexed || volume.needs_refresh ? launcher.t("更新", "Refresh") : launcher.t("添加索引", "Add Index")) {
                    catalog.index(volume, changed: changed)
                }
                .buttonStyle(LumenSecondaryButtonStyle())
                .disabled(!canIndex || catalog.editing != nil || catalog.refreshing)
            }
            if volume.indexed || volume.needs_refresh {
                Button(launcher.t("移除索引", "Remove Index")) {
                    catalog.forget(volume, changed: changed)
                }
                .buttonStyle(LumenSecondaryButtonStyle())
                .disabled(catalog.editing != nil || catalog.refreshing)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ volume: ExternalVolume) -> Color {
        if catalog.editing == volume.id { return SettingsTheme.amber }
        if !volume.available { return SettingsTheme.textTertiary }
        if volume.indexed { return SettingsTheme.green }
        if volume.needs_refresh { return SettingsTheme.amber }
        return SettingsTheme.textSecondary
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
