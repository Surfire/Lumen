import AppKit
import SwiftUI

@MainActor
final class LauncherCommands: ObservableObject {
    @Published private(set) var resolution: LumenCommandResolution = .search
    @Published private(set) var entries: [LumenCommandCatalog.Entry] = []
    @Published private(set) var selection = 0
    @Published private(set) var answer: LumenQuickAnswer.State = .idle
    @Published private(set) var copied = false
    @Published private(set) var webFailed = false
    @Published private(set) var answerPage = 0
    private(set) var raw = ""
    private lazy var request: LumenQuickAnswer = {
        let request = LumenQuickAnswer()
        request.onChange = { [weak self] in self?.answer = $0 }
        return request
    }()

    var showsCard: Bool { resolution != .search && resolution != .translation }
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

    func move(_ delta: Int) { selection = min(max(0, selection + delta), max(0, entries.count - 1)) }
    func choose(_ index: Int) { if entries.indices.contains(index) { selection = index } }
    func submit(_ question: String, using ask: @escaping LumenQuickAnswer.Answer) { request.submit(question: question, askConfiguredProvider: ask) }
    func pageAnswer(_ delta: Int) -> Bool {
        guard case .answer = answer else { return false }
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
                if case .answer(let output) = commands.answer {
                    QAAnswerView(text: output, page: commands.answerPage,
                                 label: t("模型回答", "Model Answer"))
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

    private func entryTitle(_ item: LumenCommandCatalog.Entry) -> String {
        switch item.commandID {
        case "discover": return t("命令列表", "Browse Commands")
        case "qa": return t("问模型", "Ask Model")
        case "translate": return t("翻译", "Translate")
        case "google": return t("搜索 Google", "Search Google")
        default: return item.title
        }
    }

    private var title: String {
        switch commands.resolution {
        case .question: return t("问模型", "Ask Model")
        case .web(let id, let title, _): return id == "google" ? t("搜索 Google", "Search Google") : title
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
        case .missingArgument: return t("在命令后输入内容。", "Enter text after the command.")
        case .argumentTooLong(_, let max):
            return t("内容超出 \(max) 字节。", "The input exceeds \(max) bytes.")
        default: return ""
        }
    }

    private func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

// A native non-editable text view preserves wrapping and text selection across
// the answer while Page Up/Down can scroll it from the search field.
@MainActor
private struct QAAnswerView: NSViewRepresentable {
    let text: String
    let page: Int
    let label: String

    final class Coordinator { var page = 0 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("qa-answer-scroll")
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
        if display.string != text {
            display.string = text
            scroll.contentView.scroll(to: .zero)
        }
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
