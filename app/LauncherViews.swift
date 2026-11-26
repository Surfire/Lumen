import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SearchWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: Launcher
    @ObservedObject var applicationIcons: ResultIconDisplay
    @ObservedObject var contextActions: ContextActions
    @ObservedObject var translation: TranslationPanelModel
    @ObservedObject var commands: LauncherCommands
    @ObservedObject var inlinePreview: LauncherInlinePreview
    @ObservedObject var imageSearch: LauncherImageSearch
    let clipboard: ClipboardManager
    let selectClipboard: (Int64) -> Void
    let activateCommand: () -> Void
    let activateExecution: () -> Void
    let copyOutput: () -> Void
    let cancelExecution: () -> Void
    let searchCommandAsFiles: () -> Void
    let closeInlinePreview: () -> Void
    let activateTranslation: () -> Void
    let toggleContextActions: () -> Void
    let showSettings: () -> Void
    let beginIndex: () -> Void
    let open: (LauncherResult) -> Void
    let browse: () -> Void
    let moveSelection: (Int) -> Void
    let fileAction: (FileAction, SearchHit) -> Void

    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 28
    static let maximumVisibleRows = 8

    static func height(for model: Launcher, contextCount: Int = 0, hasTranslation: Bool = false,
                       commandHeight: CGFloat? = nil, hasPreview: Bool = false, hasExecutableMatches: Bool = false) -> CGFloat {
        let shell = headerHeight + footerHeight
        if hasTranslation { return shell + 138 }
        if let commandHeight { return shell + commandHeight }
        if contextCount > 0 { return shell + CGFloat(min(contextCount, maximumVisibleRows) * 44) }
        guard model.showsResults || hasExecutableMatches else { return shell }
        let rows = model.hasQuery ? maximumVisibleRows : min(model.visibleResults.count, maximumVisibleRows)
        return shell + max(CGFloat(rows * 44), hasPreview ? 176 : 0)
    }

    private static func rowHeight(_ hit: SearchHit) -> CGFloat { hit.hasPreview ? 60 : 44 }

    private var showsResults: Bool { model.showsResults || !commands.executableMatches.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if let execution = commands.visibleExecution {
                LauncherCommandOutputCard(commands: commands, execution: execution, chinese: model.zh,
                                          run: activateExecution, copy: copyOutput, cancel: cancelExecution)
            } else if let command = translation.command {
                TranslationResultCard(model: translation, command: command, chinese: model.zh,
                                      activate: activateTranslation)
            } else if commands.isImageCommand && !model.isImageSearch {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.t("图像搜索", "Image Search"), systemImage: "photo")
                        .font(.headline)
                    Text(imageSearch.loading
                         ? model.t("正在读取图像设置…", "Checking image settings…")
                         : model.t("在「索引与隐私」选择本地目录和投影器，再建立图像索引。",
                                   "Choose a local folder and projector in Index & Privacy, then build the image index."))
                        .foregroundStyle(.secondary)
                    Button(model.t("打开图像设置…", "Open Image Settings…"), action: showSettings)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if commands.isClipboardCommand {
                if contextActions.isOpen { contextRows }
                else {
                    ClipboardHistoryView(commands: commands, clipboard: clipboard, chinese: model.zh,
                                         select: selectClipboard, copy: activateCommand, openSettings: showSettings)
                }
            } else if commands.showsCard {
                LauncherCommandCard(commands: commands, provider: translation, chinese: model.zh,
                                    activate: activateCommand, openSettings: showSettings)
            } else if contextActions.isOpen {
                contextRows
            } else if let hit = inlinePreview.hit, model.selectedHit == hit, model.containsCurrentFile(hit) {
                HStack(spacing: 0) {
                    results
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Text(hit.name).font(.headline).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 2)
                            Button(action: closeInlinePreview) {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(model.t("关闭预览", "Close Preview"))
                        }
                        MacInlinePreviewView(state: inlinePreview.state, image: inlinePreview.image,
                                             language: model.zh ? .simplifiedChinese : .english)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(width: 295)
                }
            } else if showsResults {
                results.overlay {
                    if model.visibleResults.isEmpty && commands.executableMatches.isEmpty {
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
            if let execution = commands.visibleExecution {
                keyHint("esc", execution.running ? model.t("取消", "Cancel") : model.t("关闭结果", "Close Result"))
                if execution.command.mode == .fullOutput && execution.hasOutput {
                    keyHint("PgUp/PgDn", model.t("翻页", "Scroll"))
                }
                Spacer(minLength: 8)
            } else if translation.command != nil {
                if translation.activity == .translating {
                    keyHint("esc", model.t("取消", "Cancel"))
                } else if !translation.output.isEmpty {
                    keyHint("↵", model.t("复制", "Copy"))
                    if translation.copied { Text(model.t("已复制", "Copied")).accessibilityIdentifier("translation-copied") }
                } else if translation.canTranslate {
                    keyHint("↵", model.t("翻译", "Translate"))
                }
                Spacer(minLength: 8)
            } else if commands.showsCard || commands.isImageCommand && !model.isImageSearch {
                commandFooter
            } else {
                searchFooter
            }
            Button(action: showSettings) {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.t("设置", "Settings"))
            .help(translation.command == nil ? model.t("设置与索引详情", "Settings and index details")
                  : model.t("翻译设置", "Translation Settings"))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .frame(height: Self.footerHeight)
        .background(.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var commandFooter: some View {
        switch commands.resolution {
        case .discovery:
            keyHint("↑↓", model.t("选择", "Select"))
            keyHint("↵", model.t("填入命令", "Fill Command"))
        case .clipboard:
            if contextActions.isOpen {
                keyHint("↑↓", model.t("选择操作", "Select Action"))
                keyHint("↵", model.t("执行", "Run"))
            } else if commands.selectedClipboardItem != nil {
                keyHint("↑↓", model.t("选择", "Select"))
                keyHint("↵", model.t("复制", "Copy"))
                Button(action: toggleContextActions) { keyHint("⇧↵", model.t("操作", "Actions")) }
                    .buttonStyle(.borderless)
            }
        case .question:
            switch commands.answer {
            case .loading: keyHint("esc", model.t("取消", "Cancel"))
            case .answer:
                keyHint("↵", model.t("复制", "Copy"))
                keyHint("PgUp/PgDn", model.t("翻页", "Scroll"))
                if commands.copied { Text(model.t("已复制", "Copied")) }
            case .failed: keyHint("↵", model.t("重试", "Retry"))
            case .idle: EmptyView()
            }
        default: EmptyView()
        }
        Spacer(minLength: 8)
        Button(model.t("搜索文件", "Search Files"), action: searchCommandAsFiles)
            .buttonStyle(.borderless)
    }

    @ViewBuilder private var searchFooter: some View {
        if model.isImageSearch {
            Label(model.t("图像内容", "Image Content"), systemImage: "photo")
        }
        if showsResults {
            keyHint("↑↓", model.t("选择", "Select"))
            keyHint("↵", model.t("打开", "Open"))
            if case .file(let file) = commands.selectedResult(in: model) {
                keyHint("⌘↵", model.t("在 Finder 中显示", "Show in Finder"))
                if file.isLocal && file.kind == "file" {
                    keyHint(model.t("空格 / ⌘Y", "Space / ⌘Y"), model.t("预览", "Preview"))
                }
            }
        }
        if let title = model.launcherActivityTitle,
           !model.showsResults || model.activityBusy || model.watchState == .failed || model.scopePending {
            if model.activityBusy || !model.canSearch {
                Label(title, systemImage: model.activityBusy ? "arrow.triangle.2.circlepath" : "internaldrive")
                    .lineLimit(1)
                if let metrics = model.activityMetrics { Text(metrics).monospacedDigit().lineLimit(1) }
            } else {
                Text(title).lineLimit(1)
            }
        }
        if let notice = model.searchNotice, !model.visibleResults.isEmpty {
            Text(model.title(for: notice)).lineLimit(1).help(model.title(for: notice))
                .accessibilityIdentifier("launcher-notice")
        }
        Spacer(minLength: 8)
        if !showsResults && !model.activityBusy {
            Label(model.t("筛选", "Filters"), systemImage: "line.3.horizontal.decrease")
                .help(model.t("kind:folder、ext:pdf 或 path:\"/Users/…/My Files/\"；也可直接输入绝对路径。",
                              "Try kind:folder, ext:pdf, or path:\"/Users/…/My Files/\". You can also type an absolute path."))
                .accessibilityIdentifier("query-filter-hints")
        }
        if model.canStartIndexFromLauncher {
            Button(model.t("在后台建立索引", "Build in Background"), action: beginIndex)
                .buttonStyle(.borderless).fontWeight(.semibold)
                .accessibilityIdentifier("build-index")
        } else {
            keyHint("esc", inlinePreview.isOpen ? model.t("关闭预览", "Close Preview") : model.t("关闭", "Close"))
        }
        if commands.selectedResult(in: model) != nil {
            Button(action: toggleContextActions) {
                keyHint("⌘K", model.t("操作", "Actions"))
            }
            .buttonStyle(.borderless)
        }
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
        let highlight = LauncherHighlight(model.query)
        let selection = commands.selection(in: model)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(commands.results(in: model)) { result in
                        let selected = selection == result.id
                        switch result {
                        case .file(let hit): resultRow(hit, highlight: highlight, selected: selected).id(result.id)
                        case .action(let action): actionRow(action, highlight: highlight, selected: selected).id(result.id)
                        case .shortcut(let shortcut):
                            utilityRow(result, title: shortcut.title, detail: shortcut.detail, symbol: shortcut.symbol,
                                       highlight: highlight, selected: selected).id(result.id)
                        case .calculation(let calculation):
                            utilityRow(result, title: calculation.display, detail: model.t("回车复制", "Return to Copy"),
                                       symbol: "plus.forwardslash.minus", highlight: nil, selected: selected).id(result.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: selection) { _, value in
                if let value { proxy.scrollTo(value) }
            }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(keys: [.return]) { press in
                guard press.modifiers.isEmpty, let result = commands.selectedResult(in: model) else { return .ignored }
                open(result)
                return .handled
            }
        }
    }

    private var contextRows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(contextActions.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        contextActions.run(index)
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                            .frame(height: 44).modifier(ResultRowChrome(selected: contextActions.selected == index))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(contextActions.selected == index ? .isSelected : [])
                }
            }.padding(.horizontal, 8)
        }
    }

    private func utilityRow(_ result: LauncherResult, title: String, detail: String, symbol: String,
                            highlight: LauncherHighlight?, selected: Bool) -> some View {
        return HStack(spacing: 10) {
            if case .shortcut(let shortcut) = result, let action = model.application(for: shortcut) {
                ActionResultIcon(action: action, image: ApplicationIcons.Key(action).flatMap { applicationIcons.images[$0] },
                                 selected: selected)
            } else {
                Image(systemName: symbol).frame(width: 28, height: 28)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight?.text(title, size: 13, colorScheme: colorScheme, mode: .action) ?? AttributedString(title))
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(highlight?.text(detail, size: 11, colorScheme: colorScheme) ?? AttributedString(detail))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 2)
            if case .shortcut = result { ResultCategory(title: model.t("快捷链接", "Quicklink"), symbol: "bolt") }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .modifier(ResultRowChrome(selected: selected))
        .onTapGesture { clickRow(result) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(model.t("执行", "Run"))) { open(result) }
    }

    private func clickRow(_ result: LauncherResult, count: Int? = nil) {
        browse()
        commands.choose(result, in: model)
        // Select on mouseUp without waiting to see if it becomes a double click.
        let event = NSApp.currentEvent
        if (count ?? (event?.type == .leftMouseUp ? event?.clickCount : nil)) == 2 { open(result) }
    }

    private var emptyResultsLabel: String {
        if let notice = model.searchNotice {
            if model.isImageSearch {
                return model.t("图像搜索失败。请检查本机模型和投影器。", "Image search failed. Check the local model and projector.")
            }
            return model.title(for: notice)
        }
        if model.searching || model.semanticBusy {
            return model.t("正在搜索…", "Searching…")
        }
        return model.isImageSearch ? model.t("没有足够接近的图像", "No close image matches")
            : model.t("没有匹配结果", "No matches")
    }

    private func actionRow(_ action: LaunchAction, highlight: LauncherHighlight, selected: Bool) -> some View {
        let category: ResultCategory
        let detail: String?
        switch action.destination {
        case .application(let url, _):
            category = ResultCategory(title: model.t("应用", "App"), symbol: "app")
            detail = (url.path as NSString).abbreviatingWithTildeInPath
        case .settings:
            category = ResultCategory(title: model.t("系统设置", "System Settings"), symbol: "gearshape")
            detail = nil
        case .system(let operation):
            category = ResultCategory(title: model.t("系统操作", "System Action"), symbol: "bolt")
            if case .define(let word) = operation { detail = word }
            else { detail = nil }
        case .executable(let command):
            switch command.source {
            case .script(_, _, let name, _):
                category = ResultCategory(title: model.t("本地脚本", "Local Script"), symbol: "terminal")
                detail = command.description.isEmpty ? (command.alias.isEmpty ? name : command.alias) : command.description
            case .shortcut:
                category = ResultCategory(title: model.t("快捷指令", "Apple Shortcut"), symbol: "square.stack")
                detail = nil
            }
        }
        let title = action.title(chinese: model.zh)
        return HStack(spacing: 10) {
            ActionResultIcon(action: action, image: ApplicationIcons.Key(action).flatMap { applicationIcons.images[$0] },
                             selected: selected)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.text(title, size: 13, colorScheme: colorScheme, mode: .action))
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let detail {
                    Text(highlight.text(detail, size: 11, colorScheme: colorScheme))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(detail)
                }
            }
            Spacer(minLength: 2)
            category
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .modifier(ResultRowChrome(selected: selected))
        .overlay { ActionRowClickView { clickRow(.action(action), count: $0) }.accessibilityHidden(true) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(model.t("打开", "Open"))) { open(.action(action)) }
        .accessibilityIdentifier(action.id)
    }

    @ViewBuilder private func resultRow(_ hit: SearchHit, highlight: LauncherHighlight, selected: Bool) -> some View {
        if hit.isLocal && model.containsCurrentFile(hit) {
            fileRow(hit, highlight: highlight, selected: selected).onDrag {
                guard model.containsCurrentFile(hit), let url = LocalFile.dragURL(for: hit) else { return NSItemProvider() }
                return NSItemProvider(object: url as NSURL)
            }
        } else { fileRow(hit, highlight: highlight, selected: selected) }
    }

    private func fileRow(_ hit: SearchHit, highlight: LauncherHighlight, selected: Bool) -> some View {
        let folder = hit.kind == "directory"
        return HStack(spacing: 10) {
            FileTypeIcon(name: hit.name, directory: folder)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(highlight.text(hit.name, size: 13, colorScheme: colorScheme, mode: .name))
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !hit.isCloudReference {
                        Spacer(minLength: 2)
                        fileCategory(hit, folder: folder)
                    }
                }
                let parent = (hit.path as NSString).deletingLastPathComponent as NSString
                Text(highlight.text(parent.abbreviatingWithTildeInPath, size: 11, colorScheme: colorScheme))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(hit.path)
                if hit.hasPreview, let snippet = hit.snippet {
                    HStack(spacing: 6) {
                        if let page = hit.pdf_page {
                            Text(model.t("第 \(page) 页", "Page \(page)")).fontWeight(.medium).fixedSize()
                        }
                        Text(highlight.text(snippet, size: 11, colorScheme: colorScheme)).lineLimit(1)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hit.isCloudReference {
                Label(hit.availability == "placeholder"
                      ? model.t("仅在线", "Online only")
                      : model.t("云盘 · 仅名称", "Cloud · Name only"), systemImage: "icloud")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                Button(model.t("在 Finder 中显示", "Show in Finder")) { fileAction(.reveal, hit) }
                    .buttonStyle(.borderless).font(.caption).fixedSize()
                    .accessibilityIdentifier("reveal-cloud-result")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight(hit))
        .modifier(ResultRowChrome(selected: selected))
        .onTapGesture { clickRow(.file(hit)) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(model.t("打开", "Open"))) { open(.file(hit)) }
        .accessibilityAction(named: Text(model.t("在 Finder 中显示", "Show in Finder"))) { fileAction(.reveal, hit) }
        .accessibilityActions {
            if hit.isLocal && hit.kind == "file" {
                Button(model.t("快速查看", "Quick Look")) { fileAction(.preview, hit) }
            }
            Button(model.t("复制名称", "Copy Name")) { fileAction(.copyName, hit) }
            Button(model.t("复制路径", "Copy Path")) { fileAction(.copyPath, hit) }
        }
        .contextMenu {
            Button(model.t("打开", "Open")) { fileAction(.open, hit) }.disabled(!hit.isLocal)
            Button(model.t("在 Finder 中显示", "Show in Finder")) { fileAction(.reveal, hit) }
            Button(model.t("快速查看 · ⌘Y", "Quick Look · ⌘Y")) { fileAction(.preview, hit) }
                .disabled(!hit.isLocal || hit.kind != "file")
            Divider()
            Button(model.t("复制名称 · ⇧⌘C", "Copy Name · ⇧⌘C")) { fileAction(.copyName, hit) }
            Button(model.t("复制路径 · ⌥⌘C", "Copy Path · ⌥⌘C")) { fileAction(.copyPath, hit) }
        }
    }

    private func fileCategory(_ hit: SearchHit, folder: Bool) -> ResultCategory {
        if hit.isSemanticCandidate {
            return ResultCategory(title: model.relatedExcerptsLabel, symbol: "text.quote", emphasized: true)
        }
        if hit.isImageMatch { return ResultCategory(title: model.t("图像内容", "Image Content"), symbol: "photo") }
        return folder ? ResultCategory(title: model.t("文件夹", "Folder"), symbol: "folder")
            : ResultCategory(title: model.t("文件", "File"), symbol: "doc")
    }
}

private struct ResultCategory: View {
    let title: String
    let symbol: String
    var emphasized = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(emphasized ? .primary : .secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(emphasized ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.055), in: Capsule())
        .fixedSize()
    }
}

private struct ResultRowChrome: ViewModifier {
    let selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: 8)
                ZStack {
                    if selected {
                        shape.fill(Color.accentColor.opacity(0.14))
                        shape.strokeBorder(Color.accentColor.opacity(0.29), lineWidth: 1)
                    } else if hovered {
                        shape.fill(.primary.opacity(0.065))
                    }
                }
                .padding(.vertical, 1)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

@MainActor
private struct ActionRowClickView: NSViewRepresentable {
    let click: (Int) -> Void

    func makeNSView(context: Context) -> ActionRowClickTarget { ActionRowClickTarget() }
    func updateNSView(_ view: ActionRowClickTarget, context: Context) { view.click = click }
}

// Launch actions are not draggable. Use the native mouseUp click count rather than
// inferring a double click from SwiftUI gesture timing or NSApp.currentEvent.
final class ActionRowClickTarget: NSView {
    var click: ((Int) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { click?(event.clickCount) }
    }
}

// Use type artwork without opening or requesting an icon from the indexed path.
@MainActor
private struct FileTypeIcon: View {
    let name: String
    let directory: Bool
    private static var icons: [UTType: NSImage] = [:]

    private var artwork: NSImage {
        let ext = (name as NSString).pathExtension
        let type: UTType = directory ? .folder
            : (ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data)
        if let cached = Self.icons[type] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        if Self.icons.count < 96 { Self.icons[type] = icon }
        return icon
    }

    var body: some View {
        Image(nsImage: artwork).resizable().scaledToFit()
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

private struct ActionResultIcon: View {
    let action: LaunchAction
    let image: CGImage?
    let selected: Bool

    var body: some View {
        let isApplication = ApplicationIcons.Key(action) != nil
        Group {
            if let image {
                Image(decorative: image, scale: 1).renderingMode(.original).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 26, height: 26)
            } else if let symbol = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: isApplication ? "app" : "gearshape", accessibilityDescription: nil) {
                Image(nsImage: symbol)
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                Text(isApplication ? "▣" : "⚙").font(.system(size: 14, weight: .medium))
            }
        }
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .frame(width: 28, height: 28)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)

    }
}

@MainActor
extension Launcher {
    var canStartIndexFromLauncher: Bool {
        indexWork == nil && (indexPhase == .needsIndex || indexPhase == .unreadable || scopePending ||
                             (indexPhase == .ready && watchState == .needsSetup))
    }

    var launcherActivityTitle: String? {
        if canSearch && !activityBusy && watchState == .running { return nil }
        return activityTitle
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
            if watchState == .running { return t("正在监听文件变化", "Watching file changes") }
            if watchState == .failed { return t("文件监听已停止", "File watching stopped") }
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

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, index, quicklinks, translation
    case advanced, scripts

    var id: Self { self }

    @MainActor func title(_ model: Launcher) -> String {
        switch self {
        case .general: return model.t("通用与快捷键", "General & Shortcuts")
        case .index: return model.t("索引与隐私", "Index & Privacy")
        case .quicklinks: return model.t("快捷链接", "Quicklinks")
        case .translation: return model.t("翻译", "Translation")
        case .advanced: return model.t("高级与诊断", "Advanced & Diagnostics")
        case .scripts: return model.t("脚本与快捷指令", "Scripts & Shortcuts")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .index: return "folder.badge.gearshape"
        case .quicklinks: return "link"
        case .translation: return "character.bubble"
        case .advanced: return "waveform.path.ecg"
        case .scripts: return "terminal"
        }
    }
}

enum ScopeFolders {
    case include, exclude, content

    var paths: WritableKeyPath<IndexScope, [String]> {
        switch self {
        case .include: return \.allow
        case .exclude: return \.deny
        case .content: return \.contentFolders
        }
    }

    @MainActor func title(_ model: Launcher) -> String {
        switch self {
        case .include: return model.t("仅包括", "Include Only")
        case .exclude: return model.t("排除", "Exclude")
        case .content: return model.t("正文与语义目录", "Text and Semantic Folders")
        }
    }
}

@MainActor
final class SettingsSession: ObservableObject {
    let model: Launcher
    private let pageChanged: (SettingsPage?, SettingsPage?) -> Void
    @Published var page: SettingsPage? = .general {
        didSet { if page != oldValue { pageChanged(oldValue, page) } }
    }
    @Published private(set) var draft: IndexScope?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var loginItemFailed = false
    let canManageLoginItem: Bool

    init(model: Launcher, manageLoginItem: Bool, pageChanged: @escaping (SettingsPage?, SettingsPage?) -> Void) {
        self.model = model
        self.pageChanged = pageChanged
        canManageLoginItem = manageLoginItem && Bundle.main.bundleURL.pathExtension == "app"
    }

    func refreshLoginItem() {
        guard canManageLoginItem else { return }
        let status = SMAppService.mainApp.status
        loginItemNeedsApproval = status == .requiresApproval
        launchAtLogin = status == .enabled || loginItemNeedsApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard canManageLoginItem else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemFailed = false
        } catch { loginItemFailed = true }
        refreshLoginItem()
    }

    private var baseline: IndexScope {
        var scope = model.settingsScope
        // The engine materializes derived roots in the saved scope.
        if scope.roots == scope.allow || (scope.roots == ["/"] && scope.allow.isEmpty) { scope.roots = [] }
        return scope
    }

    var scope: IndexScope { draft ?? baseline }
    var hasChanges: Bool { draft.map { $0 != baseline } ?? false }

    var canEditScope: Bool {
        model.indexPhase != .checking && (model.savedScope != nil || model.needsScopeSetup)
    }
    var canApply: Bool { canEditScope && model.canApplyScope && (hasChanges || model.needsScopeSetup) }

    var canRebuild: Bool {
        model.canApplyScope && model.savedScope != nil && model.indexPhase == .ready && !model.scopePending
    }

    func setDocuments(_ enabled: Bool) {
        var next = scope
        next.documents = enabled
        draft = next
    }

    func add(_ urls: [URL], to group: ScopeFolders) {
        var next = scope
        var seen = Set(next[keyPath: group.paths])
        let paths = urls.filter(\.isFileURL).map(IndexScope.folderPath)
        next[keyPath: group.paths].append(contentsOf: paths.filter { seen.insert($0).inserted })
        if next != scope { draft = next }
    }

    func remove(_ path: String, from group: ScopeFolders) {
        var next = scope
        next[keyPath: group.paths].removeAll { $0 == path }
        if next != scope { draft = next }
    }

    func discard() { draft = nil }

    func apply() {
        guard canApply else { return }
        let requested = scope
        draft = nil
        model.applyScope(requested)
    }
}

struct LauncherSettings: View {
    @ObservedObject var model: Launcher
    @ObservedObject var session: SettingsSession
    let translation: TranslationPanelModel
    let volumes: ExternalVolumeCatalog
    let images: LauncherImageSearch
    let clipboard: ClipboardManager
    @ObservedObject var scriptCatalog: LauncherScriptCatalog
    let chooseScriptsFolder: () -> Void
    let chooseImageFolder: () -> Void
    let chooseImageProjector: () -> Void
    let chooseQuicklinkFolder: (@escaping (URL) -> Void) -> Void
    let recordShortcut: (NSEvent) -> Void
    let disableShortcut: () -> Void
    let chooseDirectories: (ScopeFolders) -> Void
    let chooseDiagnosticFile: () -> Void
    @State private var confirmRebuild = false
    @FocusState private var sidebarFocus: SettingsPage?

    private var page: SettingsPage { session.page ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                switch page {
                case .quicklinks:
                    pageHeading.padding(.horizontal, 28).padding(.top, 26)
                    QuicklinksView(model: model, library: model.shortcuts, chooseFolder: chooseQuicklinkFolder)
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 19) {
                            pageHeading
                            switch page {
                            case .general: general
                            case .index: indexAndPrivacy
                            case .scripts: scriptsAndShortcuts
                            case .translation:
                                group(model.t("模型与提供商", "Model & Providers")) {
                                    TranslationSettingsView(model: translation, chinese: model.zh)
                                }
                            case .advanced:
                                background
                                about
                            default: EmptyView()
                            }
                        }
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 26)
                        .frame(maxWidth: .infinity)
                    }
                    .id(page)
                    if page == .index { applyBar }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 700, minHeight: 488)
        .labeledContentStyle(SettingsValueStyle())
    }

    private var pageHeading: some View {
        Text(page.title(model))
            .font(.system(size: 26, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(SettingsPage.allCases) { item in
                    let selected = item == page
                    Button {
                        session.page = item
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .foregroundStyle(selected ? .primary : .secondary)
                                .frame(width: 20)
                            Text(item.title(model))
                                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background {
                            if selected { RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.085)) }
                        }
                        .overlay {
                            if sidebarFocus == item {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($sidebarFocus, equals: item)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("settings.page.\(item.rawValue)")
                }
            }
            .padding(.horizontal, 11)
            .padding(.top, 18)
            .onMoveCommand(perform: navigateSidebar)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.t("设置页面", "Settings Pages"))
        .frame(width: 204)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func navigateSidebar(_ direction: MoveCommandDirection) {
        guard let current = sidebarFocus, let index = SettingsPage.allCases.firstIndex(of: current) else { return }
        let next: Int
        switch direction {
        case .up: next = index - 1
        case .down: next = index + 1
        default: return
        }
        guard SettingsPage.allCases.indices.contains(next) else { return }
        let destination = SettingsPage.allCases[next]
        sidebarFocus = destination
        session.page = destination
    }

    @ViewBuilder private var scriptsAndShortcuts: some View {
        group(model.t("本地脚本", "Local Scripts")) {
            Toggle(model.t("启用本地脚本", "Enable Local Scripts"), isOn: Binding(
                get: { scriptCatalog.scriptsEnabled }, set: { scriptCatalog.setScriptsEnabled($0) }
            ))
            .disabled(scriptCatalog.folder == nil)
            .accessibilityIdentifier("settings.scripts.enabled")
            if let folder = scriptCatalog.folder {
                LabeledContent(model.t("脚本文件夹", "Scripts Folder")) {
                    Text((folder as NSString).abbreviatingWithTildeInPath).textSelection(.enabled)
                }
            }
            HStack {
                Button(model.t("选择文件夹…", "Choose Folder…"), action: chooseScriptsFolder)
                    .accessibilityIdentifier("settings.scripts.choose")
                if scriptCatalog.folder == nil {
                    Button(model.t("创建默认文件夹并启用", "Create Default Folder & Enable"), action: scriptCatalog.createAndEnable)
                        .disabled(scriptCatalog.scriptLoading)
                }
                Button(model.t("重新载入脚本", "Reload Scripts"), action: scriptCatalog.reloadScripts)
                    .disabled(!scriptCatalog.scriptsEnabled || scriptCatalog.scriptLoading)
            }
            if scriptCatalog.scriptLoading { note(model.t("正在读取脚本…", "Loading scripts…")) }
            else if scriptCatalog.scriptFailed {
                note(model.t("无法读取该文件夹。请选择本机非链接目录。", "Could not read the folder. Choose a resident folder that is not a link."))
            } else {
                note(model.t("\(scriptCatalog.scripts.count) 个脚本", "Scripts available: \(scriptCatalog.scripts.count)"))
            }
            note(model.t("仅搜索该文件夹内的可执行文件。脚本拥有您的权限；请仅启用您信任的脚本。运行时会使用本地副本，工作目录仍为所选文件夹。",
                         "Only executables directly inside the folder are listed. Scripts run with your permissions; enable only scripts you trust. Scripts run from a local copy with the selected folder as their working directory."))
        }
        group(model.t("Apple 快捷指令", "Apple Shortcuts")) {
            Toggle(model.t("启用 Apple 快捷指令", "Enable Apple Shortcuts"), isOn: Binding(
                get: { scriptCatalog.shortcutsEnabled }, set: { scriptCatalog.setShortcutsEnabled($0) }
            ))
            .accessibilityIdentifier("settings.apple-shortcuts.enabled")
            Button(model.t("刷新快捷指令", "Refresh Shortcuts"), action: scriptCatalog.refreshShortcuts)
                .disabled(!scriptCatalog.shortcutsEnabled || scriptCatalog.shortcutLoading)
            if scriptCatalog.shortcutLoading { note(model.t("正在读取快捷指令…", "Loading Shortcuts…")) }
            else if scriptCatalog.shortcutFailed { note(model.t("无法读取快捷指令。", "Could not list Shortcuts.")) }
            else { note(model.t("\(scriptCatalog.shortcuts.count) 个快捷指令", "Shortcuts available: \(scriptCatalog.shortcuts.count)")) }
            note(model.t("列表仅保存在内存中。重新启动 Lumen 后，请手动刷新。",
                         "The list is kept in memory only. Refresh it after restarting Lumen."))
        }
    }

    @ViewBuilder private var general: some View {
        group(model.t("启动", "Startup")) {
            Toggle(model.t("登录时启动", "Launch at Login"), isOn: Binding(
                get: { session.launchAtLogin }, set: { session.setLaunchAtLogin($0) }
            ))
            .disabled(!session.canManageLoginItem)
            .accessibilityIdentifier("settings.launch-at-login")
            .onAppear { session.refreshLoginItem() }
            if session.loginItemNeedsApproval {
                Button(model.t("打开登录项设置…", "Open Login Items Settings…")) {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            if session.loginItemFailed {
                note(model.t("无法更改登录项。请检查 macOS 登录项设置。",
                             "Could not change this login item. Check macOS Login Items settings."))
            }
        }
        group(model.t("语言", "Language")) {
            LabeledContent(model.t("界面语言", "Interface Language")) {
                Picker(model.t("界面语言", "Interface Language"), selection: $model.language) {
                    Text(model.t("跟随系统", "System")).tag("system")
                    Text("简体中文").tag("zh")
                    Text("English").tag("en")
                }
                .labelsHidden()
            }
        }
        group(model.t("打开搜索", "Open Search")) {
            LabeledContent(model.t("全局快捷键", "Global Shortcut")) {
                HStack(spacing: 9) {
                    Text(model.hotKey?.label ?? model.t("未设置", "Off")).monospaced()
                        .accessibilityIdentifier("settings.shortcut.value")
                    ShortcutControl(model: model, record: recordShortcut).fixedSize()
                    Button(model.t("停用", "Disable"), action: disableShortcut)
                        .disabled(model.hotKey == nil && model.hotKeyIssue == nil)
                }
            }
            if let issue = model.hotKeyIssue {
                Label(issue.title(model), systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.hotKey?.cyclesMacWindows == true {
                note(model.t("macOS 也使用 ⌘` 切换窗口。", "macOS also uses ⌘` to cycle windows."))
            }
            note(model.t("菜单栏中的「打开搜索」始终可用。", "Open Search is always available in the menu bar."))
        }
        group(model.t("剪贴板历史", "Clipboard History")) {
            ClipboardSettingsView(clipboard: clipboard, chinese: model.zh)
        }
        .onAppear { clipboard.loadHistory() }
    }

    @ViewBuilder private var indexAndPrivacy: some View {
        group(model.t("正文索引", "Document Text")) {
            folderRows(.content, empty: model.t("请选择要建立正文和语义索引的目录。", "Choose folders to index for text and semantic search."))
            note(model.t("所选目录内的 TXT、Markdown、DOCX 和 PDF 文本层可检索。云端文件仍只索引名称。",
                         "Search TXT, Markdown, DOCX, and PDF text in selected folders. Cloud files remain name-only."))
            if let coverage = model.contentCoverage, coverage.total > 0 {
                ProgressView(value: Double(coverage.checked), total: Double(coverage.total)) {
                    Text(model.t("已处理 \(coverage.checked) / \(coverage.total) 份文档", "\(coverage.checked) of \(coverage.total) documents checked"))
                }
                if model.contentPaused || model.contentFailed {
                    Button(model.t("继续正文索引", "Resume Document Indexing")) { model.setContentPaused(false) }
                } else if coverage.pending > 0 {
                    Button(model.t("暂停正文索引", "Pause Document Indexing")) { model.setContentPaused(true) }
                }
            }
        }
        group(model.t("索引范围", "Index Scope")) {
            note(model.t("只扫描 macOS 允许访问的位置。排除规则优先，包括已添加的子目录。",
                         "Lumen scans locations macOS allows it to access. Exclusions take priority, including over included subfolders."))
            if !session.scope.roots.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("现有扫描根目录", "Existing Scan Roots")).font(.callout.weight(.medium))
                    ForEach(Array(Set(session.scope.roots)).sorted(), id: \.self) { path in
                        pathLabel(path)
                    }
                    note(model.t("下列规则在这些根目录内生效。", "The rules below apply within these scan roots."))
                }
            }
            folderRows(.include, empty: model.t("留空时索引启动盘的可访问位置。", "Leave empty to include accessible locations on the startup disk."),
                       constrainedEmpty: model.t("当前扫描根目录内的所有可访问位置。", "All accessible locations within the current scan roots."))
            Divider().accessibilityHidden(true)
            folderRows(.exclude, empty: model.t("没有手动排除的目录。", "No folders excluded manually."))
        }
        .disabled(!session.canEditScope)
        group(model.t("图像内容", "Image Content")) {
            LauncherImageSettings(launcher: model, images: images, chooseFolder: chooseImageFolder,
                                  chooseProjector: chooseImageProjector)
        }
        group(model.t("外置卷", "External Volumes")) {
            LauncherExternalVolumes(launcher: model, catalog: volumes, changed: model.externalVolumesChanged)
                .accessibilityIdentifier("settings.external-volumes")
        }
        if let notice = model.indexNotice {
            NoticeView(model: model, notice: notice)
        }
    }

    private func folderRows(_ group: ScopeFolders, empty: String, constrainedEmpty: String? = nil) -> some View {
        let title = group.title(model)
        let paths = Array(Set(session.scope[keyPath: group.paths])).sorted()
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.callout.weight(.medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    chooseDirectories(group)
                } label: {
                    Label(model.t("添加目录…", "Add Folder…"), systemImage: "plus")
                }
                .controlSize(.small)
                .accessibilityLabel(model.t("添加目录到「\(title)」", "Add Folder to \(title)"))
                .accessibilityIdentifier(group == .content ? "settings.content.add" : "settings.scope.add")
            }
            if paths.isEmpty {
                note(!session.scope.roots.isEmpty ? constrainedEmpty ?? empty : empty)
            }
            ForEach(paths, id: \.self) { path in
                HStack(spacing: 8) {
                    pathLabel(path)
                    Button {
                        session.remove(path, from: group)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(model.t("移除目录", "Remove Folder"))
                    .accessibilityLabel(model.t("移除目录 \(path)", "Remove Folder \(path)"))
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func pathLabel(_ path: String) -> some View {
        Label {
            Text(path).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "folder")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(path)
    }

    private var applyBar: some View {
        HStack(spacing: 12) {
            if session.hasChanges {
                note(model.t("有未应用的更改", "Unapplied changes"))
                Button(model.t("还原", "Revert")) { session.discard() }
                    .buttonStyle(.borderless)
            } else if model.isIndexing {
                note(model.activityTitle)
            } else if !session.canEditScope && model.indexPhase == .ready {
                note(model.t("当前索引的已保存范围不可用。", "The saved scope for this index is unavailable."))
            }
            Spacer()
            Button(model.indexPhase == .needsIndex ? model.t("建立索引", "Build Index")
                   : model.t("应用并更新索引", "Apply and Update Index")) { session.apply() }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canApply)
                .accessibilityIdentifier("settings.index.apply")
        }
        .padding(.horizontal, 28).padding(.vertical, 13)
        .background(alignment: .top) { Divider() }
    }

    @ViewBuilder private var background: some View {
        group(model.t("文件变化与扫描", "File Changes and Scans")) {
            Text(watchLabel)
            if let metrics = model.activityMetrics {
                if let progress = model.activeProgress, let fraction = progress.fraction {
                    ProgressView(metrics, value: fraction)
                } else {
                    Text(metrics).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else if model.isIndexing {
                ProgressView(model.activityTitle).controlSize(.small)
            }
            if let notice = model.watchNotice { NoticeView(model: model, notice: notice) }
        }
        group(model.t("本机语义搜索", "On-Device Semantic Search")) {
            LabeledContent(model.t("模型", "Model"), value: "EmbeddingGemma 2")
            localModelStatus
            semanticIndexStatus
            embeddingControls
            if let notice = model.embeddingNotice { NoticeView(model: model, notice: notice) }
            note(model.t("暂停语义索引时，文件变化仍会自动更新。",
                         "File changes continue to update while semantic indexing is paused."))
        }
    }

    @ViewBuilder private var about: some View {
        group("Lumen") {
            LabeledContent(model.t("版本", "Version"), value: version)
            LabeledContent(model.t("当前状态", "Current Status"), value: model.activityTitle)
        }
        group(model.t("索引统计", "Index Counts")) {
            if let report = model.indexReport {
                count(model.t("索引项目", "Indexed Items"), report.items)
                if let value = report.documents { count(model.t("已索引正文", "Documents with Indexed Text"), value) }
                if let value = report.placeholders { count(model.t("云端占位项目", "Online-Only Items"), value) }
                if let value = report.entries_unreadable, value > 0 { count(model.t("无法访问", "Inaccessible Entries"), value) }
                if let value = report.unverified, value > 0 { count(model.t("待验证项目", "Unverified Items"), value) }
                if let value = report.documents_not_read, value > 0 { count(model.t("正文未读取", "Documents Without Readable Text"), value) }
            } else {
                note(model.indexPhase == .checking ? model.activityTitle
                     : model.t("尚无索引统计。", "Index counts are unavailable."))
            }
        }
        diagnostics
        DisclosureGroup(model.t("高级维护", "Advanced Maintenance")) {
            VStack(alignment: .leading, spacing: 8) {
                note(model.t("按当前已生效的范围重新扫描，保留未应用的设置草稿。",
                             "Rescan the currently saved scope. Unapplied edits stay in their draft."))
                Button(model.t("重建索引…", "Rebuild Index…")) { confirmRebuild = true }
                    .disabled(!session.canRebuild)
                    .confirmationDialog(model.t("按当前范围重建索引？", "Rebuild the Index Using the Saved Scope?"),
                                        isPresented: $confirmRebuild, titleVisibility: .visible) {
                        Button(model.t("重建", "Rebuild")) { model.rebuildSavedIndex() }
                        Button(model.t("取消", "Cancel"), role: .cancel) {}
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .font(.callout)
    }

    private var diagnostics: some View {
        group(model.t("文件诊断", "File Diagnostics")) {
            HStack(alignment: .firstTextBaseline) {
                note(model.t("检查所选文件的名称、正文和语义索引状态。",
                             "Check the name, text, and semantic coverage of a selected file."))
                Spacer(minLength: 12)
                Button(model.t("选取文件…", "Choose File…"), action: chooseDiagnosticFile)
                    .disabled(model.scopePending)
                    .accessibilityIdentifier("settings.diagnostics.choose")
            }
            switch model.fileDiagnosis {
            case .idle:
                EmptyView()
            case .checking(let name):
                ProgressView(name).controlSize(.small)
            case .failed(let name):
                Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                note(model.t("无法获取此文件的诊断结果。", "Could not read diagnostics for this file."))
            case .result(let name, let result):
                Divider().accessibilityHidden(true)
                HStack {
                    Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(model.t("清除", "Clear")) { model.clearFileDiagnosis() }
                        .buttonStyle(.borderless)
                }
                LabeledContent(model.t("名称", "Name"), value: diagnosisText(result.name))
                LabeledContent(model.t("正文", "Document Text"), value: diagnosisText(result.text))
                LabeledContent(model.t("语义", "Semantic"), value: diagnosisText(result.semantic))
            }
        }
    }

    private func diagnosisText(_ reason: String) -> String {
        switch reason {
        case "indexed": return model.t("已索引", "Indexed")
        case "not_indexed": return model.t("尚未索引", "Not yet indexed")
        case "stale": return model.t("文件已变化，等待更新", "File changed, waiting for an update")
        case "unverified": return model.t("等待验证访问权限", "Awaiting access verification")
        case "index_unavailable": return model.t("索引不可用", "Index unavailable")
        case "scope_unknown": return model.t("已保存的索引范围不可用", "Saved scope unavailable")
        case "excluded": return model.t("已被范围或隐私规则排除", "Excluded by scope or privacy rules")
        case "outside_scope": return model.t("不在索引范围内", "Outside the index scope")
        case "missing": return model.t("文件已不存在", "File missing")
        case "unreadable": return model.t("无法访问文件", "File is inaccessible")
        case "symlink": return model.t("符号链接", "Symbolic link")
        case "not_file": return model.t("非常规文件", "Not a regular file")
        case "cloud_ancestor": return model.t("所在云端目录尚未下载", "The containing cloud folder is online-only")
        case "cloud_name_only": return model.t("云端项目，仅索引名称和路径", "Online-only, indexed by name and path")
        case "outside_content_scope": return model.t("不在所选正文目录内", "Outside the selected document folders")
        case "text_disabled": return model.t("正文索引已关闭", "Document indexing is off")
        case "unsupported": return model.t("文件类型不受支持", "Unsupported file type")
        case "pdf_helper_unconfigured": return model.t("PDF 文本提取不可用", "PDF text extraction is unavailable")
        case "pending_gemma": return model.t("等待建立语义索引", "Awaiting semantic indexing")
        case "gemma_limited": return model.t("语义索引已达到存储上限", "Semantic index storage limit reached")
        case "gemma_skipped": return model.t("语义索引已跳过此文件", "Skipped during semantic indexing")
        default: return model.t("无法确认", "Unknown")
        }
    }

    private var version: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return version }
        return "\(version) (\(build))"
    }

    private func count(_ label: String, _ value: Int) -> some View {
        LabeledContent(label, value: value.formatted())
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
                        .allowsHitTesting(false)
                }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var embeddingControls: some View {
        switch model.embeddingState {
        case .verifying, .running, .pausing:
            Button(model.t("暂停语义索引", "Pause Semantic Indexing")) { model.pauseEmbeddings(userInitiated: true) }
                .disabled(model.embeddingState == .pausing)
            if model.embeddingState == .pausing {
                Text(model.t("正在完成当前批次，随后暂停。", "Indexing will pause after the current batch."))
                    .foregroundStyle(.secondary)
            }
        case .idle, .paused, .finished:
            if model.gemmaCoverage?.pending == true && model.gemmaCoverage?.limited == false {
                Button(model.embeddingState == .paused
                       ? model.t("继续生成语义索引", "Resume Semantic Indexing")
                       : model.t("生成语义索引", "Build Semantic Index")) {
                    model.buildEmbeddings()
                }
                .disabled(!model.canBuildEmbeddings)
            }
            if model.embeddingState == .paused && model.embeddingNotice == nil {
                Text(model.t("已暂停。已完成的片段已保存，可以继续生成。",
                             "Indexing is paused. Completed chunks are saved and indexing can resume."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var localModelStatus: some View {
        switch model.localModelState {
        case .unchecked:
            EmptyView()
        case .available:
            Label(model.t("已找到本机模型和运行环境", "Local model and runtime found"), systemImage: "internaldrive")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView(model.t("正在校验本机 Gemma 资源…", "Verifying local Gemma resources…")).controlSize(.small)
        case .ready:
            Label(model.t("本机 Gemma 模型已就绪", "Local Gemma model ready"), systemImage: "checkmark.circle")
        case .unavailable(let issue):
            Label(model.modelDiagnostic(issue), systemImage: "info.circle")
                .foregroundStyle(.secondary)
            if !model.canBuildEmbeddings && model.indexWork != .embeddings {
                Button(model.t("重新检查本机模型", "Recheck Local Model")) { model.verifyLocalModel() }
            }
        }
    }

    @ViewBuilder private var semanticIndexStatus: some View {
        if let coverage = model.gemmaCoverage {
            let count = coverage.embedded_chunks.formatted()
            let limit = coverage.chunk_limit.formatted()
            if !coverage.documents_enabled {
                Text(model.t("启用正文索引才能生成语义索引。", "Enable document indexing to build a semantic index."))
            } else if coverage.limited && coverage.hasResults {
                Text(model.t("已达到 \(limit) 段的存储上限。已建立索引的 \(count) 段仍可检索。",
                             "Storage limit reached (\(limit) chunks). The \(count) indexed chunks are still searchable."))
            } else if coverage.limited {
                Text(model.t("已达到语义索引存储上限。", "The semantic index reached its storage limit."))
            } else if coverage.complete {
                Text(model.t("语义索引已就绪，包含 \(count) 段。", "Semantic index ready with \(count) chunks."))
            } else if coverage.hasResults {
                Text(model.t("已有 \(count) 段可检索，仍有正文待处理。",
                             "Partial semantic index: \(count) searchable chunks, with more documents to process."))
            } else if model.indexWork == .embeddings || model.embeddingState == .verifying {
                Text(model.t("正在准备语义索引…", "Preparing the semantic index…"))
            } else if coverage.pending {
                Text(model.t("正文可用于生成本机语义索引。", "Documents are ready for local semantic indexing."))
            } else if coverage.skipped_chunks > 0 {
                let skipped = coverage.skipped_chunks.formatted()
                Text(model.t("已跳过 \(skipped) 段无法索引的正文。", "Skipped \(skipped) chunks that could not be indexed."))
            } else {
                Text(model.t("当前范围还没有可建立语义索引的正文。", "There is no document text to index in this scope yet."))
            }
        }
    }

    private var watchLabel: String {
        switch model.watchState {
        case .checking: return model.t("正在检查文件监听支持…", "Checking file watching support…")
        case .unavailable: return model.t("当前版本请手动更新索引。", "Use manual index updates in this version.")
        case .needsSetup: return model.t("在「索引与隐私」中应用范围后可监听文件变化。",
                                         "Apply a scope in Index & Privacy to watch for file changes.")
        case .paused: return model.t("索引范围应用成功后恢复文件监听。", "File watching resumes after the scope is applied.")
        case .starting: return model.t("正在核对索引与访问权限…", "Checking the saved index and file access…")
        case .running: return model.t("正在监听文件变化。", "Lumen is watching for file changes.")
        case .failed: return model.t("文件监听未运行。", "File watching is stopped.")
        }
    }
}

private struct SettingsValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content.multilineTextAlignment(.trailing)
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
        case .app: return model.t("⌘, 用于打开 Lumen 设置。请选择其他快捷键。",
                                  "⌘, opens Lumen Settings. Choose a different shortcut.")
        case .occupied: return model.t("此快捷键已被注册。请录制其他组合。",
                                       "This shortcut is already registered. Choose another combination.")
        case .registration(let status):
            return model.t("无法注册快捷键（系统状态 \(status)）。",
                           "Could not register the shortcut (system status \(status)).")
        }
    }
}
