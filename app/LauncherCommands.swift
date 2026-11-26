import AppKit
import SwiftUI

@MainActor
final class LauncherCommands: ObservableObject {
    @Published private(set) var resolution: LumenCommandResolution = .search
    @Published private(set) var entries: [LumenCommandCatalog.Entry] = []
    @Published private(set) var selection = 0
    @Published private(set) var clipboardRows: [ClipboardItem] = []
    @Published private(set) var clipboardSelection: Int64?
    @Published private(set) var answer: LumenQuickAnswer.State = .idle
    @Published private var partialAnswer = ""
    @Published private(set) var copied = false
    @Published private(set) var webFailed = false
    @Published private(set) var answerPage = 0
    @Published private(set) var executableMatches: [ActionMatch] = []
    @Published private var selectedExecutableID: String?
    @Published private var manuallySelected = false
    @Published private(set) var execution: CommandExecution?
    @Published var executionArgument = ""
    @Published private(set) var outputCopied = false
    @Published private(set) var outputPage = 0
    private var executionTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private(set) var raw = ""
    private lazy var request: LumenQuickAnswer = {
        let request = LumenQuickAnswer()
        request.onChange = { [weak self] state in
            guard let self else { return }
            self.answer = state
            if !self.partialAnswer.isEmpty { self.partialAnswer = "" }
        }
        return request
    }()

    var isImageCommand: Bool { if case .image = resolution { return true }; return false }
    var isClipboardCommand: Bool { if case .clipboard = resolution { return true }; return false }
    var selectedClipboardItem: ClipboardItem? { clipboardRows.first { $0.id == clipboardSelection } }
    var showsCard: Bool { resolution != .search && resolution != .translation && !isImageCommand }
    var selectedEntry: LumenCommandCatalog.Entry? { entries.indices.contains(selection) ? entries[selection] : nil }

    func update(_ next: LumenCommandResolution, raw: String, catalog: LumenCommandCatalog) {
        if next == .discovery {
            let available = catalog.entries.filter { $0.commandID != "discover" }
            if entries != available { entries = available }
        }
        guard next != resolution || self.raw != raw else { return }
        self.raw = raw
        invalidateAnswer()
        if selection != 0 { selection = 0 }
        if webFailed { webFailed = false }
        if resolution != next { resolution = next }
    }

    func matchExecutables(_ actions: [LaunchAction], resetSelection: Bool = false) {
        let matches = resolution == .search && !actions.isEmpty && !LauncherFileQuery(raw).isFiltered
            ? LaunchCatalog.matches(raw, actions: actions, includeDictionary: false) : []
        if matches != executableMatches { executableMatches = matches }
        if resetSelection || !matches.contains(where: { $0.action.id == selectedExecutableID }) {
            if selectedExecutableID != nil { selectedExecutableID = nil }
            if resetSelection && manuallySelected { manuallySelected = false }
        }
    }

    // Merge opt-in commands here without adding I/O or catalog state to file search.
    func results(in model: Launcher) -> [LauncherResult] {
        var rows = model.visibleResults
        guard !executableMatches.isEmpty else { return rows }
        let native = Dictionary(uniqueKeysWithValues: model.launchMatches.map { ($0.action.id, $0.score) })
        let links = Dictionary(uniqueKeysWithValues: model.shortcuts.matches(model.query).map { ($0.record.rowID, $0.score) })
        func score(_ row: LauncherResult) -> Int {
            switch row {
            case .file: return 79
            case .calculation: return .max
            case .shortcut: return links[row.id] ?? 0
            case .action: return native[row.id] ?? .max // Already inserted opt-in command.
            }
        }
        for match in executableMatches {
            let insertion = rows.firstIndex { score($0) < match.score } ?? rows.firstIndex {
                // Keep partial commands accessible without interleaving file matches.
                if case .file = $0 { return match.score >= 55 }
                return false
            } ?? rows.endIndex
            rows.insert(.action(match.action), at: insertion)
        }
        return rows
    }

    func selection(in model: Launcher) -> String? {
        if let selectedExecutableID { return selectedExecutableID }
        guard !manuallySelected, executableMatches.first?.primary == true,
              let first = results(in: model).first, first.id == executableMatches.first?.action.id else { return model.selection }
        return first.id
    }

    func selectedResult(in model: Launcher) -> LauncherResult? {
        let id = selection(in: model)
        return executableMatches.first { $0.action.id == id }.map { .action($0.action) } ?? model.selectedResult
    }

    func choose(_ row: LauncherResult, in model: Launcher) {
        if !manuallySelected { manuallySelected = true }
        if case .action(let action) = row, case .executable = action.destination {
            selectedExecutableID = row.id
        } else {
            selectedExecutableID = nil
            model.selection = row.id
        }
    }

    func moveResults(_ delta: Int, in model: Launcher) {
        guard !executableMatches.isEmpty else { model.moveSelection(delta); return }
        let rows = results(in: model)
        guard let first = rows.first, let last = rows.last else { return }
        let id = selection(in: model)
        if let index = rows.firstIndex(where: { $0.id == id }) {
            choose(rows[min(max(0, index + delta), rows.count - 1)], in: model)
        } else {
            choose(delta > 0 ? first : last, in: model)
        }
    }

    var visibleExecution: CommandExecution? {
        guard let execution else { return nil }
        if case .argument = execution.phase { return execution }
        return execution.command.mode == .silent ? nil : execution
    }

    func prompt(_ command: LauncherExecutable, placeholder: String, required: Bool) {
        guard executionTask == nil else { return }
        feedbackTask?.cancel()
        executionArgument = ""
        outputCopied = false
        outputPage = 0
        execution = .init(command: command, phase: .argument(placeholder, required: required))
    }

    func run(_ command: LauncherExecutable, argument: String?, catalog: LauncherScriptCatalog) {
        guard executionTask == nil, catalog.contains(command) else { return }
        feedbackTask?.cancel()
        executionArgument = ""
        outputCopied = false
        outputPage = 0
        execution = .init(command: command, phase: .running)
        let shortcuts = catalog.shortcutsExecutable
        executionTask = Task { [weak self] in
            let result = await LauncherProcess.execute(command, argument: argument, shortcuts: shortcuts)
            guard let self else { return }
            self.executionTask = nil
            guard !Task.isCancelled else { return }
            self.execution = .init(command: command, phase: .finished(result))
            if command.mode == .silent {
                self.feedbackTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { self?.execution = nil }
                }
            }
        }
    }

    var canStartExecutable: Bool { executionTask == nil }

    @discardableResult func cancelExecution() -> Task<Void, Never>? {
        executionTask?.cancel()
        feedbackTask?.cancel()
        execution = nil
        executionArgument = ""
        return executionTask
    }

    func copyOutput(to pasteboard: NSPasteboard) {
        guard let output = visibleExecution?.output, !output.isEmpty else { return }
        outputCopied = ClipboardManager.writeInternalString(output, to: pasteboard)
    }

    func updateClipboard(_ items: [ClipboardItem], resetSelection: Bool = false) {
        let rows: [ClipboardItem]
        if case .clipboard(let filter) = resolution { rows = ClipboardItem.filtered(items, for: filter) }
        else { rows = [] }
        if clipboardRows != rows { clipboardRows = rows }
        if resetSelection || selectedClipboardItem == nil {
            if clipboardSelection != rows.first?.id { clipboardSelection = rows.first?.id }
        }
    }

    func chooseClipboard(_ id: Int64) {
        if clipboardRows.contains(where: { $0.id == id }) { clipboardSelection = id }
    }

    func moveClipboard(_ delta: Int) {
        guard let index = clipboardRows.firstIndex(where: { $0.id == clipboardSelection }) else { return }
        chooseClipboard(clipboardRows[min(max(0, index + delta), clipboardRows.count - 1)].id)
    }

    func move(_ delta: Int) { selection = min(max(0, selection + delta), max(0, entries.count - 1)) }
    func choose(_ index: Int) { if entries.indices.contains(index) { selection = index } }
    func submit(_ question: String, using ask: @escaping TranslationPanelModel.StreamingAnswer) {
        request.submit(question: question) { [weak self] input in
            try await ask(input) { [weak self] delta in
                guard !Task.isCancelled else { return }
                self?.partialAnswer += delta
            }
        }
    }

    var answerText: String {
        if case .answer(let output) = answer { return output }
        return partialAnswer
    }

    func pageAnswer(_ delta: Int) -> Bool {
        if let execution = visibleExecution, execution.command.mode == .fullOutput, execution.hasOutput {
            outputPage += delta
            return true
        }
        guard !answerText.isEmpty else { return false }
        answerPage += delta
        return true
    }

    func invalidateAnswer() {
        if answer != .idle { request.invalidate() }
        if copied { copied = false }
        if answerPage != 0 { answerPage = 0 }
    }
    func noteCopied() { copied = true }
    func recordWebFailure() { webFailed = true }
}

struct CommandExecution {
    enum Phase { case argument(String, required: Bool), running, finished(LauncherProcess.Result) }
    let command: LauncherExecutable
    let phase: Phase

    var output: String {
        if case .finished(let result) = phase { return result.output }
        return ""
    }

    var hasOutput: Bool {
        if case .finished(let result) = phase { return !result.stdout.bytes.isEmpty || !result.stderr.bytes.isEmpty }
        return false
    }

    var running: Bool { if case .running = phase { return true }; return false }

    func status(chinese: Bool) -> String {
        switch phase {
        case .argument: return chinese ? "准备运行" : "Ready to Run"
        case .running: return chinese ? "正在运行…" : "Running…"
        case .finished(let result):
            switch result.status {
            case .exited(0): return chinese ? "已完成" : "Completed"
            case .exited(let code): return chinese ? "退出码：\(code)" : "Exit code: \(code)"
            case .timedOut: return chinese ? "已超时（15 秒）" : "Timed out (15 seconds)"
            case .cancelled: return chinese ? "已取消" : "Cancelled"
            case .unavailable:
                return chinese ? "无法运行。请检查文件或重新载入命令。" : "Could not run. Check the file or reload commands."
            }
        }
    }
}

@MainActor
struct LauncherCommandOutputCard: View {
    @ObservedObject var commands: LauncherCommands
    let execution: CommandExecution
    let chinese: Bool
    let run: () -> Void
    let copy: () -> Void
    let cancel: () -> Void
    @FocusState private var argumentFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(execution.command.title, systemImage: execution.command.action.symbol)
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                if execution.running {
                    ProgressView().controlSize(.small)
                    Button(t("取消", "Cancel"), action: cancel)
                } else if execution.hasOutput {
                    Button(commands.outputCopied ? t("已复制", "Copied") : t("复制输出", "Copy Output"), action: copy)
                        .accessibilityIdentifier("command-copy-output")
                }
            }
            if case .argument(let placeholder, let required) = execution.phase {
                HStack {
                    TextField(placeholder, text: $commands.executionArgument)
                        .accessibilityIdentifier("command-argument").focused($argumentFocused)
                        .onAppear { argumentFocused = true }
                        .onSubmit(run)
                    Button(t("运行", "Run"), action: run)
                        .disabled(required && commands.executionArgument.isEmpty)
                        .accessibilityIdentifier("command-run")
                }
                if !required { Text(t("留空则不传入参数。", "Leave empty to run without an argument.")).foregroundStyle(.secondary) }
            } else {
                Text(execution.status(chinese: chinese)).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).accessibilityIdentifier("command-output-status")
                if execution.hasOutput {
                    if execution.command.mode == .fullOutput {
                        LauncherScrollableText(text: execution.output, label: t("命令输出", "Command Output"),
                                               identifier: "command-output-scroll", page: commands.outputPage)
                    } else {
                        Text(execution.output.prefix(300).split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                            .font(.callout.monospaced()).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

@MainActor
struct LauncherCommandCard: View {
    @ObservedObject var commands: LauncherCommands
    @ObservedObject var provider: TranslationPanelModel
    let chinese: Bool
    let activate: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if commands.resolution == .discovery { discovery }
            else {
                HStack {
                    Label(title, systemImage: symbol).font(.headline)
                    Spacer(minLength: 8)
                    if commands.answer == .loading {
                        ProgressView().controlSize(.small)
                        Button(t("取消", "Cancel"), action: commands.invalidateAnswer)
                    } else if canActivate {
                        Button(actionTitle, action: activate).accessibilityIdentifier("launcher-command-action")
                    }
                }
                if !commands.answerText.isEmpty {
                    LauncherScrollableText(text: commands.answerText, label: t("模型回答", "Model Answer"),
                                           identifier: "qa-answer-scroll", page: commands.answerPage)
                } else {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .question = commands.resolution {
                        if provider.answerWithSavedProvider() == nil {
                            Button(t("配置提供商…", "Configure Provider…"), action: openSettings)
                        } else if commands.answer == .failed {
                            Button(t("检查提供商设置…", "Check Provider Settings…"), action: openSettings)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var discovery: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(commands.entries.enumerated()), id: \.element.commandID) { index, item in
                        Button {
                            commands.choose(index)
                            activate()
                        } label: {
                            HStack(spacing: 10) {
                                Text(item.keyword).font(.body.monospaced()).lineLimit(1)
                                    .truncationMode(.middle).frame(width: 105, alignment: .leading)
                                    .help(item.keyword)
                                Text(entryTitle(item)).lineLimit(1)
                                Spacer()
                                if let host = item.destinationHost { Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .padding(.horizontal, 8).frame(height: 29)
                            .background(commands.selection == index ? Color.accentColor.opacity(0.17) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(commands.selection == index ? .isSelected : [])
                        .id(index)
                    }
                }
            }
            .onChange(of: commands.selection) { _, index in scroll.scrollTo(index) }
        }
    }

    func entryTitle(_ item: LumenCommandCatalog.Entry) -> String {
        localizedTitle(item.commandID, fallback: item.title)
    }

    private func localizedTitle(_ id: String, fallback: String) -> String {
        switch id {
        case "discover": return t("命令列表", "Browse Commands")
        case "qa": return t("问模型", "Ask Model")
        case "translate": return t("翻译", "Translate")
        case "google": return t("搜索 Google", fallback)
        case "github": return t("搜索 GitHub", fallback)
        case "wikipedia": return t("搜索维基百科", fallback)
        case "maps": return t("搜索 Google 地图", fallback)
        case "img": return t("按画面搜索图片", "Search Images by Description")
        case "clipboard": return t("剪贴板历史", "Clipboard History")
        default: return fallback
        }
    }

    var title: String {
        switch commands.resolution {
        case .question: return t("问模型", "Ask Model")
        case .web(let id, let title, _): return localizedTitle(id, fallback: title)
        default: return t("启动器命令", "Launcher Command")
        }
    }

    private var symbol: String {
        if case .question = commands.resolution { return "text.bubble" }
        return "globe"
    }

    private var canActivate: Bool {
        switch commands.resolution {
        case .web: return true
        case .question: return provider.answerWithSavedProvider() != nil
        default: return false
        }
    }

    private var actionTitle: String {
        if case .answer = commands.answer { return t("复制", "Copy") }
        if case .web = commands.resolution { return t("在浏览器中打开", "Open in Browser") }
        if commands.answer == .failed { return t("重试", "Retry") }
        return t("发送", "Send")
    }

    private var message: String {
        switch commands.resolution {
        case .question:
            if commands.answer == .failed {
                return t("请求失败。检查模型和服务设置后可重试。", "Request failed. Check the model and provider settings, then retry.")
            }
            guard let active = provider.provider, provider.answerWithSavedProvider() != nil,
                  let endpoint = try? TranslationEndpoint(active.endpoint) else {
                return t("请先选择提供商和模型。", "Choose a provider and model first.")
            }
            let host = endpoint.url.host() ?? ""
            let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
            let destination = local
                ? t("本机 · \(active.name)", "On this Mac · \(active.name)")
                : "\(active.name) · \(host)"
            if commands.answer == .loading { return t("正在等待 \(destination)…", "Waiting for \(destination)…") }
            return t("按回车仅将输入的问题发送至 \(destination)，不会查找实时网页。",
                     "Press Return to send only your question to \(destination). No live web lookup.")
        case .web(_, _, let url):
            if commands.webFailed { return t("未能打开浏览器。请检查默认浏览器后重试。", "Could not open the browser. Check your default browser and retry.") }
            return t("按回车将搜索词发送至 \(url.host() ?? "")。", "Press Return to send the search terms to \(url.host() ?? "").")
        case .missingArgument(let id):
            if id == "img" { return t("输入「img 红色帆船」按画面搜索。", "Try “img red sailboat” to search by image content.") }
            return t("在命令后输入内容。", "Enter text after the command.")
        case .argumentTooLong(_, let max):
            return t("内容超出 \(max) 字节。", "The input exceeds \(max) bytes.")
        default: return ""
        }
    }

    private func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

// A native non-editable text view preserves wrapping and text selection.
// The QA card also uses it to scroll from the search field on Page Up/Down.
@MainActor
struct LauncherScrollableText: NSViewRepresentable {
    let text: String
    let label: String
    let identifier: String
    var page = 0

    final class Coordinator { var page = 0 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier(identifier)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let display = NSTextView(frame: .zero)
        display.isEditable = false
        display.isRichText = false
        display.isVerticallyResizable = true
        display.autoresizingMask = [.width]
        display.textContainer?.widthTracksTextView = true
        display.textContainer?.lineFragmentPadding = 0
        display.drawsBackground = false
        display.font = .systemFont(ofSize: 13)
        display.textColor = .labelColor
        scroll.documentView = display
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let display = scroll.documentView as? NSTextView else { return }
        display.setAccessibilityLabel(label)
        if display.string != text { display.string = text }
        let delta = page - context.coordinator.page
        context.coordinator.page = page
        guard delta != 0 else { return }
        if let manager = display.layoutManager, let container = display.textContainer {
            manager.ensureLayout(for: container)
        }
        let view = scroll.contentView.bounds
        let maximum = max(0, display.frame.height - view.height)
        let y = min(maximum, max(0, view.minY + CGFloat(delta) * max(18, view.height - 18)))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
