import AppKit
import SwiftUI

struct DictionaryDefinition: Equatable {
    let word: String
    let text: String?
    let loading: Bool
}

enum PanelMode: Equatable {
    case scriptOutput(CommandExecution)
    case translation(TranslationCommand)
    case imageSetup
    case clipboard
    case window
    case commandCard
    case definition(word: String, text: String?, loading: Bool)
    case search
}

enum PanelOverlay: Equatable {
    case localQuickLook
    case contextMenu(count: Int)
    case inlinePreview(SearchHit)
    case none
}

struct PanelState: Equatable {
    let mode: PanelMode
    let overlay: PanelOverlay

    @MainActor
    static func resolve(
        model: Launcher,
        commands: LauncherCommands,
        translation: TranslationPanelModel,
        contextActions: ContextActions,
        inlinePreview: LauncherInlinePreview,
        hasLocalPreview: Bool = false
    ) -> PanelState {
        let mode: PanelMode
        if let execution = commands.visibleExecution {
            mode = .scriptOutput(execution)
        } else if let command = translation.command {
            mode = .translation(command)
        } else if commands.isImageCommand && !model.isImageSearch {
            mode = .imageSetup
        } else if commands.isClipboardCommand {
            mode = .clipboard
        } else if commands.isWindowCommand {
            mode = .window
        } else if commands.showsCard {
            mode = .commandCard
        } else if let definition = commands.definition {
            mode = .definition(word: definition.word, text: definition.text, loading: definition.loading)
        } else {
            mode = .search
        }

        let overlay: PanelOverlay
        if hasLocalPreview {
            overlay = .localQuickLook
        } else if contextActions.isOpen, mode == .search || mode == .clipboard {
            overlay = .contextMenu(count: contextActions.items.count)
        } else if mode == .search,
                  let hit = inlinePreview.hit,
                  case .file(let selected) = model.selectedResult,
                  selected == hit,
                  model.containsCurrentFile(hit) {
            overlay = .inlinePreview(hit)
        } else {
            overlay = .none
        }

        return PanelState(mode: mode, overlay: overlay)
    }
}

enum PanelGeometry {
    static let defaultWidth: CGFloat = 680
    static let previewWidth: CGFloat = 860
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 28
    static let maximumVisibleRows = 8
    static let standardRowHeight: CGFloat = 44
    static let previewRowHeight: CGFloat = 60
    static let emptyResultsHeight: CGFloat = 56
    static let inlinePreviewMinimumHeight: CGFloat = 360

    static func rowHeight(for result: LauncherResult) -> CGFloat {
        if case .file(let hit) = result, hit.hasPreview { return previewRowHeight }
        return standardRowHeight
    }

    @MainActor
    static func size(
        for state: PanelState,
        rows: [LauncherResult],
        showsResults: Bool,
        needsAccessibility: Bool = false
    ) -> CGSize {
        let width: CGFloat
        if case .inlinePreview = state.overlay { width = previewWidth }
        else { width = defaultWidth }

        let shell = headerHeight + footerHeight
            + (needsAccessibility ? WindowAccessibilityBanner.launcherHeight : 0)

        let bodyHeight: CGFloat
        switch state.mode {
        case .scriptOutput(let execution):
            bodyHeight = execution.command.mode == .fullOutput && execution.hasOutput ? 316 : 100
        case .translation:
            bodyHeight = 138
        case .imageSetup, .commandCard:
            bodyHeight = 162
        case .definition:
            bodyHeight = 220
        case .clipboard:
            if case .contextMenu(let count) = state.overlay {
                bodyHeight = CGFloat(min(count, maximumVisibleRows)) * standardRowHeight
            } else {
                bodyHeight = ClipboardHistoryView.height
            }
        case .window:
            bodyHeight = CGFloat(min(max(rows.count, 1), maximumVisibleRows)) * standardRowHeight
        case .search:
            if case .contextMenu(let count) = state.overlay {
                bodyHeight = CGFloat(min(count, maximumVisibleRows)) * standardRowHeight
            } else if !showsResults {
                bodyHeight = 0
            } else if rows.isEmpty {
                bodyHeight = emptyResultsHeight
            } else {
                let visibleHeight = rows.prefix(maximumVisibleRows).reduce(CGFloat(0)) { total, row in
                    total + rowHeight(for: row)
                }
                if case .inlinePreview = state.overlay {
                    bodyHeight = max(visibleHeight, inlinePreviewMinimumHeight)
                } else {
                    bodyHeight = visibleHeight
                }
            }
        }
        return CGSize(width: width, height: shell + bodyHeight)
    }
}

@MainActor
final class LauncherCommands: ObservableObject {
    @Published private(set) var resolution: LumenCommandResolution = .search
    @Published private(set) var entries: [LumenCommandCatalog.Entry] = []
    @Published private(set) var selection = 0
    @Published private(set) var clipboardRows: [ClipboardItem] = []
    @Published private(set) var clipboardSelection: Int64?
    @Published private(set) var windowRows: [LaunchAction] = []
    @Published private(set) var windowSelection = 0
    @Published private(set) var answer: LumenQuickAnswer.State = .idle
    @Published private var partialAnswer = ""
    @Published private(set) var copied = false
    @Published private(set) var webFailed = false
    @Published private(set) var answerPage = 0
    @Published private(set) var executableMatches: [ActionMatch] = []
    @Published private(set) var execution: CommandExecution?
    @Published var executionArgument = ""
    @Published private(set) var outputCopied = false
    @Published private(set) var outputPage = 0
    @Published private(set) var definition: DictionaryDefinition?
    @Published private(set) var definitionCopied = false
    @Published private(set) var definitionPage = 0
    private var executionTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var definitionTask: Task<Void, Never>?
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
    var isWindowCommand: Bool { if case .window = resolution { return true }; return false }
    var selectedWindowAction: LaunchAction? { windowRows.indices.contains(windowSelection) ? windowRows[windowSelection] : nil }
    var selectedClipboardItem: ClipboardItem? { clipboardRows.first { $0.id == clipboardSelection } }
    var showsCard: Bool {
        switch resolution {
        case .discovery, .question, .web, .missingArgument, .argumentTooLong: return true
        case .search, .translation, .image, .clipboard, .window: return false
        }
    }
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

    func matchExecutables(_ actions: [LaunchAction], in model: Launcher, resetSelection: Bool = false) {
        let matches = resolution == .search && !actions.isEmpty && !LauncherFileQuery(raw).isFiltered
            ? LaunchCatalog.matches(raw, actions: actions, includeDictionary: false) : []
        if matches != executableMatches { executableMatches = matches }
        model.setExecutableMatches(matches, resetSelection: resetSelection)
    }

    func results(in model: Launcher) -> [LauncherResult] { model.visibleResults }
    func selection(in model: Launcher) -> String? { model.selectedID }
    func selectedResult(in model: Launcher) -> LauncherResult? { model.selectedResult }
    func choose(_ row: LauncherResult, in model: Launcher) { model.selectedID = row.id }
    func moveResults(_ delta: Int, in model: Launcher) { model.moveSelection(delta) }

    func lookupDefinition(_ word: String,
                          fetcher: @escaping @Sendable (String) -> String? = { LauncherSystemActions.dictionaryDefinition($0) }) {
        definitionTask?.cancel()
        definitionCopied = false
        definitionPage = 0
        definition = DictionaryDefinition(word: word, text: nil, loading: true)
        definitionTask = Task { [weak self] in
            let text: String? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: fetcher(word))
                }
            }
            guard !Task.isCancelled, let self, self.definition?.word == word else { return }
            self.definitionTask = nil
            self.definition = DictionaryDefinition(word: word, text: text, loading: false)
        }
    }

    func closeDefinition() {
        definitionTask?.cancel()
        definitionTask = nil
        if definition != nil { definition = nil }
        if definitionCopied { definitionCopied = false }
        if definitionPage != 0 { definitionPage = 0 }
    }

    func copyDefinition(to pasteboard: NSPasteboard) {
        guard let text = definition?.text, !text.isEmpty else { return }
        definitionCopied = ClipboardManager.writeInternalString(text, to: pasteboard)
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

    /// `filter` defaults to the text after `win`; pass it only to override the parsed resolution.
    func updateWindowActions(_ filter: String? = nil, isPortrait: Bool, resetSelection: Bool = false) {
        var query = ""
        if let filter { query = filter }
        else if case .window(let payload) = resolution { query = payload }
        let rows = isWindowCommand ? LaunchCatalog.windowActions(isPortrait: isPortrait, query: query) : []
        let selectedID = selectedWindowAction?.id
        if windowRows != rows { windowRows = rows }
        let next = resetSelection ? 0 : (rows.firstIndex { $0.id == selectedID } ?? 0)
        if windowSelection != next { windowSelection = next }
    }

    func moveWindowSelection(_ delta: Int) {
        guard !windowRows.isEmpty else { return }
        windowSelection = min(max(0, windowSelection + delta), windowRows.count - 1)
    }

    func chooseWindowAction(_ id: String) {
        if let index = windowRows.firstIndex(where: { $0.id == id }) { windowSelection = index }
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
        if let text = definition?.text, !text.isEmpty {
            definitionPage += delta
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

struct CommandExecution: Equatable {
    enum Phase: Equatable { case argument(String, required: Bool), running, finished(LauncherProcess.Result) }
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
struct LauncherDefinitionCard: View {
    @ObservedObject var commands: LauncherCommands
    let word: String
    let text: String?
    let loading: Bool
    let chinese: Bool
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(word, systemImage: "book").font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                if loading {
                    ProgressView().controlSize(.small)
                } else if let text, !text.isEmpty {
                    Button(commands.definitionCopied ? t("已复制", "Copied") : t("复制", "Copy"), action: copy)
                        .accessibilityIdentifier("definition-copy")
                }
                Button(t("关闭", "Close"), action: close)
                    .accessibilityIdentifier("definition-close")
            }
            if loading {
                Text(t("正在查询系统词典…", "Looking up in Dictionary…"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if let text, !text.isEmpty {
                LauncherScrollableText(text: text, label: t("词典释义", "Dictionary Definition"),
                                       identifier: "definition-scroll", page: commands.definitionPage)
            } else {
                Text(t("系统词典中没有找到释义。", "No definition was found in the system dictionaries."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
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
        .padding(.horizontal, 16)
        .padding(.vertical, commands.resolution == .discovery ? 6 : 10)
    }

    private var discovery: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
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
                            .padding(.horizontal, 8).frame(height: 23)
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
        case "window": return t("窗口管理与自动分屏", "Window Management & Auto-Tile")
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

@MainActor
final class LauncherScriptCatalog: ObservableObject {
    let shortcutsExecutable: URL
    @Published private(set) var scriptsEnabled: Bool
    @Published private(set) var folder: String?
    @Published private(set) var shortcutsEnabled: Bool
    @Published private(set) var scripts: [LauncherExecutable] = []
    @Published private(set) var shortcuts: [LauncherExecutable] = []
    @Published private(set) var scriptLoading = false
    @Published private(set) var shortcutLoading = false
    @Published private(set) var scriptFailed = false
    @Published private(set) var shortcutFailed = false
    private let defaults: UserDefaults?
    private var scriptLoad: Task<Void, Never>?
    private var shortcutLoad: Task<Void, Never>?

    init(defaults: UserDefaults?, shortcutsExecutable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) {
        self.defaults = defaults
        self.shortcutsExecutable = shortcutsExecutable
        let savedFolder = defaults?.string(forKey: "localScriptsFolder")
        folder = savedFolder
        scriptsEnabled = savedFolder != nil && defaults?.bool(forKey: "localScriptsEnabled") == true
        shortcutsEnabled = defaults?.bool(forKey: "appleShortcutsEnabled") == true
    }

    func selectFolder(_ url: URL) {
        guard let path = LauncherScriptFiles.path(url) else { scriptFailed = true; return }
        if folder != path { scripts = [] }
        folder = path
        defaults?.set(path, forKey: "localScriptsFolder")
        reloadScripts()
    }

    func createAndEnable() {
        scriptLoad?.cancel()
        scriptLoading = true
        scriptFailed = false
        scriptLoad = Task { [weak self] in
            let folder = await LauncherProcess.offMain { $0.isCancelled ? nil : LauncherScriptFiles.createSuggestedFolder() }
            guard !Task.isCancelled, let self else { return }
            self.scriptLoading = false
            self.scriptLoad = nil
            guard let folder else { self.scriptFailed = true; return }
            self.selectFolder(folder)
            self.setScriptsEnabled(true)
        }
    }

    func setScriptsEnabled(_ enabled: Bool) {
        guard !enabled || folder != nil else { return }
        scriptsEnabled = enabled
        defaults?.set(enabled, forKey: "localScriptsEnabled")
        reloadScripts()
    }

    func reloadScripts() {
        scriptLoad?.cancel()
        scriptLoad = nil
        scriptFailed = false
        guard scriptsEnabled, let folder else { scripts = []; scriptLoading = false; return }
        scriptLoading = true
        scriptLoad = Task { [weak self] in
            let commands = await LauncherProcess.offMain { work in LauncherScriptFiles.scan(folder) { work.isCancelled } }
            guard !Task.isCancelled, let self else { return }
            self.scripts = commands ?? []
            self.scriptFailed = commands == nil
            self.scriptLoading = false
            self.scriptLoad = nil
        }
    }

    func setShortcutsEnabled(_ enabled: Bool) {
        shortcutsEnabled = enabled
        defaults?.set(enabled, forKey: "appleShortcutsEnabled")
        refreshShortcuts()
    }

    func refreshShortcuts() {
        shortcutLoad?.cancel()
        shortcutLoad = nil
        shortcutFailed = false
        guard shortcutsEnabled else { shortcuts = []; shortcutLoading = false; return }
        shortcutLoading = true
        let executable = shortcutsExecutable.path
        shortcutLoad = Task { [weak self] in
            let result = await LauncherProcess.offMain { work in
                LauncherProcess.run(executable, arguments: ["list"], deadline: ContinuousClock.now + .seconds(5)) { work.isCancelled }
            }
            guard !Task.isCancelled, let self else { return }
            let names = Self.shortcutNames(result)
            if let names {
                self.shortcuts = names.map { LauncherExecutable(source: .shortcut($0), title: $0, mode: .fullOutput) }
            }
            self.shortcutFailed = names == nil
            self.shortcutLoading = false
            self.shortcutLoad = nil
        }
    }

    static func shortcutNames(_ result: LauncherProcess.Result) -> [String]? {
        guard result.succeeded, !result.stdout.truncated,
              let listing = String(data: result.stdout.bytes, encoding: .utf8) else { return nil }
        var seen = Set<String>()
        return listing.split { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }.map(String.init).filter {
            !$0.utf8.contains(0) && !$0.allSatisfy(\.isWhitespace) && seen.insert($0).inserted
        }
    }

    func contains(_ command: LauncherExecutable) -> Bool {
        switch command.source {
        case .script: return scriptsEnabled && scripts.contains(command)
        case .shortcut: return shortcutsEnabled && shortcuts.contains(command)
        }
    }

    @discardableResult func close() -> Task<Void, Never>? {
        scriptLoad?.cancel()
        shortcutLoad?.cancel()
        return shortcutLoad
    }
}
