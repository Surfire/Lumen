import AppKit
import SwiftUI

struct SearchWindow: View {
    @ObservedObject var model: Launcher
    let showSettings: () -> Void
    let open: (SearchHit) -> Void
    let revealInFinder: (SearchHit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.canSearch {
                HStack {
                    Picker(model.t("搜索方式", "Search mode"), selection: Binding(
                        get: { model.mode }, set: { model.changeMode($0) }
                    )) {
                        Text(model.t("名称与拼音", "Names & Pinyin")).tag(SearchMode.name)
                        Text(model.t("名称与正文", "Names & Text")).tag(SearchMode.all)
                        Text(model.t("正文", "Text")).tag(SearchMode.text)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 360)
                    Spacer()
                    Button(model.relatedExcerptsLabel) { model.semanticSearch() }
                        .disabled(!model.hasQuery || model.semanticBusy || model.localModelState == .checking)
                }
            }
            if let work = model.indexWork {
                ProgressView(work.label(model)).controlSize(.small)
            }
            if let notice = model.indexNotice {
                NoticeView(model: model, notice: notice)
            }
            if model.watchState == .needsSetup && model.indexPhase == .ready && !model.scopePending {
                Text(model.t("当前索引未保存完整范围。请在设置中重建索引以启用自动更新。",
                             "Rebuild this index in Settings to save its scope and enable automatic updates."))
                    .foregroundStyle(.secondary).font(.callout)
            }
            switch model.indexPhase {
            case .checking:
                ProgressView(model.t("正在检查本地索引…", "Checking the local index…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            case .needsIndex, .unreadable:
                onboarding
            case .ready:
                if model.canSearch {
                    results
                } else {
                    Text(model.indexWork == nil
                         ? model.t("请在设置中重新应用索引范围，以恢复搜索。",
                                   "Apply the index scope again in Settings to resume search.")
                         : model.t("索引范围更新完成后恢复搜索。", "Search resumes when the new scope is applied."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                if let shortcut = model.hotKey {
                    Label(shortcut.label, systemImage: "keyboard")
                        .accessibilityLabel(model.t("全局快捷键", "Global shortcut") + " " + shortcut.label)
                } else if let issue = model.hotKeyIssue {
                    Label(issue.title(model), systemImage: "exclamationmark.circle")
                }
                Spacer()
                Button(action: showSettings) {
                    Label(model.t("设置", "Settings"), systemImage: "gearshape")
                }
            }
            .font(.callout)
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "internaldrive").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(model.t("先建立本地搜索索引", "Build your local search index"))
                .font(.title2.weight(.semibold))
            Text(model.t("Lumen 默认扫描启动盘上可访问的文件和文件夹，无需选择目录。首次扫描完成后即可按名称和拼音搜索。",
                         "Lumen scans accessible files and folders on the startup disk by default. You can search by name and pinyin after the first scan."))
            Text(model.t("索引保存在本机。正文索引可在设置中开启，扫描不会下载云端文件。",
                         "The index stays on this Mac. You can enable text indexing in Settings. Scanning leaves cloud files online."))
                .foregroundStyle(.secondary)
            Button(model.indexPhase == .unreadable
                   ? model.t("重新建立索引", "Rebuild Index")
                   : model.t("建立索引", "Build Index")) {
                model.buildIndex()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("build-index")
            .disabled(model.indexWork != nil)
        }
        .frame(maxWidth: 500, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.localModelState == .checking {
                ProgressView(model.t("正在校验本机 BGE 资源…", "Verifying local BGE resources…")).controlSize(.small)
            } else if case .unavailable(let issue) = model.localModelState {
                Label(model.modelDiagnostic(issue), systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.semanticBusy || model.searching {
                ProgressView(model.semanticBusy
                             ? model.t("正在查找相关原文…", "Finding related excerpts…")
                             : model.t("正在搜索…", "Searching…")).controlSize(.small)
            }
            if model.showingRelatedExcerpts && !model.hits.isEmpty {
                Text(model.t("按语义相似度呈现本地文档片段，请结合原文判断。",
                             "These local excerpts are ranked by semantic similarity. Read the source for context."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let notice = model.searchNotice {
                HStack(alignment: .top) {
                    NoticeView(model: model, notice: notice)
                    if notice.problem == .search || notice.problem == .stale {
                        Button(model.t("重试", "Retry")) { model.retrySearch() }
                    }
                }
            }
            if model.hits.isEmpty {
                if model.searchNotice == nil && !model.searching && !model.semanticBusy {
                    Text(emptyResultsLabel)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selection) {
                        ForEach(model.hits) { hit in
                            resultRow(hit)
                                .tag(hit.path)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(hit) }
                        }
                    }
                    .listStyle(.plain)
                    .onKeyPress(.return) {
                        guard let hit = model.selectedHit else { return .ignored }
                        open(hit)
                        return .handled
                    }
                    .onChange(of: model.selection) { _, value in
                        if let value { proxy.scrollTo(value) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyResultsLabel: String {
        if model.showingRelatedExcerpts { return model.t("未找到相关原文", "No related excerpts") }
        if model.hasQuery { return model.t("没有匹配结果", "No matches") }
        return model.t("输入文件名、文件夹名称或拼音", "Enter a file or folder name, or its pinyin")
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: hit.kind == "directory" ? "folder" : "doc")
                    .accessibilityHidden(true)
                Text(hit.name).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(matchLabel(hit)).foregroundStyle(.secondary).font(.caption)
                if hit.isCloudReference {
                    Label(hit.availability == "placeholder"
                          ? model.t("仅在线 · 仅索引名称", "Online only · Name indexed")
                          : model.t("云盘 · 仅索引名称", "Cloud · Name indexed"), systemImage: "icloud")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.t("在 Finder 中显示", "Show in Finder")) { revealInFinder(hit) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("reveal-cloud-result")
                }
            }
            Text(hit.path).foregroundStyle(.secondary).font(.caption).lineLimit(1).truncationMode(.middle)
            if hit.hasPreview, let snippet = hit.snippet { Text(snippet).font(.caption).lineLimit(2) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func matchLabel(_ hit: SearchHit) -> String {
        switch hit.matched_by {
        case "semantic_candidate": return model.relatedExcerptsLabel
        case "pinyin": return model.t("拼音", "Pinyin")
        case "text": return model.t("正文", "Text")
        case "path": return model.t("路径", "Path")
        default: return model.t("名称", "Name")
        }
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
        button.toolTip = model.t("使用至少两个修饰键，包含 Control 或 Command。",
                                 "Use at least two modifiers, including Control or Command.")
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
        case .invalid: return model.t("请用至少两个修饰键（含 Control 或 Command）加字母、数字或空格。",
                                      "Use at least two modifiers, including Control or Command, with a letter, number or Space.")
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
