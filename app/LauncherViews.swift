import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SearchWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: Launcher
    @ObservedObject var applicationIcons: ResultIconDisplay
    @ObservedObject var contextActions: ContextActions
    @ObservedObject var translation: TranslationPanelModel
    @ObservedObject var commands: LauncherCommands
    @ObservedObject var windowManagement: WindowManagement
    @ObservedObject var inlinePreview: LauncherInlinePreview
    @ObservedObject var imageSearch: LauncherImageSearch
    let clipboard: ClipboardManager
    let selectClipboard: (Int64) -> Void
    let previewClipboard: (ClipboardItem) -> Void
    let activateCommand: () -> Void
    let activateExecution: () -> Void
    let copyOutput: () -> Void
    let cancelExecution: () -> Void
    let copyDefinition: () -> Void
    let closeDefinition: () -> Void
    let searchCommandAsFiles: () -> Void
    let closeInlinePreview: () -> Void
    let activateTranslation: () -> Void
    let toggleContextActions: () -> Void
    let showSettings: () -> Void
    let openSnippets: (String?) -> Void
    let beginIndex: () -> Void
    let open: (LauncherResult) -> Void
    let selectRow: (LauncherResult, Bool) -> Void
    let moveSelection: (Int) -> Void
    let fileAction: (FileAction, SearchHit) -> Void
    let contextItemsForResult: (LauncherResult) -> [ContextActions.Item]
    let dismissFileDialog: () -> Void
    let dismissContext: () -> Void
    let replaceTranslationSelection: () -> Void

    static let headerHeight: CGFloat = PanelGeometry.headerHeight
    static let footerHeight: CGFloat = PanelGeometry.footerHeight
    static let maximumVisibleRows = PanelGeometry.maximumVisibleRows

    private static func rowHeight(_ hit: SearchHit) -> CGFloat { hit.hasPreview ? PanelGeometry.previewRowHeight : PanelGeometry.standardRowHeight }

    private var showsResults: Bool { model.showsResults }

    var body: some View {
        let state = PanelState.resolve(
            model: model,
            commands: commands,
            translation: translation,
            contextActions: contextActions,
            inlinePreview: inlinePreview
        )
        VStack(spacing: 0) {
            if let dialog = model.activeFileDialog {
                FileDialogBanner(dialog: dialog, chinese: model.zh, dismiss: dismissFileDialog)
                    .frame(height: FileDialogBanner.launcherHeight)
            }
            if let context = model.activeContext {
                SelectionContextBanner(context: context, chinese: model.zh, dismiss: dismissContext)
                    .frame(height: SelectionContextBanner.launcherHeight)
            }
            switch (state.mode, state.overlay) {
            case (.scriptOutput(let execution), _):
                LauncherCommandOutputCard(commands: commands, execution: execution, chinese: model.zh,
                                          run: activateExecution, copy: copyOutput, cancel: cancelExecution)
            case (.translation(let command), _):
                TranslationResultCard(
                    model: translation,
                    command: command,
                    chinese: model.zh,
                    activate: activateTranslation,
                    contextBadge: model.activeContext?.textPayload != nil
                        ? model.activeContext?.badgeTitle(chinese: model.zh)
                        : nil,
                    canReplaceSelection: model.activeContext?.canReplaceInPlace == true,
                    onReplaceSelection: replaceTranslationSelection
                )
            case (.imageSetup, _):
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.t("图像搜索", "Image Search"), systemImage: "photo")
                        .font(.headline)
                    Text(imageSearch.loading
                         ? model.t("正在读取图像设置…", "Checking image settings…")
                         : model.t("在「索引与隐私」选择本地目录和图像模型，再建立图像索引。",
                                   "Choose a local folder and image model in Index & Privacy, then build the image index."))
                        .foregroundStyle(.secondary)
                    Button(model.t("打开图像设置…", "Open Image Settings…"), action: showSettings)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            case (.clipboard, .contextMenu):
                contextRows
            case (.clipboard, _):
                ClipboardHistoryView(commands: commands, clipboard: clipboard, chinese: model.zh,
                                     select: selectClipboard, copy: activateCommand, openSettings: showSettings,
                                     onOpenPreview: previewClipboard, onOpenSnippets: openSnippets)
            case (.window, _):
                windowRowsView
            case (.commandCard, _):
                LauncherCommandCard(
                    commands: commands,
                    provider: translation,
                    chinese: model.zh,
                    activate: activateCommand,
                    openSettings: showSettings,
                    contextBadge: model.activeContext?.textPayload != nil
                        ? model.activeContext?.badgeTitle(chinese: model.zh)
                        : nil
                )
            case (.definition(let word, let text, let loading), _):
                LauncherDefinitionCard(commands: commands, word: word, text: text, loading: loading,
                                       chinese: model.zh, copy: copyDefinition, close: closeDefinition)
            case (.search, .contextMenu):
                contextRows
            case (.search, .inlinePreview(let hit)):
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
                        MacInlinePreviewView(
                            state: inlinePreview.state,
                            image: inlinePreview.image,
                            language: model.zh ? .simplifiedChinese : .english,
                            onWebContainerReady: { [weak inlinePreview] container in
                                inlinePreview?.activeWebContainer = container
                            }
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(width: 410)
                }
            case (.search, .localQuickLook), (.search, .none):
                if showsResults {
                    results.overlay {
                        if model.visibleResults.isEmpty {
                            Text(emptyResultsLabel)
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(16)
                        }
                    }
                }
            }
            if windowManagement.issue == .permissionRequired {
                WindowAccessibilityBanner(model: model, openSettings: windowManagement.openAccessibilitySettings)
                    .frame(height: WindowAccessibilityBanner.launcherHeight)
            }
            footer(for: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func footer(for state: PanelState) -> some View {
        let isTranslation: Bool
        if case .translation = state.mode { isTranslation = true }
        else { isTranslation = false }
        return HStack(spacing: 12) {
            switch state.mode {
            case .scriptOutput(let execution):
                keyHint("esc", execution.running ? model.t("取消", "Cancel") : model.t("关闭结果", "Close Result"))
                if execution.command.mode == .fullOutput && execution.hasOutput {
                    keyHint("PgUp/PgDn", model.t("翻页", "Scroll"))
                }
                Spacer(minLength: 8)
            case .translation:
                if translation.activity == .translating {
                    keyHint("esc", model.t("取消", "Cancel"))
                } else if !translation.output.isEmpty {
                    keyHint("↵", model.t("复制", "Copy"))
                    if model.activeContext?.canReplaceInPlace == true {
                        keyHint("⌘↵", model.t("替换原文本", "Replace Selection"))
                    }
                    if translation.copied { Text(model.t("已复制", "Copied")).accessibilityIdentifier("translation-copied") }
                } else if translation.canTranslate {
                    keyHint("↵", model.t("翻译", "Translate"))
                }
                Spacer(minLength: 8)
            case .definition(_, let text, let loading):
                keyHint("esc", model.t("关闭", "Close"))
                if !loading, let text, !text.isEmpty {
                    keyHint("↵", model.t("复制", "Copy"))
                    keyHint("PgUp/PgDn", model.t("翻页", "Scroll"))
                    if commands.definitionCopied { Text(model.t("已复制", "Copied")) }
                }
                Spacer(minLength: 8)
            case .imageSetup, .clipboard, .window, .commandCard:
                commandFooter(overlay: state.overlay)
            case .search:
                searchFooter(overlay: state.overlay)
            }
            Button(action: showSettings) {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.t("设置", "Settings"))
            .help(isTranslation ? model.t("翻译设置", "Translation Settings")
                  : model.t("设置与索引详情", "Settings and index details"))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .frame(height: Self.footerHeight)
        .background(.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private func commandFooter(overlay: PanelOverlay) -> some View {
        switch commands.resolution {
        case .discovery:
            keyHint("↑↓", model.t("选择", "Select"))
            keyHint("↵", model.t("填入命令", "Fill Command"))
        case .clipboard:
            if case .contextMenu = overlay {
                keyHint("↑↓", model.t("选择操作", "Select Action"))
                keyHint("↵", model.t("执行", "Run"))
            } else if let item = commands.selectedClipboardItem {
                keyHint("↑↓", model.t("选择", "Select"))
                keyHint("↵", model.t("复制", "Copy"))
                if item.text == nil {
                    keyHint(model.t("空格", "Space"), model.t("预览", "Preview"))
                }
                Button(action: toggleContextActions) { keyHint("⌘K", model.t("操作", "Actions")) }
                    .buttonStyle(.borderless)
            }
        case .window:
            keyHint("↑↓", model.t("选择", "Select"))
            keyHint("↵", model.t("应用布局", "Apply"))
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

    @ViewBuilder private func searchFooter(overlay: PanelOverlay) -> some View {
        if model.isImageSearch {
            Label(model.t("图像内容", "Image Content"), systemImage: "photo")
        }
        if showsResults {
            keyHint("↑↓", model.t("选择", "Select"))
            if let dialog = model.activeFileDialog {
                switch model.selectedResult {
                case .file(let file):
                    let isDir = file.kind == "directory"
                    let enterLabel = (isDir || dialog.kind == .save)
                        ? model.t("跳转此目录", "Jump to Folder")
                        : model.t("在弹窗中选中", "Select in Dialog")
                    keyHint("↵", enterLabel)
                    keyHint("⌘↵", fileActionTitle(model.secondaryFileAction(for: file)))
                    if isDir && !file.name.lowercased().hasSuffix(".app") {
                        keyHint("⇥", model.t("目录内搜索", "Search Inside"))
                    }
                case .finderFolder:
                    keyHint("↵", model.t("跳转此目录", "Jump to Folder"))
                    keyHint("⇥", model.t("目录内搜索", "Search Inside"))
                case .shortcut(let shortcut):
                    if case .folder = shortcut.target {
                        keyHint("↵", model.t("跳转此目录", "Jump to Folder"))
                        keyHint("⇥", model.t("目录内搜索", "Search Inside"))
                    } else {
                        keyHint("↵", fileActionTitle(.open))
                    }
                case .snippet:
                    keyHint("↵", model.t("粘贴", "Paste"))
                case .calculation:
                    keyHint("↵", model.t("复制", "Copy"))
                case .dictionary:
                    keyHint("↵", model.t("查看释义", "Define"))
                case .bookmark:
                    keyHint("↵", model.t("打开链接", "Open"))
                case .calendarEvent(let event):
                    keyHint("↵", event.meetingURL != nil ? model.t("入会", "Join") : model.t("打开", "Open"))
                case .reminder:
                    keyHint("↵", model.t("完成", "Complete"))
                case .contact, .action, .none:
                    keyHint("↵", fileActionTitle(.open))
                }
            } else {
                switch model.selectedResult {
                case .file(let file):
                    keyHint("↵", fileActionTitle(model.primaryFileAction(for: file)))
                    keyHint("⌘↵", fileActionTitle(model.secondaryFileAction(for: file)))
                    if file.kind == "directory", !file.name.lowercased().hasSuffix(".app") {
                        keyHint("⇥", model.t("目录内搜索", "Search Inside"))
                    } else if file.kind == "file" {
                        keyHint(model.t("空格 / ⌘Y", "Space / ⌘Y"), model.t("悬浮 / 侧边", "Window / Inline"))
                    }
                case .finderFolder:
                    keyHint("↵", fileActionTitle(.open))
                    keyHint("⇥", model.t("目录内搜索", "Search Inside"))
                case .shortcut(let shortcut):
                    keyHint("↵", fileActionTitle(.open))
                    if case .folder = shortcut.target {
                        keyHint("⇥", model.t("目录内搜索", "Search Inside"))
                    }
                case .snippet:
                    keyHint("↵", model.t("粘贴", "Paste"))
                case .calculation:
                    keyHint("↵", model.t("复制", "Copy"))
                case .dictionary:
                    keyHint("↵", model.t("查看释义", "Define"))
                case .bookmark:
                    keyHint("↵", model.t("打开链接", "Open"))
                case .calendarEvent(let event):
                    keyHint("↵", event.meetingURL != nil ? model.t("入会", "Join") : model.t("打开", "Open"))
                case .reminder:
                    keyHint("↵", model.t("完成", "Complete"))
                case .contact, .action, .none:
                    keyHint("↵", fileActionTitle(.open))
                }
            }
        }
        if !model.canSearch {
            Label(model.t("索引启动盘上的可访问文件", "Index accessible files on this Mac"), systemImage: "internaldrive")
                .lineLimit(1)
        }
        if let issue = windowManagement.issue, issue != .permissionRequired {
            Text(issue.title(model)).lineLimit(1).help(issue.title(model))
        } else if let notice = model.searchNotice, !model.visibleResults.isEmpty {
            Text(model.title(for: notice)).lineLimit(1).help(model.title(for: notice))
                .accessibilityIdentifier("launcher-notice")
        }
        Spacer(minLength: 8)
        if !showsResults {
            Label(model.t("筛选", "Filters"), systemImage: "line.3.horizontal.decrease")
                .help(model.t("kind:folder、ext:pdf 或 path:\"/Users/…/My Files/\"；也可直接输入绝对路径。",
                              "Try kind:folder, ext:pdf, or path:\"/Users/…/My Files/\". You can also type an absolute path."))
                .accessibilityIdentifier("query-filter-hints")
        }
        if !model.canSearch {
            Button(model.t("在后台建立索引", "Build in Background"), action: beginIndex)
                .buttonStyle(.borderless).fontWeight(.semibold)
                .accessibilityIdentifier("build-index")
        } else {
            keyHint("esc", escapeHintLabel(overlay: overlay))
        }
        if model.selectedResult != nil {
            Button(action: toggleContextActions) {
                keyHint("⌘K", model.t("操作", "Actions"))
            }
            .buttonStyle(.borderless)
        }
    }

    private func escapeHintLabel(overlay: PanelOverlay) -> String {
        if case .inlinePreview = overlay { return model.t("关闭预览", "Close Preview") }
        if case .contextMenu = overlay { return model.t("关闭操作", "Close Actions") }
        if model.activeScopedDirectory != nil && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model.t("退出目录", "Exit Folder")
        }
        if model.hasQuery { return model.t("清除", "Clear") }
        return model.t("关闭", "Close")
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4.5).padding(.vertical, 1.5)
                .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.primary.opacity(0.11), lineWidth: 0.75)
                }
            Text(action)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var results: some View {
        let highlight = LauncherHighlight(model.activeHighlightQuery)
        let selection = model.selectedID
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleResults) { result in
                        let selected = selection == result.id
                        switch result {
                        case .file(let hit): resultRow(hit, highlight: highlight, selected: selected).id(result.id)
                        case .action(let action): actionRow(action, highlight: highlight, selected: selected).id(result.id)
                        case .shortcut(let shortcut):
                            utilityRow(result, title: shortcut.title, detail: shortcut.detail, symbol: shortcut.symbol,
                                       highlight: highlight, selected: selected,
                                       badge: (model.t("快捷链接", "Quicklink"), "bolt", false)).id(result.id)
                        case .calculation(let calculation):
                            utilityRow(result, title: calculation.display,
                                       detail: calculation.detail ?? model.t("回车复制", "Return to Copy"),
                                       symbol: "plus.forwardslash.minus", highlight: nil, selected: selected,
                                       badge: calculation.detail != nil ? (model.t("汇率", "FX"), "banknote", false) : nil)
                            .id(result.id)
                        case .dictionary(let dict):
                            utilityRow(result, title: dict.word, detail: dict.summary, symbol: "book.closed",
                                       highlight: highlight, highlightDetail: false, selected: selected,
                                       detailTruncation: .tail,
                                       badge: (model.t("词典", "Dict"), "book.closed", false)).id(result.id)
                        case .bookmark(let bookmark):
                            utilityRow(result, title: bookmark.title.isEmpty ? bookmark.domain : bookmark.title,
                                       detail: bookmark.domain.isEmpty ? bookmark.browser : "\(bookmark.domain) · \(bookmark.browser)",
                                       symbol: "safari", highlight: highlight, selected: selected,
                                       badge: (model.t("书签", "Bookmark"), "bookmark", false)).id(result.id)
                        case .contact(let contact):
                            utilityRow(result, title: contact.fullName, detail: contact.subtitle,
                                       symbol: "person.crop.circle", highlight: highlight, selected: selected,
                                       detailTruncation: .tail,
                                       badge: (model.t("通讯录", "Contact"), "person.crop.circle", false)).id(result.id)
                        case .calendarEvent(let event):
                            utilityRow(result, title: event.title, detail: "\(event.dateSummary) · \(event.calendarTitle)",
                                       symbol: "calendar", highlight: highlight, selected: selected,
                                       detailTruncation: .tail,
                                       badge: event.meetingURL != nil
                                           ? (model.t("入会", "Join"), "video", true)
                                           : (model.t("日程", "Event"), "calendar", false)).id(result.id)
                        case .reminder(let reminder):
                            utilityRow(result, title: reminder.title, detail: "\(reminder.dueSummary) · \(reminder.listTitle)",
                                       symbol: reminder.isCompleted ? "checkmark.circle.fill" : "checklist",
                                       highlight: highlight, selected: selected, detailTruncation: .tail,
                                       badge: (model.t("提醒", "Reminder"), "checklist", false)).id(result.id)
                        case .snippet(let snippet):
                            snippetRow(snippet, highlight: highlight, selected: selected).id(result.id)
                        case .finderFolder(let folder):
                            utilityRow(result, title: folder.name,
                                       detail: (folder.path as NSString).abbreviatingWithTildeInPath,
                                       symbol: "folder.fill", highlight: highlight, selected: selected,
                                       badge: (model.t("访达窗口", "Finder"), "macwindow", true)).id(result.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: selection) { _, value in
                if let value { proxy.scrollTo(value) }
            }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(keys: [.return]) { press in
                guard press.modifiers.isEmpty, let result = model.selectedResult else { return .ignored }
                open(result)
                return .handled
            }
        }
    }

    private var windowRowsView: some View {
        let filterQuery: String = {
            if case .window(let payload) = commands.resolution { return payload }
            return ""
        }()
        let highlight = LauncherHighlight(filterQuery)
        let selection = commands.windowSelection
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(commands.windowRows.enumerated()), id: \.element.id) { index, action in
                        actionRow(action, highlight: highlight, selected: selection == index)
                            .id(action.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: selection) { _, index in
                if commands.windowRows.indices.contains(index) {
                    proxy.scrollTo(commands.windowRows[index].id)
                }
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

    private func snippetRow(_ snippet: SavedSnippet, highlight: LauncherHighlight, selected: Bool) -> some View {
        let expanded = model.snippets.expand(snippet, liveClipboardText: clipboard.currentPasteboardPreviewText())
        let titleText = snippet.displayTitle
        let expandedSingleLine = expanded
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let rawSingleLine = snippet.content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let detailText: String = {
            if !expandedSingleLine.isEmpty && expandedSingleLine != titleText {
                return expandedSingleLine
            }
            if ClipboardTemplateExpander.containsVariables(snippet.content) {
                return rawSingleLine
            }
            return model.t("常用短语", "Snippet")
        }()

        return HStack(spacing: 10) {
            Image(systemName: "text.quote").frame(width: 28, height: 28)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.text(titleText, size: 13, colorScheme: colorScheme, mode: .action))
                    .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text(verbatim: detailText)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(expanded)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if snippet.pinnedToHome {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(model.t("首页置顶", "Pinned to Home"))
                }
                Text(verbatim: snippet.alias)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.075), in: Capsule())
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .modifier(ResultRowChrome(selected: selected))
        .overlay { ActionRowClickView { selectRow(.snippet(snippet), $0 == 2) }.accessibilityHidden(true) }
        .contextMenu {
            ForEach(contextItemsForResult(.snippet(snippet))) { actionItem in
                Button {
                    actionItem.perform()
                } label: {
                    Label(actionItem.title, systemImage: actionItem.symbol)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(model.t("粘贴", "Paste"))) { open(.snippet(snippet)) }
    }

    private func utilityRow(_ result: LauncherResult, title: String, detail: String, symbol: String,
                            highlight: LauncherHighlight?, highlightDetail: Bool = true, selected: Bool,
                            detailTruncation: Text.TruncationMode = .middle,
                            badge: (title: String, symbol: String, emphasized: Bool)? = nil) -> some View {
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
                    .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text((highlightDetail ? highlight?.text(detail, size: 11, colorScheme: colorScheme) : nil) ?? AttributedString(detail))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(detailTruncation)
                    .help(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let badge {
                ResultCategory(title: badge.title, symbol: badge.symbol, emphasized: badge.emphasized)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .modifier(ResultRowChrome(selected: selected))
        .overlay { ActionRowClickView { selectRow(result, $0 == 2) }.accessibilityHidden(true) }
        .contextMenu {
            ForEach(contextItemsForResult(result)) { item in
                Button {
                    item.perform()
                } label: {
                    Label(item.title, systemImage: item.symbol)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(model.t("执行", "Run"))) { open(result) }
    }

    private var emptyResultsLabel: String {
        if let notice = model.searchNotice {
            if model.isImageSearch {
                return model.t("图像搜索失败。请检查本机图像模型。", "Image search failed. Check the local image model.")
            }
            return model.title(for: notice)
        }
        if model.searching {
            return model.t("正在搜索…", "Searching…")
        }
        if model.semanticBusy {
            return model.t("未找到字面匹配，正在查找相关原文…", "No literal matches — checking related excerpts…")
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
        case .window:
            category = ResultCategory(title: model.t("窗口管理", "Window Management"), symbol: "macwindow")
            detail = nil
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
        .overlay { ActionRowClickView { selectRow(.action(action), $0 == 2) }.accessibilityHidden(true) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(model.t("打开", "Open"))) { open(.action(action)) }
        .accessibilityIdentifier(action.id)
    }

    private func resultRow(_ hit: SearchHit, highlight: LauncherHighlight, selected: Bool) -> some View {
        fileRow(hit, highlight: highlight, selected: selected).onDrag {
            guard hit.isResident, model.containsCurrentFile(hit), let url = LocalFile.dragURL(for: hit) else {
                return NSItemProvider()
            }
            return NSItemProvider(object: url as NSURL)
        }
    }

    private func fileRow(_ hit: SearchHit, highlight: LauncherHighlight, selected: Bool) -> some View {
        let folder = hit.kind == "directory"
        return HStack(spacing: 10) {
            FileTypeIcon(hit: hit, directory: folder)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(highlight.text(hit.name, size: 13, colorScheme: colorScheme, mode: .name))
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if hit.isResident {
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
            if hit.isPlaceholder {
                Label(model.t("仅在线", "Online only"), systemImage: "icloud")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight(hit))
        .modifier(ResultRowChrome(selected: selected))
        .onTapGesture { selectRow(.file(hit), false) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { selectRow(.file(hit), true) })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(fileActionTitle(.open))) { fileAction(.open, hit) }
        .accessibilityAction(named: Text(fileActionTitle(.reveal))) { fileAction(.reveal, hit) }
        .accessibilityActions {
            if hit.kind == "file" && !hit.name.lowercased().hasSuffix(".app") {
                Button(model.t("内嵌预览", "Inline Preview")) { fileAction(.preview, hit) }
            }
            Button(model.t("复制名称", "Copy Name")) { fileAction(.copyName, hit) }
            Button(model.t("复制路径", "Copy Path")) { fileAction(.copyPath, hit) }
        }
        .contextMenu {
            let primary = model.primaryFileAction(for: hit)
            let secondary = model.secondaryFileAction(for: hit)
            Button("\(fileActionTitle(primary)) · ↵") { fileAction(primary, hit) }
            Button("\(fileActionTitle(secondary)) · ⌘↵") { fileAction(secondary, hit) }
            Button(model.t("内嵌预览 · ⌘Y", "Inline Preview · ⌘Y")) { fileAction(.preview, hit) }
                .disabled(hit.kind != "file" || hit.name.lowercased().hasSuffix(".app"))
            if hit.kind == "file" {
                Button(fileActionTitle(.searchInFolder)) { fileAction(.searchInFolder, hit) }
            }
            Divider()
            Button(model.t("复制名称 · ⇧⌘C", "Copy Name · ⇧⌘C")) { fileAction(.copyName, hit) }
            Button(model.t("复制路径 · ⌥⌘C", "Copy Path · ⌥⌘C")) { fileAction(.copyPath, hit) }
            Button(fileActionTitle(.copyFile)) { fileAction(.copyFile, hit) }
            Button(fileActionTitle(.openInTerminal)) { fileAction(.openInTerminal, hit) }
        }
    }

    private func fileActionTitle(_ action: FileAction) -> String {
        switch action {
        case .open: return model.t("打开", "Open")
        case .reveal: return model.t("在 Finder 中显示", "Show in Finder")
        case .preview: return model.t("内嵌预览", "Inline Preview")
        case .copyName: return model.t("复制名称", "Copy Name")
        case .copyPath: return model.t("复制路径", "Copy Path")
        case .copyFile: return model.t("复制文件", "Copy File")
        case .openInTerminal: return model.t("在终端中打开", "Open in Terminal")
        case .openWith: return model.t("打开方式…", "Open With…")
        case .searchInFolder: return model.t("在所在文件夹中搜索", "Search in Parent Folder")
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                ZStack {
                    if selected {
                        shape.fill(Color.accentColor.opacity(colorScheme == .dark ? 0.17 : 0.13))
                        shape.strokeBorder(Color.accentColor.opacity(colorScheme == .dark ? 0.30 : 0.18), lineWidth: 1)
                    } else if hovered {
                        shape.fill(.primary.opacity(0.06))
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

private actor FileIconCache {
    static let shared = FileIconCache()

    private enum Entry {
        case image(CGImage), unavailable
    }

    private let capacity = 128
    private var entries: [String: Entry] = [:]
    private var recent: [String] = []

    func icon(for path: String, directory: Bool) async -> CGImage? {
        if let existing = entries[path] {
            touch(path)
            if case .image(let image) = existing { return image }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let loaded: CGImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let image = withNoDatalessMaterialization { () -> CGImage? in
                    guard SearchHit.existsOnDisk(at: path, kind: directory ? "directory" : "file",
                                                 permitsDatalessLeaf: false) else { return nil }
                    let url = URL(fileURLWithPath: path, isDirectory: directory)
                    guard !LocalFile.isUbiquitousPlaceholder(url) else { return nil }
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
                    return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                }
                continuation.resume(returning: image)
            }
        }
        guard !Task.isCancelled else { return nil }
        entries[path] = loaded.map(Entry.image) ?? .unavailable
        touch(path)
        return loaded
    }

    private func touch(_ path: String) {
        recent.removeAll { $0 == path }
        recent.append(path)
        if recent.count > capacity {
            entries.removeValue(forKey: recent.removeFirst())
        }
    }
}

// Render instant UTType artwork first; resolve native icons asynchronously only for resident files under NoMaterialization.
@MainActor
private struct FileTypeIcon: View {
    let hit: SearchHit
    let directory: Bool
    @State private var resolved: CGImage?
    private static var icons: [UTType: NSImage] = [:]

    private var artwork: NSImage {
        let ext = (hit.name as NSString).pathExtension
        let type: UTType = directory ? .folder
            : (ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data)
        if let cached = Self.icons[type] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        if Self.icons.count < 96 { Self.icons[type] = icon }
        return icon
    }

    private var canLoadNativeIcon: Bool { hit.isResident && !hit.isPlaceholder }

    var body: some View {
        Group {
            if let resolved {
                Image(decorative: resolved, scale: 2)
                    .renderingMode(.original).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(nsImage: artwork).resizable().scaledToFit()
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
        .task(id: canLoadNativeIcon ? hit.path : "") {
            guard canLoadNativeIcon else { resolved = nil; return }
            resolved = await FileIconCache.shared.icon(for: hit.path, directory: directory)
        }
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
                    .frame(width: 28, height: 28)
            } else {
                Group {
                    if let symbol = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
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
            }
        }
        .frame(width: 28, height: 28)
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
        guard !canSearch else { return nil }
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
        if contentRunning { return t("正在索引文档内容…", "Indexing document content…") }
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

struct FileDialogBanner: View {
    static let launcherHeight: CGFloat = 34
    let dialog: FileDialogContext
    let chinese: Bool
    let dismiss: () -> Void

    var body: some View {
        let modeLabel = chinese
            ? (dialog.kind == .save ? "保存" : "打开")
            : (dialog.kind == .save ? "Save" : "Open")
        let title = chinese
            ? "文件弹窗快速切换 · \(dialog.appName)「\(modeLabel)」"
            : "Quick Switch · \(dialog.appName) “\(modeLabel)”"
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("⌘⇧⌫")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.primary.opacity(0.11), lineWidth: 0.75)
                }
                .fixedSize()
                .accessibilityIdentifier("selection-context-banner-shortcut")
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(chinese ? "关闭快速切换" : "Dismiss Quick Switch")
            .accessibilityIdentifier("file-dialog-banner-close")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.09))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-dialog-banner")
    }
}

struct SelectionContextBanner: View {
    static let launcherHeight: CGFloat = 30
    let context: CapturedContext
    let chinese: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: context.filePaths.isEmpty ? "text.quote" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(verbatim: context.badgeTitle(chinese: chinese))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
            if let preview = previewSnippet {
                Text(verbatim: preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text("⌘⇧⌫")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.primary.opacity(0.11), lineWidth: 0.75)
                }
                .fixedSize()
                .accessibilityIdentifier("selection-context-banner-shortcut")
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(chinese ? "清除附带上下文" : "Clear Attached Context")
            .accessibilityIdentifier("selection-context-banner-close")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.045))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection-context-banner")
    }

    private var previewSnippet: String? {
        if let text = context.textPayload {
            let singleLine = text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return singleLine.isEmpty ? nil : singleLine
        }
        guard !context.filePaths.isEmpty else { return nil }
        return context.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }
}

struct DirectoryScopeHeaderChip: View {
    let breadcrumbs: [String]
    let chinese: Bool
    let clear: () -> Void

    var body: some View {
        let displayed = breadcrumbs.count > 2
            ? ["…"] + Array(breadcrumbs.suffix(2))
            : breadcrumbs
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(verbatim: displayed.joined(separator: " › "))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(chinese ? "退出目录范围" : "Clear Directory Scope")
            .accessibilityIdentifier("directory-scope-chip-clear")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 260)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 0.75))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("directory-scope-chip")
    }
}

struct FolderAliasHeaderPill: View {
    let title: String
    let alias: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(verbatim: title.isEmpty ? alias : title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .frame(maxWidth: 165)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("folder-alias-pill")
    }
}

struct WindowAccessibilityBanner: View {
    static let launcherHeight: CGFloat = 66
    let model: Launcher
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "accessibility").font(.title2).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(WindowActionIssue.permissionRequired.title(model)).font(.callout.weight(.semibold))
                Text(model.t("请在「隐私与安全性」→「辅助功能」中启用 Lumen。",
                             "Enable Lumen in Privacy & Security → Accessibility."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(model.t("打开辅助功能设置…", "Open Accessibility Settings…"), action: openSettings)
                .accessibilityIdentifier("window-accessibility-settings")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window-accessibility-banner")
    }
}
