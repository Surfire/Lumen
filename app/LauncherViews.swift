import AppKit
import SwiftUI

struct SearchWindow: View {
    @ObservedObject var model: Launcher
    let showSettings: () -> Void
    let beginIndex: () -> Void
    let open: (SearchHit) -> Void
    let revealInFinder: (SearchHit) -> Void

    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 28
    static let maximumVisibleRows = 8

    static func height(for model: Launcher) -> CGFloat {
        let shell = headerHeight + footerHeight
        return model.canSearch && model.hasQuery ? shell + CGFloat(maximumVisibleRows * 44) : shell
    }

    private static func rowHeight(_ hit: SearchHit) -> CGFloat { hit.hasPreview ? 60 : 44 }

    var body: some View {
        VStack(spacing: 0) {
            if model.canSearch && model.hasQuery {
                results.overlay {
                    if model.hits.isEmpty {
                        Text(emptyResultsLabel)
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.canSearch && model.hasQuery {
                keyHint("↑↓", model.t("选择", "Select"))
                keyHint("↵", model.t("打开", "Open"))
                keyHint("⌘↵", model.t("在 Finder 中显示", "Show in Finder"))
            } else if model.activityBusy || !model.canSearch {
                Label(model.activityTitle, systemImage: model.activityBusy ? "arrow.triangle.2.circlepath" : "internaldrive")
                    .lineLimit(1)
                if let metrics = model.activityMetrics { Text(metrics).monospacedDigit().lineLimit(1) }
            } else {
                Text(model.activityTitle).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.canStartIndexFromLauncher {
                Button(model.t("在后台建立索引", "Build in Background"), action: beginIndex)
                    .buttonStyle(.borderless).fontWeight(.semibold)
                    .accessibilityIdentifier("build-index")
            } else {
                keyHint("esc", model.t("关闭", "Close"))
            }
            Button(action: showSettings) {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.t("设置", "Settings"))
            .help(model.t("设置与索引详情", "Settings and index details"))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .frame(height: Self.footerHeight)
        .background(.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 3))
            Text(action)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.hits) { hit in
                        resultRow(hit).id(hit.path)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: model.selection) { _, value in
                if let value { proxy.scrollTo(value) }
            }
            .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
            .onKeyPress(keys: [.return]) { press in
                guard press.modifiers.isEmpty, let hit = model.selectedHit else { return .ignored }
                open(hit)
                return .handled
            }
        }
    }

    private var emptyResultsLabel: String {
        if let notice = model.searchNotice { return model.title(for: notice) }
        if model.searching || model.semanticBusy {
            return model.t("正在搜索…", "Searching…")
        }
        return model.t("没有匹配结果", "No matches")
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        let selected = model.selection == hit.path
        return HStack(spacing: 10) {
            Image(systemName: hit.kind == "directory" ? "folder" : "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                let parent = (hit.path as NSString).deletingLastPathComponent as NSString
                Text(parent.abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(hit.path)
                if hit.hasPreview, let snippet = hit.snippet {
                    Text(snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hit.isCloudReference {
                Label(hit.availability == "placeholder"
                      ? model.t("仅在线", "Online only")
                      : model.t("云盘 · 仅名称", "Cloud · Name only"), systemImage: "icloud")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                Button(model.t("在 Finder 中显示", "Show in Finder")) { revealInFinder(hit) }
                    .buttonStyle(.borderless).font(.caption).fixedSize()
                    .accessibilityIdentifier("reveal-cloud-result")
            } else if hit.isSemanticCandidate {
                Text(model.relatedExcerptsLabel).font(.caption).foregroundStyle(.secondary).fixedSize()
            } else if selected {
                Image(systemName: "return").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight(hit))
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15))
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(hit) }
        .onTapGesture { model.selection = hit.path }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(model.t("打开", "Open"))) { open(hit) }
        .accessibilityAction(named: Text(model.t("在 Finder 中显示", "Show in Finder"))) { revealInFinder(hit) }
    }

}

@MainActor
extension Launcher {
    var canStartIndexFromLauncher: Bool {
        indexWork == nil && (indexPhase == .needsIndex || indexPhase == .unreadable || scopePending ||
                             (indexPhase == .ready && watchState == .needsSetup))
    }

    var activityTitle: String {
        if isIndexing || watchProgress != nil || watchState == .starting {
            switch activeProgress?.phase {
            case "preparing": return t("正在准备索引…", "Preparing index…")
            case "finalizing", "done": return t("正在保存索引…", "Saving index…")
            case "scanning": return t("正在扫描文件…", "Scanning files…")
            default: return t("正在后台更新索引…", "Indexing in background…")
            }
        }
        if indexWork == .embeddings { return t("正在生成语义索引…", "Building semantic index…") }
        if scopePending || indexPhase == .unreadable { return t("索引需要更新", "Index needs attention") }
        switch indexPhase {
        case .checking: return t("正在检查索引…", "Checking index…")
        case .needsIndex: return t("索引启动盘上的可访问文件", "Index accessible files on this Mac")
        case .ready, .unreadable:
            if watchState == .running { return t("实时更新", "Live updates") }
            if watchState == .failed { return t("自动更新已停止", "Automatic updates stopped") }
            if watchState == .needsSetup { return t("重建后可开启实时更新", "Rebuild to enable live updates") }
            return t("索引就绪", "Index ready")
        }
    }

    var activityMetrics: String? {
        guard let progress = activeProgress else { return nil }
        let elapsed = durationText(Double(progress.elapsed_ms) / 1_000)
        let entries = progress.entries.formatted()
        let eta = progress.eta.map {
            let duration = durationText($0)
            return t("约余 \(duration)", "About \(duration) left")
        } ?? t("剩余时间待估", "ETA unavailable")
        return t("\(entries) 项 · 已用 \(elapsed) · \(eta)", "\(entries) entries · \(elapsed) elapsed · \(eta)")
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds],
                                                            width: .abbreviated, maximumUnitCount: 2)
            .locale(zh ? Locale(identifier: "zh-Hans") : Locale(identifier: "en")))
    }
}

struct LauncherSettings: View {
    @ObservedObject var model: Launcher
    let recordShortcut: (NSEvent) -> Void
    let disableShortcut: () -> Void

    var body: some View {
        Form {
            Section(model.t("常规", "General")) {
                Picker(model.t("界面语言", "Interface language"), selection: $model.language) {
                    Text(model.t("跟随系统", "System")).tag("system")
                    Text("简体中文").tag("zh")
                    Text("English").tag("en")
                }
                LabeledContent(model.t("全局快捷键", "Global shortcut")) {
                    HStack {
                        Text(model.hotKey?.label ?? model.t("未设置", "Off")).monospaced()
                        ShortcutControl(model: model, record: recordShortcut)
                            .fixedSize()
                        Button(model.t("停用", "Disable"), action: disableShortcut)
                            .disabled(model.hotKey == nil && model.hotKeyIssue == nil)
                    }
                }
                if let issue = model.hotKeyIssue {
                    Label(issue.title(model), systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.hotKey?.cyclesMacWindows == true {
                    Text(model.t("macOS 也使用 ⌘` 切换窗口。可随时在菜单栏中打开 Lumen 搜索。",
                                 "macOS also uses ⌘` to cycle windows. Open Search is always available in the Lumen menu bar item."))
                        .font(.callout).foregroundStyle(.secondary)
                } else if model.hotKeyIssue != nil {
                    Text(model.t("仍可从菜单栏打开搜索。", "You can still open Search from the Lumen menu bar item."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section(model.t("本地索引", "Local Index")) {
                Toggle(model.t("索引本地 TXT、Markdown、DOCX 和 PDF 文本层", "Index local TXT, Markdown, DOCX and PDF text"),
                       isOn: $model.scope.documents)
                DisclosureGroup(model.t("自定义索引范围", "Customize Index Scope")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.t("留空时使用启动盘的可访问范围。每行填写一个绝对路径，排除优先。",
                                     "Leave the fields blank to use accessible locations on the startup disk. Enter one absolute path per line. Exclusions take priority."))
                            .foregroundStyle(.secondary)
                        pathEditor(model.t("仅包括", "Include Only"), text: $model.scope.allow)
                        pathEditor(model.t("排除", "Exclude"), text: $model.scope.deny)
                    }
                    .padding(.vertical, 6)
                }
                Button(model.indexPhase == .ready ? model.t("应用设置并更新索引", "Apply Settings and Update Index")
                       : model.t("建立索引", "Build Index")) { model.buildIndex() }
                    .disabled(model.indexWork != nil || model.indexPhase == .checking)
                if let work = model.indexWork { ProgressView(work.label(model)).controlSize(.small) }
                if let progress = model.activeProgress, let metrics = model.activityMetrics {
                    if let fraction = progress.fraction {
                        ProgressView(metrics, value: fraction)
                    } else {
                        Text(metrics).font(.callout).monospacedDigit()
                    }
                }
                if let report = model.indexReport { scanCounts(report) }
                Text(watchLabel).foregroundStyle(.secondary)
                if let notice = model.watchNotice { NoticeView(model: model, notice: notice) }
                if let notice = model.indexNotice { NoticeView(model: model, notice: notice) }
            }
            Section(model.t("离线 BGE 语义模型", "Offline BGE Model")) {
                Picker(model.t("模型语言", "Model language"), selection: $model.semanticLanguage) {
                    Text("简体中文").tag("zh")
                    Text("English").tag("en")
                }
                Button(model.t("检查本机模型", "Check Local Model")) { model.verifyLocalModel() }
                    .disabled(model.localModelState == .checking || model.indexWork == .embeddings)
                localModelStatus
                embeddingControls
                if let notice = model.embeddingNotice { NoticeView(model: model, notice: notice) }
                if let batch = model.embeddingBatch {
                    let count = batch.new_embeddings.formatted()
                    Text(model.t("本批新增 \(count) 段语义索引。", "This batch indexed \(count) chunks."))
                    if batch.skipped_chunks > 0 {
                        let skipped = batch.skipped_chunks.formatted()
                        Text(model.t("本批跳过 \(skipped) 段。", "This batch skipped \(skipped) chunks."))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var embeddingControls: some View {
        switch model.embeddingState {
        case .verifying, .running, .pausing:
            Button(model.t("暂停生成", "Pause Indexing")) { model.pauseEmbeddings() }
                .disabled(model.embeddingState == .pausing)
            if model.embeddingState == .pausing {
                Text(model.t("正在完成当前批次，随后暂停。", "Indexing will pause after the current batch."))
                    .foregroundStyle(.secondary)
            }
        case .idle, .paused, .finished:
            Button(model.embeddingState == .paused
                   ? model.t("继续生成语义索引", "Resume Semantic Indexing")
                   : model.t("生成语义索引", "Build Semantic Index")) {
                model.buildEmbeddings()
            }
            .disabled(!model.canBuildEmbeddings)
            if model.embeddingState == .paused && model.embeddingNotice == nil {
                Text(model.t("已暂停。已完成的片段已保存，可以继续生成。",
                             "Indexing is paused. Completed chunks are saved and indexing can resume."))
                    .foregroundStyle(.secondary)
            } else if model.embeddingState == .finished {
                Text(model.t("本轮语义索引生成已结束。", "This semantic indexing run has finished."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var localModelStatus: some View {
        switch model.localModelState {
        case .unchecked:
            EmptyView()
        case .checking:
            ProgressView(model.t("正在校验本机 BGE 资源…", "Verifying local BGE resources…")).controlSize(.small)
        case .ready:
            Label(model.t("本机模型已校验", "Local model verified"), systemImage: "checkmark.circle")
        case .unavailable(let issue):
            Label(model.modelDiagnostic(issue), systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func pathEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.callout)
            TextEditor(text: text)
                .font(.body.monospaced())
                .frame(height: 52)
                .accessibilityLabel(title)
        }
    }

    private func scanCounts(_ report: IndexReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t("上次扫描已索引 \(report.items.formatted()) 个项目",
                         "\(report.items.formatted()) items indexed as of the last scan"))
            if let count = report.entries_unreadable, count > 0 {
                Text(model.t("无法访问 \(count.formatted()) 个项目", "\(count.formatted()) entries could not be accessed"))
            }
            if let count = report.placeholders, count > 0 {
                Text(model.t("\(count.formatted()) 个云端占位项目", "\(count.formatted()) cloud placeholders"))
            }
            if let count = report.documents, count > 0 {
                Text(model.t("已索引 \(count.formatted()) 份文档的正文", "Text indexed for \(count.formatted()) documents"))
            }
            if let count = report.documents_not_read, count > 0 {
                Text(model.t("\(count.formatted()) 份文档未读取正文", "Text was unavailable for \(count.formatted()) documents"))
            }
        }.font(.callout)
    }

    private var watchLabel: String {
        switch model.watchState {
        case .checking: return model.t("正在检查自动更新支持…", "Checking automatic update support…")
        case .unavailable: return model.t("当前版本请手动更新索引。", "Use manual index updates in this version.")
        case .needsSetup: return model.t("请重建索引以保存范围并启用自动更新。", "Rebuild the index to save its scope and enable automatic updates.")
        case .paused: return model.t("索引范围应用成功后恢复自动更新。", "Automatic updates resume after the scope is applied.")
        case .starting: return model.t("正在检查文件变化并启动自动更新…", "Checking for changes and starting automatic updates…")
        case .running: return model.t("自动更新进程已启动。", "The automatic update process is running.")
        case .failed: return model.t("自动更新当前未运行。", "Automatic updates are currently stopped.")
        }
    }
}

private struct NoticeView: View {
    @ObservedObject var model: Launcher
    let notice: LauncherNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(model.title(for: notice), systemImage: "info.circle")
            if !notice.detail.isEmpty {
                DisclosureGroup(model.t("技术详情", "Technical Details")) {
                    Text(notice.detail).font(.caption.monospaced()).textSelection(.enabled).lineLimit(5)
                }
            }
        }.font(.callout)
    }
}

private struct ShortcutControl: NSViewRepresentable {
    @ObservedObject var model: Launcher
    let record: (NSEvent) -> Void

    func makeNSView(context: Context) -> HotKeyRecorder {
        let button = HotKeyRecorder(title: "", target: context.coordinator, action: #selector(Coordinator.begin(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ button: HotKeyRecorder, context: Context) {
        let title = model.t("录制…", "Record…")
        let prompt = model.t("按下组合键（Esc 取消）", "Press Shortcut (Esc Cancels)")
        if !button.recording { button.title = title }
        button.toolTip = model.t("按一个含 ⌘、⌃ 或 ⌥ 的组合键。",
                                 "Press a shortcut that includes Command, Control, or Option.")
        button.stopRecording = { [weak button] in
            button?.recording = false
            button?.title = title
        }
        button.record = { [weak button] event in
            button?.stopRecording?()
            record(event)
        }
        context.coordinator.prompt = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var prompt = ""
        @objc func begin(_ button: HotKeyRecorder) {
            if button.recording { button.stopRecording?(); return }
            guard button.window?.makeFirstResponder(button) == true else { return }
            button.recording = true
            button.title = prompt
        }
    }
}

@MainActor
private extension IndexWork {
    func label(_ model: Launcher) -> String {
        switch self {
        case .names: return model.t("正在建立名称与拼音索引…", "Indexing names and pinyin…")
        case .documents: return model.t("正在建立文档正文索引…", "Indexing document text…")
        case .embeddings: return model.t("正在生成本机语义索引…", "Preparing local semantic embeddings…")
        }
    }
}

@MainActor
private extension HotKeyIssue {
    func title(_ model: Launcher) -> String {
        switch self {
        case .invalid: return model.t("请将 ⌘、⌃ 或 ⌥ 与字母、数字、符号或空格组合。",
                                      "Combine Command, Control, or Option with a letter, number, symbol, or Space.")
        case .system: return model.t("此快捷键由 macOS 保留。请录制其他组合。",
                                     "macOS reserves this shortcut. Choose another combination.")
        case .occupied: return model.t("此快捷键已被注册。请录制其他组合。",
                                       "This shortcut is already registered. Choose another combination.")
        case .registration(let status):
            return model.t("无法注册快捷键（系统状态 \(status)）。",
                           "Could not register the shortcut (system status \(status)).")
        }
    }
}
