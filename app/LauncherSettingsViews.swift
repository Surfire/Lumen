import AppKit
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, index, translation, quicklinks, scripts, advanced

    var id: Self { self }

    @MainActor func title(_ model: Launcher) -> String {
        switch self {
        case .general: return model.t("通用", "General")
        case .index: return model.t("索引", "Index")
        case .translation: return model.t("AI 与模型", "AI & Models")
        case .quicklinks: return model.t("快捷链接", "Quicklinks")
        case .scripts: return model.t("脚本与指令", "Scripts")
        case .advanced: return model.t("状态与关于", "Status & About")
        }
    }

    @MainActor func subtitle(_ model: Launcher) -> String {
        switch self {
        case .general: return model.t("快捷键、外观与剪贴板", "Shortcut, appearance & clipboard")
        case .index: return model.t("目录范围、过滤与外置盘", "Folders, filters & volumes")
        case .translation: return model.t("语义、搜图与翻译服务", "Embeddings, images & AI")
        case .quicklinks: return model.t("搜索别名与常用网页", "Aliases & web shortcuts")
        case .scripts: return model.t("本地脚本与快捷指令", "Local scripts & Shortcuts")
        case .advanced: return model.t("监听、诊断、更新与版本", "Watch, diagnostics & updates")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .index: return "folder.badge.gearshape"
        case .translation: return "sparkles"
        case .quicklinks: return "link"
        case .scripts: return "terminal"
        case .advanced: return "waveform.path.ecg"
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
        case .content: return model.t("内容目录", "Content Folders")
        }
    }
}

@MainActor
final class SettingsSession: ObservableObject {
    let model: Launcher
    let indexStatus: IndexStatusState
    private let pageChanged: (SettingsPage?, SettingsPage?) -> Void
    @Published var page: SettingsPage? = .general {
        didSet { if page != oldValue { pageChanged(oldValue, page) } }
    }
    @Published private(set) var draft: IndexScope?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var loginItemFailed = false
    @Published private(set) var contentPreview: ContentScopePreview?
    @Published private(set) var previewLoading = false
    let canManageLoginItem: Bool
    private var previewProcess: Process?
    private var previewGeneration = 0

    init(model: Launcher, indexStatus: IndexStatusState? = nil, manageLoginItem: Bool,
         pageChanged: @escaping (SettingsPage?, SettingsPage?) -> Void) {
        self.model = model
        self.indexStatus = indexStatus ?? model.indexStatus
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
        var scope = (!indexStatus.scopePending ? indexStatus.savedScope : nil) ?? indexStatus.scope
        // The engine materializes derived roots in the saved scope.
        if scope.roots == scope.allow || (scope.roots == ["/"] && scope.allow.isEmpty) { scope.roots = [] }
        return scope
    }

    var scope: IndexScope { draft ?? baseline }
    var hasChanges: Bool { draft.map { $0 != baseline } ?? false }

    var canEditScope: Bool {
        indexStatus.indexPhase != .checking && (indexStatus.savedScope != nil || model.needsScopeSetup)
    }
    var canApply: Bool { canEditScope && model.canApplyScope && (hasChanges || model.needsScopeSetup) }

    var canRebuild: Bool {
        model.canApplyScope && indexStatus.savedScope != nil && indexStatus.indexPhase == .ready && !indexStatus.scopePending
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
        if group == .content { refreshContentPreview() }
    }

    func remove(_ path: String, from group: ScopeFolders) {
        var next = scope
        next[keyPath: group.paths].removeAll { $0 == path }
        if next != scope { draft = next }
        if group == .content { refreshContentPreview() }
    }

    func discard() {
        draft = nil
        refreshContentPreview()
    }

    var contentFilter: ContentFilter { scope.content_filter ?? ContentFilter() }

    func updateContentFilter(_ change: (inout ContentFilter) -> Void) {
        var filter = contentFilter
        change(&filter)
        var next = scope
        // Leave an untouched default unset so a saved scope without a filter shows no pending change.
        next.content_filter = filter == ContentFilter() && baseline.content_filter == nil ? nil : filter
        guard next != scope else { return }
        draft = next
        refreshContentPreview()
    }

    func excludeNoise(_ folder: ContentScopePreview.Subfolder) {
        updateContentFilter { filter in
            if !filter.deny_folders.contains(folder.path) { filter.deny_folders.append(folder.path) }
        }
    }

    /// Settings-only, read-only engine query; never runs on the launcher hot path.
    func refreshContentPreview() {
        previewGeneration &+= 1
        let generation = previewGeneration
        if previewProcess?.isRunning == true { previewProcess?.terminate() }
        previewProcess = nil
        let roots = scope.contentFolders
        guard !roots.isEmpty else {
            contentPreview = nil
            previewLoading = false
            return
        }
        previewLoading = true
        previewProcess = model.previewContentScope(roots: roots, filter: scope.content_filter) { [weak self] preview in
            guard let self, self.previewGeneration == generation else { return }
            self.previewProcess = nil
            self.previewLoading = false
            self.contentPreview = preview
        }
    }

    func apply() {
        guard canApply else { return }
        let requested = scope
        draft = nil
        model.applyScope(requested)
    }
}

struct LauncherSettings: View {
    @ObservedObject var model: Launcher
    @ObservedObject var indexStatus: IndexStatusState
    @ObservedObject var session: SettingsSession
    let translation: TranslationPanelModel
    let volumes: ExternalVolumeCatalog
    @ObservedObject var images: LauncherImageSearch
    let clipboard: ClipboardManager
    @ObservedObject var windowManagement: WindowManagement
    @ObservedObject var scriptCatalog: LauncherScriptCatalog
    let updates: UpdateSettings?
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

    static func aboutDisplayTitle() -> String { "Lumen" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            LumenSettingsHairline()
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                switch page {
                case .quicklinks:
                    VStack(alignment: .leading, spacing: 0) {
                        pageHeader
                            .padding(.horizontal, 28)
                            .padding(.top, 24)
                            .padding(.bottom, 10)
                        QuicklinksView(model: model, library: model.shortcuts, chooseFolder: chooseQuicklinkFolder)
                            .scrollContentBackground(.hidden)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: SettingsTheme.spacingLG) {
                            pageHeader
                            switch page {
                            case .general: general
                            case .index: indexAndPrivacy
                            case .translation: aiAndModels
                            case .scripts: scriptsAndShortcuts
                            case .advanced: statusAndAbout
                            case .quicklinks: EmptyView()
                            }
                        }
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    }
                    .id(page)
                    if page == .index { applyBar }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsTheme.canvasBackground)
        }
        .frame(minWidth: 740, minHeight: 560)
        .toggleStyle(.switch)
        .labeledContentStyle(SettingsValueStyle())
    }

    // MARK: - Sidebar (198pt Warm Editorial)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LUMEN")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2.0)
                    .foregroundStyle(SettingsTheme.textTertiary)
                Text(model.t("偏好设置", "Preferences"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(SettingsPage.allCases) { item in
                        navPill(item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .onMoveCommand(perform: navigateSidebar)
            }

            Spacer(minLength: 0)

            LumenSettingsHairline()
                .padding(.horizontal, 14)

            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)
                Text("v\(version)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.t("设置页面", "Settings Pages"))
        .frame(width: 198)
        .background(SettingsTheme.sidebarBackground)
    }

    private func navPill(_ item: SettingsPage) -> some View {
        let selected = item == page
        let showUpdateDot = item == .advanced && updates?.release != nil
        return Button {
            session.page = item
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title(model))
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? SettingsTheme.navActiveTitle : SettingsTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.subtitle(model))
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? SettingsTheme.navActiveSubtitle : SettingsTheme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 2)
                if showUpdateDot {
                    Circle()
                        .fill(SettingsTheme.amber)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                    .fill(selected ? SettingsTheme.navActiveBackground : Color.clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(SettingsTheme.navActiveIndicator)
                        .frame(width: 3, height: 24)
                        .padding(.leading, 3)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if sidebarFocus == item {
                    RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                        .strokeBorder(SettingsTheme.amber.opacity(0.65), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($sidebarFocus, equals: item)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.page.\(item.rawValue)")
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

    @ViewBuilder private var pageHeader: some View {
        switch page {
        case .general:
            LumenSettingsHeader(
                kicker: "GENERAL",
                title: model.t("通用", "General"),
                description: model.t("全局快捷键、外观主题、语言与剪贴板历史。",
                                     "Global shortcut, appearance theme, language, and clipboard history.")
            )
        case .index:
            LumenSettingsHeader(
                kicker: "INDEX",
                title: model.t("索引与目录范围", "Index & Scope"),
                description: model.t("管理内容与语义目录、文件名搜索范围及外置存储。",
                                     "Manage content & semantic folders, filename scope, and external drives.")
            )
        case .translation:
            LumenSettingsHeader(
                kicker: "AI & MODELS",
                title: model.t("AI 与模型", "AI & Models"),
                description: model.t("配置文本语义嵌入引擎、以文搜图视觉模型与翻译问答提供商。",
                                     "Configure text embedding engines, visual image search models, and AI translation providers.")
            )
        case .quicklinks:
            LumenSettingsHeader(
                kicker: "QUICKLINKS",
                title: model.t("快捷链接", "Quicklinks"),
                description: model.t("自定义搜索别名、固定应用与网页直达命令。",
                                     "Custom search aliases, pinned apps, and web shortcuts.")
            )
        case .scripts:
            LumenSettingsHeader(
                kicker: "SCRIPTS & SHORTCUTS",
                title: model.t("脚本与指令", "Scripts & Shortcuts"),
                description: model.t("启用本地可执行脚本与 Apple 快捷指令。",
                                     "Enable local executable scripts and Apple Shortcuts.")
            )
        case .advanced:
            LumenSettingsHeader(
                kicker: "STATUS & ABOUT",
                title: model.t("状态与关于", "Status & About"),
                description: model.t("文件监听健康状态、索引统计、单文件诊断与软件更新。",
                                     "File watching health, index counts, single-file diagnostics, and updates.")
            )
        }
    }

    // MARK: - General

    @ViewBuilder private var general: some View {
        if windowManagement.issue == .permissionRequired {
            WindowAccessibilityBanner(model: model, openSettings: windowManagement.openAccessibilitySettings)
        }

        LumenSettingsCard(title: model.t("启动与快捷键", "Startup & Shortcut"), icon: "command") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    startupWell
                        .frame(width: 192)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    shortcutWell
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 10) {
                    startupWell
                    shortcutWell
                }
            }

            if let issue = model.hotKeyIssue {
                Label(issue.title(model), systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.amber)
            }
            if model.hotKey?.cyclesMacWindows == true {
                note(model.t("macOS 也使用 ⌘` 切换窗口。", "macOS also uses ⌘` to cycle windows."))
            }
            note(model.t("菜单栏中的「打开搜索」始终可用。", "Open Search is always available in the menu bar."))
        }

        LumenSettingsCard(title: model.t("外观与语言", "Appearance & Language"), icon: "paintbrush") {
            HStack(alignment: .top, spacing: 12) {
                LumenSettingsWell(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.t("外观主题", "APPEARANCE").uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(SettingsTheme.textTertiary)
                        Picker(model.t("外观", "Appearance"),
                               selection: Binding(get: { model.appearanceMode }, set: { model.setAppearanceMode($0) })) {
                            Text(model.t("跟随系统", "System")).tag(AppearanceMode.system)
                            Text(model.t("浅色", "Light")).tag(AppearanceMode.light)
                            Text(model.t("深色", "Dark")).tag(AppearanceMode.dark)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("settings.appearance")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                LumenSettingsWell(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.t("界面语言", "LANGUAGE").uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(SettingsTheme.textTertiary)
                        Picker(model.t("界面语言", "Interface Language"),
                               selection: Binding(get: { model.language }, set: { model.set(\.language, to: $0) })) {
                            Text(model.t("跟随系统", "System")).tag("system")
                            Text("简体中文").tag("zh")
                            Text("English").tag("en")
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }

        LumenSettingsCard(title: model.t("剪贴板历史", "Clipboard History"), icon: "clipboard") {
            ClipboardSettingsView(clipboard: clipboard, chinese: model.zh)
        }
        .onAppear { clipboard.loadHistory() }
    }

    private var startupWell: some View {
        LumenSettingsWell(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("启动行为", "STARTUP").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(SettingsTheme.textTertiary)
                HStack(spacing: 8) {
                    Text(model.t("登录时启动", "Launch at Login"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Toggle(model.t("登录时启动", "Launch at Login"), isOn: Binding(
                        get: { session.launchAtLogin }, set: { session.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .disabled(!session.canManageLoginItem)
                    .accessibilityIdentifier("settings.launch-at-login")
                    .onAppear { session.refreshLoginItem() }
                }
                if session.loginItemNeedsApproval {
                    Button(model.t("打开登录项设置…", "Open Login Items Settings…")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(LumenSecondaryButtonStyle())
                }
                if session.loginItemFailed {
                    note(model.t("无法更改登录项。请检查 macOS 登录项设置。",
                                 "Could not change this login item. Check macOS Login Items settings."))
                }
            }
        }
    }

    private var shortcutWell: some View {
        LumenSettingsWell(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("全局快捷键", "GLOBAL SHORTCUT").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(SettingsTheme.textTertiary)
                HStack(spacing: 6) {
                    if let hotKey = model.hotKey {
                        ShortcutKeycaps(label: hotKey.label)
                            .fixedSize()
                            .accessibilityIdentifier("settings.shortcut.value")
                    } else {
                        Text(model.t("未设置", "Off"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(SettingsTheme.textSecondary)
                            .accessibilityIdentifier("settings.shortcut.value")
                    }
                    Spacer(minLength: 4)
                    ShortcutControl(model: model, record: recordShortcut).fixedSize()
                    Button(model.t("停用", "Disable"), action: disableShortcut)
                        .buttonStyle(LumenSecondaryButtonStyle())
                        .fixedSize()
                        .disabled(model.hotKey == nil && model.hotKeyIssue == nil)
                }
            }
        }
    }

    // MARK: - Index & Scope

    @ViewBuilder private var indexAndPrivacy: some View {
        LumenSettingsCard(
            title: model.t("内容与语义目录", "Content & Semantic Folders"),
            icon: "doc.text.magnifyingglass",
            trailing: { activeEngineBadgeLink }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                folderRows(.content, empty: model.t("请选择要建立正文、语义和图像索引的目录。",
                                                    "Choose folders to index for text, semantic, and image search."))
                contentScopeSummary
                LumenSettingsWell(padding: 10) {
                    Toggle(model.t("包含源代码", "Include source code"), isOn: Binding(
                        get: { session.contentFilter.enable_code },
                        set: { value in session.updateContentFilter { $0.enable_code = value } }
                    ))
                    .accessibilityIdentifier("settings.content.code")
                }
                note(model.t("自动跳过 node_modules、dist、build、*.lock、*.min.* 等开发产物；仅在线占位文件只索引名称。",
                             "Dev artifacts such as node_modules, dist, build, *.lock, and *.min.* are skipped automatically. Online-only placeholders stay name-only."))
                DisclosureGroup(model.t("高级过滤规则…", "Advanced filter rules…")) {
                    advancedContentFilters
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SettingsTheme.textSecondary)
                .accessibilityIdentifier("settings.content.advanced")
            }
            .disabled(!session.canEditScope)

            LumenSettingsHairline()
            contentProgress
        }
        .onAppear { session.refreshContentPreview() }

        LumenSettingsCard(title: model.t("文件名搜索范围", "Filename Search Scope"), icon: "folder.badge.gearshape") {
            note(model.t("只扫描 macOS 允许访问的位置。排除规则优先，包括已添加的子目录。",
                         "Lumen scans locations macOS allows it to access. Exclusions take priority, including over included subfolders."))
            if !session.scope.roots.isEmpty {
                LumenSettingsWell(padding: 10) {
                    Text(model.t("现有扫描根目录", "Existing Scan Roots"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                    ForEach(Array(Set(session.scope.roots)).sorted(), id: \.self) { path in
                        pathLabel(path)
                    }
                    note(model.t("下列规则在这些根目录内生效。", "The rules below apply within these scan roots."))
                }
            }
            folderRows(.include, empty: model.t("留空时索引启动盘的可访问位置。", "Leave empty to include accessible locations on the startup disk."),
                       constrainedEmpty: model.t("当前扫描根目录内的所有可访问位置。", "All accessible locations within the current scan roots."))
            LumenSettingsHairline()
            folderRows(.exclude, empty: model.t("没有手动排除的目录。", "No folders excluded manually."))
        }
        .disabled(!session.canEditScope)

        LumenSettingsCard(title: model.t("外置卷与网络共享", "External & Network Volumes"), icon: "externaldrive.connected.to.line.below") {
            LauncherExternalVolumes(launcher: model, catalog: volumes, changed: model.externalVolumesChanged)
                .accessibilityIdentifier("settings.external-volumes")
        }

        if let notice = indexStatus.indexNotice {
            NoticeView(model: model, notice: notice)
        }
    }

    private var activeEngineBadgeLink: some View {
        let cfg = model.textEmbeddingBackend
        let label: String
        let color: Color
        if cfg.mode == .localOpenAI {
            let shortModel = cfg.trimmedModel.isEmpty ? model.t("未选模型", "Unconfigured") : cfg.trimmedModel
            label = model.t("本机服务 · \(shortModel)", "Local · \(shortModel)")
            color = model.localModelState == .ready ? SettingsTheme.green : SettingsTheme.amber
        } else {
            switch model.localModelState {
            case .ready:
                label = "Gemma 2 · \(model.t("已就绪", "Ready"))"
                color = SettingsTheme.green
            case .available:
                label = "Gemma 2 · \(model.t("已安装", "Installed"))"
                color = SettingsTheme.green
            case .checking:
                label = "Gemma 2 · \(model.t("校验中", "Checking"))"
                color = SettingsTheme.amber
            case .unchecked, .unavailable:
                label = "Gemma 2 · \(model.t("前往配置", "Configure"))"
                color = SettingsTheme.textTertiary
            }
        }
        return Button {
            session.page = .translation
        } label: {
            HStack(spacing: 5) {
                LumenStatusPill(text: label, color: color)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .help(model.t("前往「AI 与模型」配置文本语义与图像模型", "Open AI & Models to configure text and image models"))
    }

    @ViewBuilder private var contentScopeSummary: some View {
        if let preview = session.contentPreview {
            let counts = preview.by_category
            note(model.t("约 \(preview.total_files.formatted()) 个文件 · PDF \(counts.pdf.formatted()) · Office \(counts.docx.formatted()) · 文本 \(counts.text.formatted()) · 图片 \(counts.images.formatted()) · 代码 \(counts.code.formatted())",
                         "About \(preview.total_files.formatted()) files · PDF \(counts.pdf.formatted()) · Office \(counts.docx.formatted()) · Text \(counts.text.formatted()) · Images \(counts.images.formatted()) · Code \(counts.code.formatted())"))
                .accessibilityIdentifier("settings.content.preview")
            let noise = preview.top_subfolders.filter { $0.suggested_noise && !session.contentFilter.deny_folders.contains($0.path) }
            if !noise.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text(model.t("排除噪音子目录", "Exclude noisy subfolders"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsTheme.textTertiary)
                        ForEach(noise) { folder in
                            Button {
                                session.excludeNoise(folder)
                            } label: {
                                if let reason = Self.noiseReasonLabel(folder.noise_reason, zh: model.zh) {
                                    Label("\(folder.name) · \(reason) · \(folder.count.formatted())", systemImage: "minus.circle")
                                } else {
                                    Label("\(folder.name) · \(folder.count.formatted())", systemImage: "minus.circle")
                                }
                            }
                            .buttonStyle(LumenSecondaryButtonStyle())
                            .help(folder.path)
                        }
                    }
                }
            }
        } else if session.previewLoading {
            ProgressView().controlSize(.small)
        }
    }

    static func noiseReasonLabel(_ reason: String?, zh: Bool) -> String? {
        switch reason {
        case "ai_runtime": return zh ? "AI 运行时" : "AI Runtime"
        case "image_dump": return zh ? "高图占比" : "Image Dump"
        case "sequential_frames": return zh ? "序列帧" : "Frame Dump"
        case "high_volume": return zh ? "高频" : "High Volume"
        case "noise_dir": return zh ? "噪声" : "Noise"
        default: return nil
        }
    }

    @ViewBuilder private var advancedContentFilters: some View {
        LumenSettingsWell(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    filterToggle("PDF", \.enable_pdf)
                    filterToggle("Office", \.enable_docx)
                        .help("DOCX / XLSX / PPTX / DOC / XLS / PPT / RTF")
                    filterToggle(model.t("文本", "Text"), \.enable_text)
                    filterToggle(model.t("图片", "Images"), \.enable_images)
                }
                .toggleStyle(.checkbox)
                CommaListField(title: model.t("额外包含扩展名", "Also include extensions"), prompt: "swift, json",
                               values: session.contentFilter.allow_extensions) { values in
                    session.updateContentFilter { $0.allow_extensions = values.map(Self.extensionToken) }
                }
                CommaListField(title: model.t("排除扩展名", "Exclude extensions"), prompt: "log, csv",
                               values: session.contentFilter.deny_extensions) { values in
                    session.updateContentFilter { $0.deny_extensions = values.map(Self.extensionToken) }
                }
                CommaListField(title: model.t("排除目录", "Exclude folders"), prompt: "/Users/me/Archive",
                               values: session.contentFilter.deny_folders) { values in
                    session.updateContentFilter { $0.deny_folders = values }
                }
            }
        }
        .padding(.top, 6)
        .font(.system(size: 12.5))
    }

    private static func extensionToken(_ value: String) -> String {
        var token = value.lowercased()
        while token.hasPrefix(".") || token.hasPrefix("*") { token.removeFirst() }
        return token
    }

    private func filterToggle(_ title: String, _ key: WritableKeyPath<ContentFilter, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { session.contentFilter[keyPath: key] },
            set: { value in session.updateContentFilter { $0[keyPath: key] = value } }
        ))
    }

    private var contentActive: Bool {
        indexStatus.contentRunning
            || (indexStatus.contentCoverage?.pending ?? 0) > 0 && !indexStatus.contentPaused && !indexStatus.contentFailed
    }

    private var embeddingActive: Bool {
        [.verifying, .running, .pausing].contains(indexStatus.embeddingState)
    }

    private var contentResumable: Bool {
        (indexStatus.contentCoverage?.pending ?? 0) > 0 && (indexStatus.contentPaused || indexStatus.contentFailed)
    }

    private var embeddingResumable: Bool {
        indexStatus.gemmaCoverage?.pending == true && indexStatus.gemmaCoverage?.limited == false && model.canBuildEmbeddings
    }

    private var imagePending: Bool {
        indexStatus.imageCoverage?.pending == true && indexStatus.imageCoverage?.limited == false
    }

    private var imageResumable: Bool {
        images.projector != nil && session.contentFilter.enable_images && !(indexStatus.savedScope?.contentFolders ?? []).isEmpty
            && !images.loading && model.canSearch && !indexStatus.scopePending && indexStatus.indexWork == nil
    }

    /// One unified progress block and one Pause/Resume for content extraction, text embeddings, and image embeddings.
    @ViewBuilder private var contentProgress: some View {
        LumenSettingsWell(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let coverage = indexStatus.contentCoverage, coverage.total > 0 {
                    ProgressView(value: Double(coverage.checked), total: Double(coverage.total)) {
                        Text(model.t("正文：已处理 \(coverage.checked) / \(coverage.total) 份文档",
                                     "Text: \(coverage.checked) of \(coverage.total) documents checked"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(SettingsTheme.textPrimary)
                    }
                    .tint(SettingsTheme.amber)
                }
                semanticIndexStatus
                    .font(.system(size: 12.5))
                if images.projector != nil || (indexStatus.imageCoverage?.vectors ?? 0) > 0 || images.building {
                    LauncherImageSettings(launcher: model, images: images)
                        .font(.system(size: 12.5))
                }
                if let notice = indexStatus.embeddingNotice {
                    NoticeView(model: model, notice: notice)
                }
                HStack(spacing: 10) {
                    if contentActive || embeddingActive || images.building {
                        Button(model.t("暂停索引", "Pause Indexing")) {
                            model.setContentPaused(true)
                            model.pauseEmbeddings(userInitiated: true)
                            if images.building {
                                images.stop()
                                model.setEmbeddingIndexingPaused(true)
                            }
                        }
                        .buttonStyle(LumenSecondaryButtonStyle())
                        .disabled(indexStatus.embeddingState == .pausing)
                        .accessibilityIdentifier("settings.content.pause")
                    } else if contentResumable || embeddingResumable || (imageResumable && imagePending) {
                        Button(model.t("继续索引", "Resume Indexing")) {
                            model.setEmbeddingIndexingPaused(false)
                            if contentResumable { model.setContentPaused(false) }
                            if embeddingResumable {
                                model.buildEmbeddings()
                            } else if model.embeddingState != .running && imageResumable && imagePending {
                                images.clearFailure()
                                images.build()
                            }
                        }
                        .buttonStyle(LumenPrimaryButtonStyle())
                        .accessibilityIdentifier("settings.content.resume")
                    } else if imageResumable {
                        Button(model.t("建立或刷新图像索引", "Build or Refresh Image Index")) { images.build() }
                            .buttonStyle(LumenSecondaryButtonStyle())
                            .accessibilityIdentifier("settings.content.images")
                    }
                    if indexStatus.embeddingState == .pausing {
                        note(model.t("正在完成当前批次，随后暂停。", "Indexing will pause after the current batch."))
                    }
                }
            }
        }
    }

    private func folderRows(_ group: ScopeFolders, empty: String, constrainedEmpty: String? = nil) -> some View {
        let title = group.title(model)
        let paths = Array(Set(session.scope[keyPath: group.paths])).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    chooseDirectories(group)
                } label: {
                    Label(model.t("添加目录…", "Add Folder…"), systemImage: "plus")
                }
                .buttonStyle(LumenSecondaryButtonStyle())
                .accessibilityLabel(model.t("添加目录到「\(title)」", "Add Folder to \(title)"))
                .accessibilityIdentifier(group == .content ? "settings.content.add" : "settings.scope.add")
            }

            LumenSettingsWell(padding: 10) {
                if paths.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(SettingsTheme.textTertiary)
                            .accessibilityHidden(true)
                        Text(!session.scope.roots.isEmpty ? constrainedEmpty ?? empty : empty)
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                            if index > 0 { LumenSettingsHairline() }
                            HStack(spacing: 8) {
                                pathLabel(path)
                                Button {
                                    session.remove(path, from: group)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(SettingsTheme.textTertiary)
                                }
                                .buttonStyle(.borderless)
                                .help(model.t("移除目录", "Remove Folder"))
                                .accessibilityLabel(model.t("移除目录 \(path)", "Remove Folder \(path)"))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private func pathLabel(_ path: String) -> some View {
        Label {
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "folder")
                .foregroundStyle(SettingsTheme.amber)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(SettingsTheme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(path)
    }

    private var applyBar: some View {
        HStack(spacing: 12) {
            if session.hasChanges {
                LumenStatusPill(text: model.t("有未应用的更改", "Unapplied changes"), color: SettingsTheme.amber)
                Button(model.t("还原", "Revert")) { session.discard() }
                    .buttonStyle(LumenSecondaryButtonStyle())
            } else if model.isIndexing {
                note(model.activityTitle)
            } else if !session.canEditScope && indexStatus.indexPhase == .ready {
                note(model.t("当前索引的已保存范围不可用。", "The saved scope for this index is unavailable."))
            }
            Spacer()
            Button(indexStatus.indexPhase == .needsIndex ? model.t("建立索引", "Build Index")
                   : model.t("应用并更新索引", "Apply and Update Index")) { session.apply() }
                .buttonStyle(LumenPrimaryButtonStyle())
                .disabled(!session.canApply)
                .accessibilityIdentifier("settings.index.apply")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 13)
        .background(SettingsTheme.cardBackground)
        .overlay(alignment: .top) { LumenSettingsHairline() }
    }

    // MARK: - AI & Models (.translation)

    @ViewBuilder private var aiAndModels: some View {
        TextEmbeddingEngineCard(model: model, assets: GemmaAssetManager.shared) { _ in
            model.verifyLocalModel()
            images.adoptInstalledProjector()
            model.refreshCoverageAfterImageBuild()
        }

        imageModelCard

        LumenSettingsCard(title: model.t("翻译与问答提供商", "Translation & Q&A Providers"), icon: "character.bubble") {
            TranslationSettingsView(model: translation, chinese: model.zh)
        }
    }

    private var imageModelCard: some View {
        let assets = GemmaAssetManager.shared
        let vectors = indexStatus.imageCoverage?.enabled == true
            ? (indexStatus.imageCoverage?.vectors ?? 0)
            : (images.scope?.vectors ?? indexStatus.imageCoverage?.vectors ?? 0)
        let ready = images.projector != nil && assets.textInstalled
        let installedInDefaultHome = assets.imageInstalled && assets.textInstalled
        return LumenSettingsCard(
            title: model.t("以文搜图模型", "Image Search Model"),
            icon: "photo.on.rectangle.angled",
            trailing: {
                if images.building {
                    LumenStatusPill(text: model.t("已处理 \(images.checked) 张", "Prepared \(images.checked)"),
                                    color: SettingsTheme.amber)
                } else if ready {
                    LumenStatusPill(text: model.t("已就绪", "Ready"), color: SettingsTheme.green)
                } else if installedInDefaultHome {
                    LumenStatusPill(text: model.t("已安装", "Installed"), color: SettingsTheme.green)
                } else if images.projector != nil {
                    LumenStatusPill(text: model.t("需基础模型", "Needs Base Model"), color: SettingsTheme.amber)
                } else {
                    LumenStatusPill(text: model.t("未安装", "Not Installed"), color: SettingsTheme.textTertiary)
                }
            }
        ) {
            GemmaAssetSettings(launcher: model, assets: GemmaAssetManager.shared, scope: .imageOnly) { _ in
                model.verifyLocalModel()
                images.adoptInstalledProjector()
                model.refreshCoverageAfterImageBuild()
            }

            LumenSettingsWell(padding: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.t("自定义视觉投影模型 (.gguf)", "Custom Image Projector (.gguf)"))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(SettingsTheme.textPrimary)
                            Text(images.projector?.lastPathComponent ?? model.t("使用默认内置 mmproj", "Default built-in mmproj"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(SettingsTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button(model.t("选择…", "Choose…"), action: chooseImageProjector)
                            .buttonStyle(LumenSecondaryButtonStyle())
                            .disabled(images.building)
                    }
                    LumenSettingsHairline()
                    LumenSettingsRow(
                        label: model.t("已索引图像向量", "Indexed Images"),
                        value: images.building
                            ? model.t("已处理 \(images.checked) 张", "Prepared \(images.checked)")
                            : model.t("\(vectors.formatted()) 张", "\(vectors.formatted()) images"),
                        statusColor: vectors > 0 ? SettingsTheme.green : SettingsTheme.textSecondary
                    )
                }
            }

            if images.failed {
                Text(model.t("图像索引失败。请检查目录和图像模型后重试。",
                             "Image indexing failed. Check the folders and image model, then retry."))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.red)
            }

            note(model.t("以文搜图始终使用本机 Gemma 2 多模态模型（mmproj），与上方文本语义引擎相互独立。",
                         "Image search is always powered locally by built-in Gemma 2 multimodal (mmproj), independent of the text embedding engine above."))
        }
    }

    // MARK: - Scripts & Shortcuts

    @ViewBuilder private var scriptsAndShortcuts: some View {
        LumenSettingsCard(title: model.t("本地脚本", "Local Scripts"), icon: "terminal") {
            LumenSettingsWell(padding: 12) {
                Toggle(model.t("启用本地脚本", "Enable Local Scripts"), isOn: Binding(
                    get: { scriptCatalog.scriptsEnabled }, set: { scriptCatalog.setScriptsEnabled($0) }
                ))
                .disabled(scriptCatalog.folder == nil)
                .accessibilityIdentifier("settings.scripts.enabled")

                if let folder = scriptCatalog.folder {
                    LumenSettingsHairline()
                    LumenSettingsRow(
                        label: model.t("脚本文件夹", "Scripts Folder"),
                        value: (folder as NSString).abbreviatingWithTildeInPath
                    )
                }
            }

            HStack(spacing: 8) {
                Button(model.t("选择文件夹…", "Choose Folder…"), action: chooseScriptsFolder)
                    .buttonStyle(LumenSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.scripts.choose")
                if scriptCatalog.folder == nil {
                    Button(model.t("创建默认文件夹并启用", "Create Default Folder & Enable"), action: scriptCatalog.createAndEnable)
                        .buttonStyle(LumenPrimaryButtonStyle())
                        .disabled(scriptCatalog.scriptLoading)
                }
                Button(model.t("重新载入脚本", "Reload Scripts"), action: scriptCatalog.reloadScripts)
                    .buttonStyle(LumenSecondaryButtonStyle())
                    .disabled(!scriptCatalog.scriptsEnabled || scriptCatalog.scriptLoading)
            }

            if scriptCatalog.scriptLoading { note(model.t("正在读取脚本…", "Loading scripts…")) }
            else if scriptCatalog.scriptFailed {
                Text(model.t("无法读取该文件夹。请选择本机非链接目录。", "Could not read the folder. Choose a resident folder that is not a link."))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.red)
            } else {
                note(model.t("\(scriptCatalog.scripts.count) 个脚本", "Scripts available: \(scriptCatalog.scripts.count)"))
            }

            note(model.t("仅搜索该文件夹内的可执行文件。脚本拥有您的权限；请仅启用您信任的脚本。将直接在所选文件夹内运行，工作目录为该文件夹。",
                         "Only executables directly inside the folder are listed. Scripts run with your permissions; enable only scripts you trust. Scripts run directly with the selected folder as their working directory."))
        }

        LumenSettingsCard(title: model.t("Apple 快捷指令", "Apple Shortcuts"), icon: "square.stack.3d.up") {
            LumenSettingsWell(padding: 12) {
                Toggle(model.t("启用 Apple 快捷指令", "Enable Apple Shortcuts"), isOn: Binding(
                    get: { scriptCatalog.shortcutsEnabled }, set: { scriptCatalog.setShortcutsEnabled($0) }
                ))
                .accessibilityIdentifier("settings.apple-shortcuts.enabled")
            }

            HStack(spacing: 10) {
                Button(model.t("刷新快捷指令", "Refresh Shortcuts"), action: scriptCatalog.refreshShortcuts)
                    .buttonStyle(LumenSecondaryButtonStyle())
                    .disabled(!scriptCatalog.shortcutsEnabled || scriptCatalog.shortcutLoading)
                if scriptCatalog.shortcutLoading { note(model.t("正在读取快捷指令…", "Loading Shortcuts…")) }
                else if scriptCatalog.shortcutFailed {
                    Text(model.t("无法读取快捷指令。", "Could not list Shortcuts."))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.red)
                } else {
                    note(model.t("\(scriptCatalog.shortcuts.count) 个快捷指令", "Shortcuts available: \(scriptCatalog.shortcuts.count)"))
                }
            }
        }
    }

    // MARK: - Status & About (.advanced)

    @ViewBuilder private var statusAndAbout: some View {
        LumenSettingsCard(
            title: model.t("索引健康与统计", "Index Health & Counts"),
            icon: "waveform.path.ecg",
            trailing: {
                LumenStatusPill(text: watchShortBadge, color: watchStatusColor)
            }
        ) {
            Text(watchLabel)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsTheme.textPrimary)

            if let metrics = model.activityMetrics {
                if let progress = model.activeProgress, let fraction = progress.fraction {
                    ProgressView(metrics, value: fraction)
                        .tint(SettingsTheme.amber)
                } else {
                    Text(metrics)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
            } else if model.isIndexing {
                ProgressView(model.activityTitle).controlSize(.small)
            }

            if let notice = indexStatus.watchNotice {
                NoticeView(model: model, notice: notice)
            }

            if let report = indexStatus.indexReport {
                let columns = [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ]
                LazyVGrid(columns: columns, spacing: 10) {
                    LumenSettingsMetricTile(
                        label: model.t("索引项目", "Indexed Items"),
                        value: report.items.formatted(),
                        subtitle: model.t("名称与路径目录", "Names & paths"),
                        accent: SettingsTheme.green
                    )
                    LumenSettingsMetricTile(
                        label: model.t("已索引正文", "Indexed Documents"),
                        value: (report.documents ?? 0).formatted(),
                        subtitle: "PDF · Office · Text",
                        accent: SettingsTheme.amber
                    )
                    LumenSettingsMetricTile(
                        label: model.t("语义向量", "Semantic Chunks"),
                        value: (indexStatus.gemmaCoverage?.embedded_chunks ?? 0).formatted(),
                        subtitle: activeSemanticTileSubtitle,
                        accent: SettingsTheme.amber
                    )
                    LumenSettingsMetricTile(
                        label: model.t("仅在线文件", "Online-Only Files"),
                        value: (report.placeholders ?? 0).formatted(),
                        subtitle: model.t("图像 \((indexStatus.imageCoverage?.vectors ?? 0).formatted()) 张",
                                          "\((indexStatus.imageCoverage?.vectors ?? 0).formatted()) images"),
                        accent: SettingsTheme.textTertiary
                    )
                }

                let warnings = [
                    (model.t("无法访问", "Inaccessible Entries"), report.entries_unreadable ?? 0),
                    (model.t("暂不可访问", "Unavailable Items"), report.unverified ?? 0),
                    (model.t("正文未读取", "Documents Without Readable Text"), report.documents_not_read ?? 0),
                ].filter { $0.1 > 0 }
                if !warnings.isEmpty {
                    LumenSettingsWell(padding: 10) {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { index, item in
                            if index > 0 { LumenSettingsHairline() }
                            LumenSettingsRow(label: item.0, value: item.1.formatted(), statusColor: SettingsTheme.amber)
                        }
                    }
                }
            } else {
                LumenSettingsWell(padding: 10) {
                    Text(indexStatus.indexPhase == .checking ? model.activityTitle
                         : model.t("尚无索引统计。", "Index counts are unavailable."))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
            }
        }

        diagnostics

        about
    }

    private var activeSemanticTileSubtitle: String {
        let cfg = model.textEmbeddingBackend
        if cfg.mode == .localOpenAI {
            return cfg.trimmedModel.isEmpty ? model.t("本机服务", "Local Server") : cfg.trimmedModel
        }
        return indexStatus.gemmaCoverage?.documents_enabled == true ? "EmbeddingGemma 2" : model.t("未开启正文", "Documents off")
    }

    private var diagnostics: some View {
        LumenSettingsCard(title: model.t("单文件排查诊断", "File Diagnostics"), icon: "magnifyingglass.circle") {
            HStack(alignment: .center, spacing: 12) {
                note(model.t("检查所选文件的名称、正文和语义索引状态。",
                             "Check the name, text, and semantic coverage of a selected file."))
                Spacer(minLength: 12)
                Button(model.t("选取文件…", "Choose File…"), action: chooseDiagnosticFile)
                    .buttonStyle(LumenSecondaryButtonStyle())
                    .disabled(indexStatus.scopePending)
                    .accessibilityIdentifier("settings.diagnostics.choose")
            }
            switch indexStatus.fileDiagnosis {
            case .idle:
                EmptyView()
            case .checking(let name):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .lineLimit(1)
                }
            case .failed(let name):
                LumenSettingsWell(padding: 10) {
                    Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(model.t("无法获取此文件的诊断结果。", "Could not read diagnostics for this file."))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.red)
                }
            case .result(let name, let result):
                LumenSettingsWell(padding: 12) {
                    HStack {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SettingsTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(model.t("清除", "Clear")) { model.clearFileDiagnosis() }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.textSecondary)
                    }
                    LumenSettingsHairline()
                    LumenSettingsRow(label: model.t("名称", "Name"), value: diagnosisText(result.name),
                                     statusColor: diagnosisColor(result.name))
                    LumenSettingsRow(label: model.t("正文", "Document Text"), value: diagnosisText(result.text),
                                     statusColor: diagnosisColor(result.text))
                    LumenSettingsRow(label: model.t("语义", "Semantic"), value: diagnosisText(result.semantic),
                                     statusColor: diagnosisColor(result.semantic))
                }
            }
        }
    }

    @ViewBuilder private var about: some View {
        LumenSettingsCard(title: model.t("关于 Lumen", "About Lumen"), icon: "sparkles") {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.aboutDisplayTitle())
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(SettingsTheme.textPrimary)
                    Text(model.t("版本 \(version)", "Version \(version)"))
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(SettingsTheme.textSecondary)
                    LumenStatusPill(text: model.activityTitle, color: aboutStatusColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            LumenSettingsHairline()

            LumenSettingsWell(padding: 12) {
                LumenSettingsRow(label: model.t("版本", "Version"), value: version)
                LumenSettingsHairline()
                LumenSettingsRow(label: model.t("平台", "Platform"), value: "macOS 14+")
                LumenSettingsHairline()
                LumenSettingsRow(label: model.t("许可证", "License"), value: "MIT")
            }

            if let updates {
                LumenSettingsHairline()
                LauncherUpdateControls(updates: updates, model: model)
            }

            LumenSettingsHairline()

            DisclosureGroup(model.t("高级维护", "Advanced Maintenance")) {
                VStack(alignment: .leading, spacing: 8) {
                    note(model.t("按当前已生效的范围重新扫描，保留未应用的设置草稿。",
                                 "Rescan the currently saved scope. Unapplied edits stay in their draft."))
                    Button(model.t("重建索引…", "Rebuild Index…")) { confirmRebuild = true }
                        .buttonStyle(LumenSecondaryButtonStyle())
                        .disabled(!session.canRebuild)
                        .confirmationDialog(model.t("按当前范围重建索引？", "Rebuild the Index Using the Saved Scope?"),
                                            isPresented: $confirmRebuild, titleVisibility: .visible) {
                            Button(model.t("重建", "Rebuild")) { model.rebuildSavedIndex() }
                            Button(model.t("取消", "Cancel"), role: .cancel) {}
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(SettingsTheme.textSecondary)
        }
    }

    // MARK: - Helpers

    private func diagnosisColor(_ reason: String) -> Color {
        switch reason {
        case "indexed": return SettingsTheme.green
        case "stale", "unverified", "pending_gemma": return SettingsTheme.amber
        case "index_unavailable", "unreadable", "missing", "gemma_limited": return SettingsTheme.red
        default: return SettingsTheme.textSecondary
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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(SettingsTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var watchStatusColor: Color {
        switch indexStatus.watchState {
        case .running: return SettingsTheme.green
        case .paused, .failed: return SettingsTheme.amber
        case .checking, .starting, .needsSetup, .unavailable: return SettingsTheme.textTertiary
        }
    }

    private var watchShortBadge: String {
        switch indexStatus.watchState {
        case .running: return model.t("监听中", "Watching")
        case .paused: return model.t("已暂停", "Paused")
        case .failed: return model.t("已停止", "Stopped")
        case .starting, .checking: return model.t("检查中", "Checking")
        case .needsSetup: return model.t("待配置", "Setup Needed")
        case .unavailable: return model.t("手动", "Manual")
        }
    }

    private var aboutStatusColor: Color {
        if indexStatus.watchState == .failed { return SettingsTheme.amber }
        if indexStatus.watchState == .running || model.canSearch { return SettingsTheme.green }
        return SettingsTheme.textTertiary
    }

    @ViewBuilder private var semanticIndexStatus: some View {
        if let coverage = indexStatus.gemmaCoverage {
            let count = coverage.embedded_chunks.formatted()
            let limit = coverage.chunk_limit.formatted()
            let partial = coverage.documents_enabled && !coverage.complete && !coverage.limited && coverage.pending
            if !coverage.documents_enabled {
                Text(model.t("启用正文索引才能生成语义索引。", "Enable document indexing to build a semantic index."))
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else if coverage.limited && coverage.hasResults {
                Text(model.t("已达到 \(limit) 段的存储上限。已建立索引的 \(count) 段仍可检索。",
                             "Storage limit reached (\(limit) chunks). The \(count) indexed chunks are still searchable."))
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else if coverage.limited {
                Text(model.t("已达到语义索引存储上限。", "The semantic index reached its storage limit."))
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else if coverage.complete {
                Text(model.t("语义索引已就绪，包含 \(count) 段。", "Semantic index ready with \(count) chunks."))
                    .foregroundStyle(SettingsTheme.green)
            } else if partial && [.verifying, .running, .pausing].contains(indexStatus.embeddingState) {
                let label = indexStatus.embeddingState == .pausing
                    ? model.t("语义向量：正在暂停 · 已完成 \(count) / \(limit) 段", "Semantic vectors: pausing · \(count) / \(limit) chunks")
                    : model.t("语义向量：正在后台生成 · \(count) / \(limit) 段", "Semantic vectors: indexing in background · \(count) / \(limit) chunks")
                if coverage.chunk_limit > 0 {
                    ProgressView(value: Double(min(coverage.embedded_chunks, coverage.chunk_limit)),
                                 total: Double(coverage.chunk_limit)) {
                        Text(label).font(.system(size: 12.5))
                    }
                    .tint(SettingsTheme.amber)
                } else {
                    ProgressView { Text(label).font(.system(size: 12.5)) }
                }
            } else if partial && indexStatus.embeddingState == .paused && coverage.hasResults {
                Text(model.t("语义向量：已暂停 · 已有 \(count) / \(limit) 段可检索",
                             "Semantic vectors: paused · \(count) / \(limit) chunks searchable"))
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else if coverage.hasResults {
                Text(model.t("已有 \(count) / \(limit) 段可检索，仍有正文待处理。",
                             "Partial semantic index: \(count) / \(limit) searchable chunks, with more documents to process."))
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else if indexStatus.indexWork == .embeddings || indexStatus.embeddingState == .verifying {
                Text(model.t("正在准备语义索引…", "Preparing the semantic index…"))
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else if coverage.pending {
                Text(model.t("正文可用于生成本机语义索引。", "Documents are ready for local semantic indexing."))
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else if coverage.skipped_chunks > 0 {
                let skipped = coverage.skipped_chunks.formatted()
                Text(model.t("已跳过 \(skipped) 段无法索引的正文。", "Skipped \(skipped) chunks that could not be indexed."))
                    .foregroundStyle(SettingsTheme.textSecondary)
            } else {
                Text(model.t("当前范围还没有可建立语义索引的正文。", "There is no document text to index in this scope yet."))
                    .foregroundStyle(SettingsTheme.textSecondary)
            }
        }
    }

    private var watchLabel: String {
        switch indexStatus.watchState {
        case .checking: return model.t("正在检查文件监听支持…", "Checking file watching support…")
        case .unavailable: return model.t("当前版本请手动更新索引。", "Use manual index updates in this version.")
        case .needsSetup: return model.t("在「索引」中应用范围后可监听文件变化。",
                                         "Apply a scope in Index to watch for file changes.")
        case .paused: return model.t("索引范围应用成功后恢复文件监听。", "File watching resumes after the scope is applied.")
        case .starting: return model.t("正在核对索引与访问权限…", "Checking the saved index and file access…")
        case .running: return model.t("正在监听文件变化。", "Lumen is watching for file changes.")
        case .failed: return model.t("文件监听未运行。", "File watching is stopped.")
        }
    }
}

/// Comma-separated list editor that commits on Return or focus loss, so typing a comma never re-parses mid-edit.
private struct CommaListField: View {
    let title: String
    let prompt: String
    let values: [String]
    let commit: ([String]) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .lumenWellField()
                .frame(maxWidth: 260)
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { _, now in if !now { apply() } }
        }
        .onAppear { text = values.joined(separator: ", ") }
        .onChange(of: values) { _, now in if !focused { text = now.joined(separator: ", ") } }
    }

    private func apply() {
        let parsed = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = parsed.filter { seen.insert($0).inserted }
        if unique != values { commit(unique) }
    }
}

private struct LauncherUpdateControls: View {
    @ObservedObject var updates: UpdateSettings
    let model: Launcher

    private static let checkDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(model.t("每 24 小时自动检查更新", "Automatically check for updates every 24 hours"),
                   isOn: $updates.autoCheckUpdates)
                .toggleStyle(.switch)
                .accessibilityIdentifier("settings.updates.autoCheck")
            if let backup = updates.backup {
                Text(model.t("更新已安装。正在重新打开 Lumen；若未自动重启，请手动退出并重开。",
                             "Update installed. Relaunching Lumen; quit and reopen manually if needed."))
                    .font(.system(size: 12.5))
                Text(model.t("旧版本备份：\(backup.path)", "Previous app backup: \(backup.path)"))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    Button(model.t("检查更新", "Check for Updates"), action: updates.check)
                        .buttonStyle(LumenSecondaryButtonStyle())
                        .accessibilityIdentifier("settings.updates.check")
                    if let release = updates.release {
                        if updates.canInstallInPlace {
                            Button(model.t("安装并重启 \(release.version)", "Install & Relaunch \(release.version)"),
                                   action: updates.installAndRelaunch)
                                .buttonStyle(LumenPrimaryButtonStyle())
                                .accessibilityIdentifier("settings.updates.install")
                        } else {
                            Button(model.t("打开下载页 \(release.version)", "Open Download \(release.version)"),
                                   action: updates.openReleasePage)
                                .buttonStyle(LumenPrimaryButtonStyle())
                                .accessibilityIdentifier("settings.updates.download")
                        }
                    }
                    if updates.busy { ProgressView().controlSize(.small) }
                }
                .disabled(updates.busy)

                if let error = updates.error {
                    Text(model.t("更新失败：\(error)", "Update failed: \(error)"))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.red)
                        .textSelection(.enabled)
                } else if let release = updates.release {
                    if !release.notes.isEmpty {
                        LumenSettingsWell(padding: 10) {
                            Text(release.notes)
                                .font(.system(size: 12))
                                .foregroundStyle(SettingsTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                } else if updates.checked {
                    Text(model.t("当前已是最新版本。", "Lumen is up to date."))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.green)
                }

                if let lastCheck = updates.lastUpdateCheckAt {
                    Text(model.t("上次检查：\(Self.checkDateFormatter.string(from: lastCheck))",
                                 "Last checked: \(Self.checkDateFormatter.string(from: lastCheck))"))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsTheme.textTertiary)
                }
            }
        }
    }
}

private struct ShortcutKeycaps: View {
    let label: String

    private var tokens: [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var parts: [String] = []
        var remainder = Substring(label)
        while let first = remainder.first, modifiers.contains(first) {
            parts.append(String(first))
            remainder = remainder.dropFirst()
        }
        if !remainder.isEmpty {
            let key = String(remainder)
            parts.append(key == "␣" ? "Space" : key)
        }
        return parts.isEmpty ? [label] : parts
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .padding(.horizontal, 6.5)
                    .frame(minWidth: 23, minHeight: 22)
                    .background(SettingsTheme.cardBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(SettingsTheme.cardBorder, lineWidth: 0.9)
                    }
                    .shadow(color: .black.opacity(0.06), radius: 0.5, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
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
        LumenSettingsWell(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.title(for: notice), systemImage: "info.circle")
                    .foregroundStyle(SettingsTheme.amber)
                if !notice.detail.isEmpty {
                    DisclosureGroup(model.t("技术详情", "Technical Details")) {
                        Text(notice.detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(SettingsTheme.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(5)
                    }
                }
            }
            .font(.system(size: 12))
        }
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
