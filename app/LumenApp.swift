import AppKit
import Carbon
import Combine
import SwiftUI

@main
struct LumenApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let smoke = LauncherSmoke.configuration()
        let launcher = AppDelegate(smoke: smoke)
        application.delegate = launcher
        application.setActivationPolicy(smoke?.usesOffscreenWindows == true ? .prohibited : .accessory)
        withExtendedLifetime(launcher) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    let model: Launcher
    let smoke: LauncherSmoke?
    let applicationIcons = ResultIconDisplay()
    let contextActions = ContextActions()
    let commands = LauncherCommands()
    let inlinePreview = LauncherInlinePreview()
    let imageSearch: LauncherImageSearch
    private var imageUpdates: AnyCancellable?
    private var literalCommand: String?
    private var providerUpdates: AnyCancellable?
    private var shortcutUpdates: AnyCancellable?
    private var catalog = LumenCommandCatalog()
    private var contextUpdates: AnyCancellable?
    private var contextResultID: String?
    private let defaults: UserDefaults?
    private(set) lazy var globalHotKey = GlobalHotKey { [weak self] in
        guard let self else { return }
        if self.searchPresented && self.panel.isKeyWindow { self.dismissSearch() }
        else { self.showSearch() }
    }
    private var statusItem: NSStatusItem?
    private var statusSymbol: String?
    private(set) var statusMenu: NSMenu?
    private var activityItem: NSMenuItem?
    private var metricsItem: NSMenuItem?
    private var buildIndexItem: NSMenuItem?
    private var languageChange: AnyCancellable?
    private var presentationChange: AnyCancellable?
    private var presentationScheduled = false
    private var volumeChanges: AnyCancellable?
    let externalVolumes: ExternalVolumeCatalog
    let translation: TranslationPanelModel
    #if LUMEN_EXTENSIONS
    private let extensionModel = LumenExtensionPanelModel()
    #endif
    private(set) var settings: NSPanel?
    private(set) lazy var settingsSession = SettingsSession(model: model) { [weak self] oldPage, page in
        guard let self else { return }
        if oldPage == .translation { self.translation.endSettingsSession() }
        if page == .index {
            self.externalVolumes.reload()
            self.imageSearch.ensureStatus()
        }
    }
    private var configuredKey: HotKey?
    private var actionInFlight = false
    private var previewPreparing = false
    private(set) var localPreview: LocalPreviewPanel?
    private(set) var searchPresented = false
    private var searchPresentationGeneration: UInt64 = 0

    lazy var searchField: SearchField = {
        let field = SearchField()
        field.delegate = self
        field.target = self
        field.action = #selector(searchFieldAction)
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = .labelColor
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private(set) lazy var panel: SearchPanel = {
        let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 84),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = "Lumen"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancelCurrentPanelAction() }
        panel.onContextActions = { [weak self] in self?.toggleContextActions() }
        panel.onAnswerPage = { [weak self] delta in self?.commands.pageAnswer(delta) ?? false }
        panel.onSettings = { [weak self] in self?.showSearchSettings() }
        panel.onFileAction = { [weak self] action in
            guard let self, self.translation.command == nil, !self.commands.showsCard,
                  !self.contextActions.isOpen, let hit = self.model.selectedHit else { return }
            self.perform(action, on: hit)
        }
        let content = SearchBackdrop()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 15
        content.layer?.masksToBounds = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.image?.isTemplate = true
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill",
                                            accessibilityDescription: model.t("关闭搜索", "Close Search")) ?? NSImage(),
                             target: self, action: #selector(dismissSearch))
        close.isBordered = false
        close.image?.isTemplate = true
        close.setAccessibilityLabel(model.t("关闭搜索", "Close Search"))
        content.appearanceChanged = { [weak icon, weak close, weak content] in
            content?.effectiveAppearance.performAsCurrentDrawingAppearance {
                let tint = NSColor(cgColor: NSColor.secondaryLabelColor.cgColor) ?? .secondaryLabelColor
                icon?.contentTintColor = tint
                close?.contentTintColor = tint
            }
        }
        close.translatesAutoresizingMaskIntoConstraints = false
        let results = NSHostingView(rootView: SearchWindow(
            model: model,
            applicationIcons: applicationIcons,
            contextActions: contextActions,
            translation: translation,
            commands: commands,
            inlinePreview: inlinePreview,
            imageSearch: imageSearch,
            activateCommand: { [weak self] in self?.activateCommand() },
            searchCommandAsFiles: { [weak self] in self?.searchCommandAsFiles() },
            closeInlinePreview: { [weak self] in self?.closeInlinePreview() },
            activateTranslation: { [weak self] in self?.activateTranslation() },
            toggleContextActions: { [weak self] in self?.toggleContextActions() },
            showSettings: { [weak self] in self?.showSearchSettings() },
            beginIndex: { [weak self] in self?.startBackgroundIndex() },
            open: { [weak self] in self?.open($0) },
            fileAction: { [weak self] action, hit in self?.perform(action, on: hit) }
        ))
        results.translatesAutoresizingMaskIntoConstraints = false
        results.sizingOptions = []
        content.addSubview(icon)
        content.addSubview(searchField)
        content.addSubview(close)
        content.addSubview(results)
        panel.contentView = content
        panel.initialFirstResponder = searchField
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 26),
            searchField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -11),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            close.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 25),
            results.topAnchor.constraint(equalTo: content.topAnchor, constant: 56),
            results.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            results.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            results.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        updateSearchField()
        return panel
    }()

    init(smoke: LauncherSmoke?) {
        self.smoke = smoke
        defaults = smoke != nil ? smoke?.shortcutFixturePreferences : .standard
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let executable = smoke?.executable ?? resources.appendingPathComponent("lumen")
        let database = smoke?.database ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lumen/index.sqlite")
        let engine = LauncherEngine(executable: executable, database: database,
                                    syntheticRoot: smoke?.corpus, gemmaHome: smoke?.gemmaHome)
        model = Launcher(engine: engine, defaults: defaults, locale: smoke?.language)
        externalVolumes = ExternalVolumeCatalog(engine: engine)
        imageSearch = LauncherImageSearch(engine: engine, defaults: defaults)
        translation = smoke?.makeTranslationModel() ?? TranslationPanelModel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if smoke == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.imagePosition = .imageLeading
            loadShortcut()
        }
        languageChange = model.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updateLanguage() }
        }
        presentationChange = model.objectWillChange.sink { [weak self] _ in
            guard let self, !self.presentationScheduled else { return }
            self.presentationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentationScheduled = false
                self.updatePresentation()
            }
        }
        contextUpdates = contextActions.$items.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updatePresentation() }
        }
        providerUpdates = translation.$providers.combineLatest(translation.$selected)
            .map { providers, selected in providers.first { $0.id == selected } }
            .removeDuplicates().dropFirst().sink { [weak self] _ in self?.commands.invalidateAnswer() }
        shortcutUpdates = model.shortcuts.$entries.sink { [weak self] entries in
            guard let self else { return }
            self.catalog = LumenCommandCatalog(additionalLinks: entries.compactMap(\.queryLink))
            if self.searchPresented { self.searchFieldAction() }
        }
        imageUpdates = imageSearch.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchPresented, self.commands.isImageCommand else { return }
                self.searchFieldAction()
                self.updatePresentation()
            }
        }
        updateLanguage()
        model.start()
        if smoke == nil {
            let workspace = NSWorkspace.shared.notificationCenter
            volumeChanges = workspace.publisher(for: NSWorkspace.didMountNotification)
                .merge(with: workspace.publisher(for: NSWorkspace.didUnmountNotification),
                       workspace.publisher(for: NSWorkspace.didRenameVolumeNotification))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.externalVolumeStateChanged() }
        }
        loadApplicationCatalog()
        if let smoke { Task { @MainActor in await smoke.run(self) } }
    }

    private func loadApplicationCatalog() {
        if let smoke {
            model.loadApplications(roots: smoke.appRoots, extraApps: [])
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let knownSystemApps = ["com.apple.finder", "com.apple.Safari"].compactMap { identifier -> URL? in
                let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.resolvingSymlinksInPath()
                return path?.path.hasPrefix("/System/") == true ? path : nil
            }
            model.loadApplications(roots: LaunchCatalog.applicationRoots(home: home), extraApps: knownSystemApps)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        smoke?.wasActivated = true
        // Revalidate when returning from System Settings.
        guard smoke == nil, let configuredKey else { return }
        do {
            try globalHotKey.set(configuredKey)
            model.hotKey = globalHotKey.shortcut
            model.hotKeyIssue = nil
        } catch {
            globalHotKey.disable()
            model.hotKey = nil
            model.hotKeyIssue = error as? HotKeyIssue
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSearch()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        localPreview?.close()
        translation.cancel()
        imageSearch.stop(refreshStatus: false)
        externalVolumes.stop()
        globalHotKey.close()
        model.close()
    }

    @objc func showSearch() {
        let firstShow = !searchPresented
        searchPresentationGeneration &+= 1
        searchPresented = true
        if firstShow {
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - panel.frame.width / 2,
                                                   y: visible.maxY - visible.height / 3))
            }
        }
        updatePresentation()
        (panel.contentView as? SearchBackdrop)?.refreshTransparency()
        if smoke == nil { panel.makeKeyAndOrderFront(nil) }
        focusSearch()
        if firstShow {
            loadApplicationCatalog()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchPresented else { return }
                self.model.warmNameSearch()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object is SearchPanel { focusSearch() }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window is SearchPanel || window === localPreview else { return }
        dismissSearchIfFocusLeft()
    }

    private func dismissSearchIfFocusLeft() {
        guard searchPresented else { return }
        let generation = searchPresentationGeneration
        // AppKit can report resignation or closure before the next key window is set.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.searchPresented, self.searchPresentationGeneration == generation,
                  !self.panel.isKeyWindow, self.localPreview?.isKeyWindow != true else { return }
            self.dismissSearch()
        }
    }

    private func focusSearch() {
        panel.makeFirstResponder(searchField)
        searchField.refreshTextColor()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !(sender is SearchPanel) { return true }
        dismissSearch()
        return false
    }

    @objc func dismissSearch() {
        guard searchPresented else { return }
        searchPresentationGeneration &+= 1
        searchPresented = false
        translation.setCommand(nil)
        inlinePreview.close()
        commands.update(.search, raw: "", catalog: catalog)
        literalCommand = nil
        contextActions.close()
        // Release the field editor first so an earlier composition cannot be restored on reopen.
        panel.makeFirstResponder(nil)
        searchField.stringValue = ""
        model.clear()
        panel.orderOut(nil)
        if smoke == nil, NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) {
            NSApp.deactivate()
        }
    }

    @objc func startBackgroundIndex() {
        if model.indexPhase == .ready, model.watchState == .needsSetup, model.savedScope == nil, !model.scopePending {
            presentSettings(page: .index)
            return
        }
        model.applyScope(model.settingsScope)
        if model.isIndexing { dismissSearch() }
    }

    func controlTextDidChange(_ notification: Notification) { searchFieldAction() }

    private var searchText: String {
        (searchField.currentEditor() as? NSTextView)?.string ?? searchField.stringValue
    }

    @objc private func searchFieldAction() {
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let text = searchText
        if literalCommand != text { literalCommand = nil }
        let previousCommand = commands.resolution
        let priorRaw = commands.raw
        let hadCommandCard = commands.showsCard
        let translationCommand = literalCommand == nil ? TranslationCommand.parse(text) : nil
        let next = literalCommand == nil
            ? catalog.resolve(text, isExistingTranslation: { _ in translationCommand != nil }) : .search
        if priorRaw != text || previousCommand != next {
            contextActions.close()
            inlinePreview.close()
        }
        commands.update(next, raw: text, catalog: catalog)
        translation.setCommand(translationCommand)
        if case .image(let term) = next {
            imageSearch.ensureStatus()
            if let projector = imageSearch.readyProjector {
                model.setImageQuery(term, projector: projector)
            } else if model.hasQuery {
                model.clear()
            }
        } else if next == .search {
            model.setQuery(text)
        } else if previousCommand == .search || model.isImageSearch {
            model.clear()
        }
        if hadCommandCard != commands.showsCard || previousCommand != next && commands.isImageCommand ||
            (previousCommand == .translation) != (next == .translation) {
            updatePresentation()
        }
    }

    private func searchCommandAsFiles() {
        literalCommand = searchText
        searchFieldAction()
        focusSearch()
    }

    private func activateCommand() {
        guard searchPresented, searchText == commands.raw,
              (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        switch commands.resolution {
        case .discovery:
            guard let item = commands.selectedEntry, item.keyword != "?",
                  let editor = searchField.currentEditor() as? NSTextView else { return }
            editor.insertText(item.keyword + " ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        case .question(let question):
            if case .answer(let output) = commands.answer {
                let pasteboard = smoke?.filePasteboard ?? .general
                pasteboard.clearContents()
                if pasteboard.setString(output, forType: .string) { commands.noteCopied() }
            } else if commands.answer != .loading, let ask = translation.answerWithSavedProvider() {
                commands.submit(question, using: ask)
            }
        case .web(_, _, let url):
            if let smoke { smoke.dispatchedQuicklinks.append(url); dismissSearch() }
            else if NSWorkspace.shared.open(url) { dismissSearch() }
            else { commands.recordWebFailure() }
        default: break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): moveCurrentSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveCurrentSelection(1)
        case #selector(NSResponder.insertNewline(_:)):
            searchFieldAction()
            openSelection()
        case #selector(NSResponder.cancelOperation(_:)): cancelCurrentPanelAction()
        default: return false
        }
        return true
    }

    private func moveCurrentSelection(_ delta: Int) {
        if commands.resolution == .discovery { commands.move(delta); return }
        guard translation.command == nil, !commands.showsCard,
              !commands.isImageCommand || model.isImageSearch else { return }
        if contextActions.isOpen { contextActions.move(delta) }
        else { model.moveSelection(delta); refreshInlinePreview() }
    }

    @discardableResult func closeInlinePreview() -> Bool {
        guard inlinePreview.close() else { return false }
        updatePresentation()
        return true
    }

    private func cancelCurrentPanelAction() {
        if closeInlinePreview() { return }
        if commands.answer == .loading { commands.invalidateAnswer() }
        else if translation.activity == .translating { translation.cancel() }
        else if contextActions.isOpen { contextActions.close() }
        else { dismissSearch() }
    }

    private func toggleContextActions() {
        guard translation.command == nil, !commands.showsCard,
              !commands.isImageCommand || model.isImageSearch else { return }
        if contextActions.isOpen { contextActions.close(); return }
        guard let selected = model.selectedResult else { return }
        contextResultID = selected.id
        var items: [ContextActions.Item] = []
        func item(_ id: String, _ zh: String, _ en: String, _ symbol: String, _ callback: @escaping () -> Void) {
            items.append(.init(id: id, title: model.t(zh, en), symbol: symbol) { [weak self] in
                guard self?.model.selectedResult?.id == selected.id else { return }
                callback()
            })
        }
        if case .calculation = selected {
            item("copy", "复制结果", "Copy Result", "doc.on.doc") { [weak self] in self?.open(selected) }
        } else if case .file(let hit) = selected, !hit.isLocal {
            item("reveal", "在 Finder 中显示", "Show in Finder", "folder") { [weak self] in self?.revealInFinder(hit) }
        } else {
            item("open", "打开", "Open", "return") { [weak self] in self?.open(selected) }
        }

        switch selected {
        case .file(let hit):
            if hit.isLocal { item("reveal", "在 Finder 中显示", "Show in Finder", "folder") { [weak self] in self?.revealInFinder(hit) } }
            if hit.isLocal && hit.kind == "file" {
                if LauncherInlinePreview.kind(hit) != nil {
                    item("preview", "内嵌预览", "Inline Preview", "eye") { [weak self] in self?.previewFile(hit) }
                    item("quick-look", "在窗口中预览", "Preview in Window", "macwindow") { [weak self] in
                        self?.previewFile(hit, forceWindow: true)
                    }
                } else {
                    item("preview", "快速查看", "Quick Look", "eye") { [weak self] in self?.previewFile(hit) }
                }
            }
            item("copy-name", "复制名称", "Copy Name", "doc.on.doc") { [weak self] in self?.perform(.copyName, on: hit) }
            item("copy-path", "复制路径", "Copy Path", "link") { [weak self] in self?.perform(.copyPath, on: hit) }
            if hit.isLocal && hit.kind == "directory" {
                item("pin-folder", "固定项目文件夹", "Pin Project Folder", "pin") { [weak self] in
                    guard let self else { return }
                    self.model.resolve(hit, action: .open) { [weak self] url in
                        self?.pin(title: hit.name, target: .folder(url.path))
                    }
                }
            }
        case .action(let action):
            if case .application = action.destination {
                item("pin-app", "固定应用", "Pin Application", "pin") { [weak self] in
                    guard let self, self.model.containsCurrentAction(action) else { return }
                    self.pin(title: action.title(chinese: self.model.zh), target: .application(action.id))
                }
            }
        case .shortcut(let shortcut):
            item("toggle-pin", shortcut.pinned ? "取消固定" : "固定", shortcut.pinned ? "Unpin" : "Pin", "pin") { [weak self] in
                self?.model.shortcuts.togglePin(shortcut)
            }
        case .calculation: break
        }
        contextActions.show(items)
    }

    private func pin(title: String, target: SavedShortcut.Target) {
        if let saved = model.shortcuts.entries.first(where: { $0.target == target }) {
            if !saved.pinned { model.shortcuts.togglePin(saved) }
        } else if !model.shortcuts.save(.init(id: UUID(), title: title, alias: "", target: target, pinned: true)) {
            model.openingFailed()
        }
    }

    private func openSelection() {
        if commands.isImageCommand && !model.isImageSearch { return }
        if commands.showsCard { activateCommand(); return }
        if translation.command != nil {
            activateTranslation()
            return
        }
        if contextActions.isOpen {
            if model.selectedResult?.id == contextResultID { contextActions.run() }
            else { contextActions.close() }
            return
        }
        if let selected = model.selectedResult { open(selected) }
    }

    private func open(_ result: LauncherResult) {
        guard translation.command == nil, !commands.showsCard,
              !commands.isImageCommand || model.isImageSearch else { return }
        switch result {
        case .file(let hit): openFile(hit)
        case .action(let action): runAction(action)
        case .shortcut(let shortcut): openShortcut(shortcut)
        case .calculation(let calculation):
            guard searchPresented, model.calculation == calculation else { return }
            let pasteboard = smoke?.filePasteboard ?? NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(calculation.copyValue, forType: .string) { dismissSearch() }
            else { model.openingFailed() }
        }
    }

    private func openShortcut(_ shortcut: SavedShortcut) {
        guard searchPresented, model.visibleResults.contains(where: {
            if case .shortcut(let current) = $0 { return current == shortcut }
            return false
        }) else { return }
        let url: URL
        switch shortcut.target {
        case .application:
            guard let app = model.application(for: shortcut) else { model.openingFailed(); return }
            runAction(app, shortcut: shortcut)
            return
        case .folder(let path):
            guard SearchHit.pathStamp(at: path, kind: "directory") != nil else { model.openingFailed(); return }
            url = URL(fileURLWithPath: path, isDirectory: true)
        case .web(let destination):
            guard let verified = SavedShortcut.webURL(destination.absoluteString) else { model.openingFailed(); return }
            url = verified
        }
        if let smoke { smoke.dispatchedQuicklinks.append(url) }
        else if !NSWorkspace.shared.open(url) { model.openingFailed(); return }
        model.shortcuts.noteOpened(shortcut)
        dismissSearch()
    }

    private func runAction(_ action: LaunchAction, shortcut: SavedShortcut? = nil) {
        let current = shortcut.map { saved in
            model.visibleResults.contains { row in
                if case .shortcut(let value) = row { return value == saved && model.application(for: value) == action }
                return false
            }
        } ?? model.containsCurrentAction(action)
        guard searchPresented, current, !actionInFlight else { return }
        actionInFlight = true
        let query = model.query
        let finished: (Bool) -> Void = { [weak self] success in
            guard let self else { return }
            self.actionInFlight = false
            guard self.searchPresented, self.model.query == query else { return }
            if success { self.dismissSearch() }
            else { self.model.openingFailed() }
        }
        if let smoke { smoke.dispatch(action, completion: finished) }
        else { LaunchDispatcher.perform(action, completion: finished) }
    }

    private func openFile(_ hit: SearchHit) {
        model.resolve(hit, action: .open) { [weak self] url in
            guard let self else { return }
            if let smoke = self.smoke, smoke.simulatesFileOpen(url) {
                smoke.opened = url
                self.dismissSearch()
            } else if NSWorkspace.shared.open(url) {
                self.model.noteFileOpened(hit)
                self.dismissSearch()
            } else {
                self.model.openingFailed()
            }
        }
    }

    func revealInFinder(_ hit: SearchHit) {
        model.resolve(hit, action: .reveal) { [weak self] url in
            guard let self else { return }
            if let smoke = self.smoke {
                smoke.revealed = url
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func perform(_ action: FileAction, on hit: SearchHit) {
        switch action {
        case .open: openFile(hit)
        case .reveal: revealInFinder(hit)
        case .preview: previewFile(hit)
        case .copyName, .copyPath:
            model.resolve(hit, action: action) { [weak self] _ in
                guard let self, self.searchPresented else { return }
                let pasteboard = self.smoke?.filePasteboard ?? NSPasteboard.general
                let value = action == .copyName ? hit.name : hit.path
                pasteboard.clearContents()
                if pasteboard.setString(value, forType: .string) { self.model.copied(action) }
                else { self.model.openingFailed() }
            }
        }
    }

    private func refreshInlinePreview() {
        guard inlinePreview.isOpen else { return }
        guard !model.scopePending, let hit = model.selectedHit, model.containsCurrentFile(hit),
              LauncherInlinePreview.kind(hit) != nil else { inlinePreview.close(); return }
        inlinePreview.show(hit)
    }

    private func previewFile(_ hit: SearchHit, forceWindow: Bool = false) {
        if !forceWindow, LauncherInlinePreview.kind(hit) != nil {
            guard searchPresented, !model.scopePending, model.containsCurrentFile(hit),
                  hit.isLocal || hit.isCloudReference else { return }
            model.selection = hit.path
            if inlinePreview.hit == hit { inlinePreview.close() }
            else { inlinePreview.show(hit) }
            updatePresentation()
            return
        }
        guard !previewPreparing else { return }
        model.resolve(hit, action: .preview) { [weak self] _ in
            guard let self, self.searchPresented else { return }
            self.previewPreparing = true
            let query = self.model.query
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let snapshot = try? PreviewSnapshot.make(for: hit)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { snapshot?.remove(); return }
                    self.previewPreparing = false
                    guard self.searchPresented, self.model.query == query, self.model.containsCurrentFile(hit) else {
                        snapshot?.remove()
                        return
                    }
                    guard let snapshot, let panel = LocalPreviewPanel(snapshot: snapshot, title: hit.name, page: hit.pdf_page) else {
                        snapshot?.remove()
                        self.model.previewFailed()
                        return
                    }
                    self.localPreview?.close()
                    self.localPreview = panel
                    panel.delegate = self
                    if self.smoke == nil {
                        panel.center()
                        self.makeLocalPreviewKey()
                    } else {
                        panel.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
                    }
                }
            }
        }
    }

    func makeLocalPreviewKey() {
        guard let localPreview else { return }
        if smoke == nil { NSApp.activate() }
        localPreview.makeKeyAndOrderFront(nil)
    }

    private func chooseQuicklinkFolder(_ complete: @escaping (URL) -> Void) {
        guard let settings else { return }
        if let smoke {
            if let folder = smoke.chosenQuicklinkFolder { complete(folder) }
            return
        }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.resolvesAliases = false
        picker.beginSheetModal(for: settings) { response in
            if response == .OK, let url = picker.url { complete(url) }
        }
    }

    func externalVolumeStateChanged() {
        model.externalVolumesChanged()
        if settings?.isVisible == true, settingsSession.page == .index { externalVolumes.reload() }
    }

    @objc func showSettings() { presentSettings(page: nil) }

    private var isQuestion: Bool {
        if case .question = commands.resolution { return true }
        return false
    }

    private func showSearchSettings() {
        presentSettings(page: commands.isImageCommand ? .index : (translation.command != nil || isQuestion ? .translation : nil))
    }

    private func presentSettings(page: SettingsPage?) {
        if let page, page != settingsSession.page { settingsSession.page = page }
        else if settingsSession.page == .index, settings?.isVisible != true { externalVolumes.reload() }
        if smoke == nil { NSApp.activate() }
        if settings == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 770, height: 568),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.contentMinSize = NSSize(width: 700, height: 488)
            window.delegate = self
            let extensionContent: AnyView?
            #if LUMEN_EXTENSIONS
            extensionContent = AnyView(LumenExtensionPanel(
                model: extensionModel, chinese: { [weak self] in self?.model.zh ?? false },
                parentWindow: { [weak window] in window }
            ))
            #else
            extensionContent = nil
            #endif
            window.contentView = NSHostingView(rootView: LauncherSettings(
                model: model,
                session: settingsSession,
                translation: translation,
                volumes: externalVolumes,
                images: imageSearch,
                chooseImageFolder: { [weak self] in self?.chooseImageResource(folder: true) },
                chooseImageProjector: { [weak self] in self?.chooseImageResource(folder: false) },
                extensionContent: extensionContent,
                chooseQuicklinkFolder: { [weak self] in self?.chooseQuicklinkFolder($0) },
                recordShortcut: { [weak self] in self?.recordShortcut($0) },
                disableShortcut: { [weak self] in self?.disableShortcut() },
                chooseDirectories: { [weak self] in self?.chooseSettingsDirectories($0) },
                chooseDiagnosticFile: { [weak self] in self?.chooseDiagnosticFile() }
            ))
            if smoke == nil { window.center() }
            else { window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000)) }
            settings = window
        }
        settings?.title = model.t("Lumen 设置", "Lumen Settings")
        if smoke == nil { settings?.makeKeyAndOrderFront(nil) }
        if searchPresented { dismissSearch() }
    }

    func chooseImageResource(folder: Bool) {
        guard let settings else { return }
        if let smoke {
            if folder, let url = smoke.chosenImageFolder { imageSearch.setFolder(url) }
            else if !folder, let url = smoke.chosenImageProjector { imageSearch.setProjector(url) }
            return
        }
        let picker = NSOpenPanel()
        picker.canChooseFiles = !folder
        picker.canChooseDirectories = folder
        picker.resolvesAliases = false
        picker.canDownloadUbiquitousContents = false
        picker.beginSheetModal(for: settings) { [weak self] result in
            guard result == .OK, let url = picker.url else { return }
            if folder { self?.imageSearch.setFolder(url) } else { self?.imageSearch.setProjector(url) }
        }
    }

    func chooseSettingsDirectories(_ group: ScopeFolders) {
        guard let settings else { return }
        if let smoke {
            if let urls = smoke.chosenSettingsDirectories {
                smoke.chosenSettingsDirectories = nil
                settingsSession.add(urls, to: group)
            }
            return
        }
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.resolvesAliases = false
        open.prompt = model.t("添加", "Add")
        open.message = model.t("选择要添加的目录。更改会在应用后生效。",
                               "Choose folders to add. Changes take effect when you apply them.")
        open.beginSheetModal(for: settings) { [weak self] result in
            guard result == .OK else { return }
            self?.settingsSession.add(open.urls, to: group)
        }
    }

    func chooseDiagnosticFile() {
        guard let settings, !model.scopePending else { return }
        if let smoke {
            if let file = smoke.chosenDiagnosticFile {
                smoke.chosenDiagnosticFile = nil
                model.diagnoseFile(file)
            }
            return
        }
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.resolvesAliases = false
        open.prompt = model.t("检查", "Check")
        open.message = model.t("选择一个要查看索引状态的文件。", "Choose a file to check its indexing status.")
        open.beginSheetModal(for: settings) { [weak self] result in
            guard result == .OK, let file = open.url else { return }
            self?.model.diagnoseFile(file)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let localPreview, (notification.object as? NSWindow) === localPreview {
            self.localPreview = nil
            dismissSearchIfFocusLeft()
        }
        if let settings, (notification.object as? NSWindow) === settings {
            settings.makeFirstResponder(nil)
            translation.endSettingsSession()
            model.clearFileDiagnosis()
        }
    }

    @objc func showTranslation() {
        showSearch()
        guard let editor = searchField.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        editor.insertText("tr ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func activateTranslation() {
        guard searchPresented, let command = translation.command, searchText == command.raw,
              (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        if translation.output.isEmpty {
            translation.translate()
        } else {
            let pasteboard = smoke?.filePasteboard ?? .general
            pasteboard.clearContents()
            if pasteboard.setString(translation.output, forType: .string) { translation.noteCopied() }
        }
    }

    func recordShortcut(_ event: NSEvent) {
        do {
            let key = try HotKey(event: event)
            try globalHotKey.set(key)
            configuredKey = key
            model.hotKey = globalHotKey.shortcut
            model.hotKeyIssue = nil
            defaults?.set(try JSONEncoder().encode(key), forKey: "launcher.shortcut")
            defaults?.set(false, forKey: "launcher.shortcutDisabled")
        } catch {
            model.hotKeyIssue = error as? HotKeyIssue
        }
    }

    func disableShortcut() {
        globalHotKey.disable()
        configuredKey = nil
        model.hotKey = nil
        model.hotKeyIssue = nil
        defaults?.set(true, forKey: "launcher.shortcutDisabled")
    }

    private func loadShortcut() {
        guard defaults?.bool(forKey: "launcher.shortcutDisabled") != true else { return }
        let saved = defaults?.data(forKey: "launcher.shortcut").flatMap {
            try? JSONDecoder().decode(HotKey.self, from: $0)
        }
        let shortcut = saved ?? .standard
        configuredKey = shortcut
        do {
            try globalHotKey.set(shortcut)
            model.hotKey = globalHotKey.shortcut
        } catch {
            model.hotKeyIssue = error as? HotKeyIssue
        }
    }

    private func updateLanguage() {
        updateSearchField()
        updateStatusMenu()
        installEditMenu()
        settings?.title = model.t("Lumen 设置", "Lumen Settings")
    }

    private func updateSearchField() {
        searchField.placeholderString = model.t("搜索文件、应用和系统设置", "Search files, apps, and system settings")
        searchField.setAccessibilityLabel(model.t("搜索", "Search"))
    }

    private func updateStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: model.t("打开搜索", "Open Search"), action: #selector(showSearch), keyEquivalent: "").target = self
        buildIndexItem = menu.addItem(withTitle: model.t("在后台建立索引", "Build Index in Background"),
                                      action: #selector(startBackgroundIndex), keyEquivalent: "")
        buildIndexItem?.target = self
        menu.addItem(.separator())
        activityItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        metricsItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: model.t("翻译…", "Translate…"), action: #selector(showTranslation), keyEquivalent: "").target = self
        menu.addItem(withTitle: model.t("设置…", "Settings…"), action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: model.t("退出 Lumen", "Quit Lumen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
        statusItem?.menu = menu
        statusMenu = menu
        updatePresentation()
    }

    private func updatePresentation() {
        let pinnedApps = model.visibleResults.prefix(SearchWindow.maximumVisibleRows).compactMap { row -> ActionMatch? in
            guard case .shortcut(let shortcut) = row, let action = model.application(for: shortcut) else { return nil }
            return ActionMatch(action: action, score: 0)
        }
        applicationIcons.update(for: searchPresented ? model.launchMatches + pinnedApps : [])

        let activity = model.activityTitle
        let metrics = model.activityMetrics
        let metricsTitle = metrics ?? ""
        if activityItem?.title != activity { activityItem?.title = activity }
        if metricsItem?.title != metricsTitle { metricsItem?.title = metricsTitle }
        if metricsItem?.isHidden != (metrics == nil) { metricsItem?.isHidden = metrics == nil }
        let hidesBuild = !model.canStartIndexFromLauncher
        if buildIndexItem?.isHidden != hidesBuild { buildIndexItem?.isHidden = hidesBuild }
        if let button = statusItem?.button {
            let symbol = model.activityBusy ? "arrow.triangle.2.circlepath" : "magnifyingglass"
            if statusSymbol != symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                button.image?.isTemplate = true
                statusSymbol = symbol
            }
            let count = model.activeProgress?.entries.formatted(.number.notation(.compactName)) ?? ""
            if button.title != count { button.title = count }
            let summary = ["Lumen", activity, metrics].compactMap { $0 }.joined(separator: " · ")
            if button.toolTip != summary {
                button.toolTip = summary
                button.setAccessibilityLabel(summary)
            }
        }
        if model.scopePending, imageSearch.building { imageSearch.stop() }
        guard searchPresented else { return }
        refreshInlinePreview()
        if contextActions.isOpen, model.selectedResult?.id != contextResultID { contextActions.close() }
        var frame = panel.frame
        let height = SearchWindow.height(for: model, contextCount: contextActions.items.count,
                                         hasTranslation: translation.command != nil,
                                         commandHeight: commands.showsCard || (commands.isImageCommand && !model.isImageSearch) ? 162 : nil,
                                         hasPreview: inlinePreview.isOpen)
        guard frame.height != height else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func installEditMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: model.t("设置…", "Settings…"), action: #selector(showSettings),
                        keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: model.t("退出 Lumen", "Quit Lumen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu
        main.addItem(application)

        let edit = NSMenuItem()
        let commands = NSMenu(title: model.t("编辑", "Edit"))
        commands.addItem(withTitle: model.t("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = commands.addItem(withTitle: model.t("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        commands.addItem(.separator())
        commands.addItem(withTitle: model.t("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        commands.addItem(withTitle: model.t("复制", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        commands.addItem(withTitle: model.t("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        commands.addItem(withTitle: model.t("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = commands
        main.addItem(edit)
        NSApp.mainMenu = main
    }
}

@MainActor
final class SearchField: NSTextField {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTextColor()
    }

    func refreshTextColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
            textColor = color
            if let editor = currentEditor() as? NSTextView {
                editor.textColor = color
                editor.insertionPointColor = color
            }
        }
    }
}

@MainActor
final class SearchBackdrop: NSVisualEffectView {
    private var transparencyChange: AnyCancellable?
    var appearanceChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        appearanceChanged?()
        transparencyChange = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTransparency() }
        refreshTransparency()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
        refreshTransparency()
    }

    func refreshTransparency() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material = reduced ? .windowBackground : .popover
        blendingMode = reduced ? .withinWindow : .behindWindow
    }
}

@MainActor
final class SearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onFileAction: ((FileAction) -> Void)?
    var onContextActions: (() -> Void)?
    var onAnswerPage: ((Int) -> Bool)?
    var onSettings: (() -> Void)?
    override var canBecomeKey: Bool { true }

    private func handleCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.type == .keyDown, (firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command], key == "," { onSettings?(); return true }
        if modifiers == [.command] {
            if key == "y" { onFileAction?(.preview) }
            else if key == "k" { onContextActions?() }
            else if event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter { onFileAction?(.reveal) }
            else { return false }
        } else if key == "c", modifiers == [.command, .shift] {
            onFileAction?(.copyName)
        } else if key == "c", modifiers == [.command, .option] {
            onFileAction?(.copyPath)
        } else {
            return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCommand(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if handleCommand(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, modifiers.isEmpty,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            if event.keyCode == kVK_Escape { onCancel?(); return }
            if event.keyCode == kVK_PageDown, onAnswerPage?(1) == true { return }
            if event.keyCode == kVK_PageUp, onAnswerPage?(-1) == true { return }
        }
        super.sendEvent(event)
    }
}
