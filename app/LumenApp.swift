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
    private var contextUpdates: AnyCancellable?
    private(set) var quicklinksWindow: NSPanel?
    private let defaults: UserDefaults?
    private(set) lazy var globalHotKey = GlobalHotKey { [weak self] in self?.showSearch() }
    private var statusItem: NSStatusItem?
    private var statusSymbol: String?
    private(set) var statusMenu: NSMenu?
    private var activityItem: NSMenuItem?
    private var metricsItem: NSMenuItem?
    private var buildIndexItem: NSMenuItem?
    private var languageChange: AnyCancellable?
    private var presentationChange: AnyCancellable?
    private var presentationScheduled = false
    private(set) var settings: NSPanel?
    private(set) var translationWindow: NSPanel?
    private(set) lazy var settingsSession = SettingsSession(model: model)
    private var configuredKey: HotKey?
    private var actionInFlight = false
    private var previewPreparing = false
    private(set) var localPreview: LocalPreviewPanel?
    private(set) var searchPresented = false
    #if LUMEN_EXTENSIONS
    private var extensions: NSPanel?
    #endif

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
                                styleMask: [.borderless],
                                backing: .buffered, defer: false)
        panel.title = "Lumen"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancelCurrentPanelAction() }
        panel.onContextActions = { [weak self] in self?.toggleContextActions() }
        panel.onSettings = { [weak self] in self?.showSettings() }
        panel.onFileAction = { [weak self] action in
            guard let self, !self.contextActions.isOpen, let hit = self.model.selectedHit else { return }
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
            toggleContextActions: { [weak self] in self?.toggleContextActions() },
            showSettings: { [weak self] in self?.showSettings() },
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
        panel.center()
        updateSearchField()
        return panel
    }()

    init(smoke: LauncherSmoke?) {
        self.smoke = smoke
        defaults = smoke == nil ? .standard : nil
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let executable = smoke?.executable ?? resources.appendingPathComponent("lumen")
        let database = smoke?.database ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lumen/index.sqlite")
        let engine = LauncherEngine(executable: executable, database: database,
                                    syntheticRoot: smoke?.corpus, gemmaHome: smoke?.gemmaHome)
        model = Launcher(engine: engine, defaults: defaults, locale: smoke?.language)
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
        updateLanguage()
        model.start()
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
        globalHotKey.close()
        model.close()
    }

    @objc func showSearch() {
        let firstShow = !searchPresented
        searchPresented = true
        updatePresentation()
        if firstShow { panel.center() }
        (panel.contentView as? SearchBackdrop)?.refreshTransparency()
        if smoke == nil {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Exercise the same responder and rendering code inside this process only.
            panel.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        }
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
        if notification.object is SearchPanel { dismissSearch() }
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
        searchPresented = false
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
            settingsSession.page = .index
            showSettings()
            return
        }
        model.applyScope(model.settingsScope)
        if model.isIndexing { dismissSearch() }
    }

    func controlTextDidChange(_ notification: Notification) { searchFieldAction() }

    @objc private func searchFieldAction() {
        if model.query != searchField.stringValue { contextActions.close() }
        model.setQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): moveCurrentSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveCurrentSelection(1)
        case #selector(NSResponder.insertNewline(_:)): openSelection()
        case #selector(NSResponder.cancelOperation(_:)): cancelCurrentPanelAction()
        default: return false
        }
        return true
    }

    private func moveCurrentSelection(_ delta: Int) {
        if contextActions.isOpen { contextActions.move(delta) }
        else { model.moveSelection(delta) }
    }

    private func cancelCurrentPanelAction() {
        if contextActions.isOpen { contextActions.close() }
        else { dismissSearch() }
    }

    private func toggleContextActions() {
        if contextActions.isOpen { contextActions.close(); return }
        var items: [ContextActions.Item] = []
        func item(_ id: String, _ zh: String, _ en: String, _ symbol: String, _ callback: @escaping () -> Void) {
            items.append(.init(id: id, title: model.t(zh, en), symbol: symbol, perform: callback))
        }
        if let selected = model.selectedResult {
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
                    item("preview", "快速查看", "Quick Look", "eye") { [weak self] in self?.previewFile(hit) }
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
        }
        item("quicklinks", "管理快捷链接…", "Manage Quicklinks…", "link") { [weak self] in self?.showQuicklinks() }
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
        if contextActions.isOpen { contextActions.run(); return }
        if let selected = model.selectedResult { open(selected) }
    }

    private func open(_ result: LauncherResult) {
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
        if action.destination == .translation { showTranslation(); return }
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
            if let smoke = self.smoke {
                smoke.opened = url
                self.dismissSearch()
            } else if NSWorkspace.shared.open(url) {
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

    private func previewFile(_ hit: SearchHit) {
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
                    guard let snapshot, let panel = LocalPreviewPanel(snapshot: snapshot, title: hit.name) else {
                        snapshot?.remove()
                        self.model.previewFailed()
                        return
                    }
                    self.localPreview?.close()
                    self.localPreview = panel
                    panel.delegate = self
                    if self.smoke == nil {
                        panel.center()
                        panel.makeKeyAndOrderFront(nil)
                    } else {
                        panel.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
                    }
                }
            }
        }
    }

    @objc func showQuicklinks() {
        loadApplicationCatalog()
        if quicklinksWindow == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = QuicklinksView(model: model, library: model.shortcuts) { [weak self, weak window] complete in
                guard let self, let window else { return }
                if let smoke = self.smoke {
                    if let folder = smoke.chosenQuicklinkFolder { complete(folder) }
                    return
                }
                let picker = NSOpenPanel()
                picker.canChooseDirectories = true
                picker.canChooseFiles = false
                picker.allowsMultipleSelection = false
                picker.resolvesAliases = false
                picker.beginSheetModal(for: window) { response in
                    if response == .OK, let url = picker.url { complete(url) }
                }
            }
            window.contentView = NSHostingView(rootView: view)
            if smoke == nil { window.center() }
            else { window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000)) }
            quicklinksWindow = window
        }
        quicklinksWindow?.title = model.t("快捷链接", "Quicklinks")
        if smoke == nil {
            NSApp.activate()
            quicklinksWindow?.makeKeyAndOrderFront(nil)
        }
        if searchPresented { dismissSearch() }
    }

    @objc func showSettings() {
        if smoke == nil { NSApp.activate() }
        if settings == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 770, height: 568),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.contentMinSize = NSSize(width: 700, height: 488)
            window.delegate = self
            window.contentView = NSHostingView(rootView: LauncherSettings(
                model: model,
                session: settingsSession,
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
        if let localPreview, (notification.object as? NSWindow) === localPreview { self.localPreview = nil }
        if let translationWindow, (notification.object as? NSWindow) === translationWindow {
            translationWindow.contentView = nil
            self.translationWindow = nil
        }
        if let settings, (notification.object as? NSWindow) === settings {
            settings.makeFirstResponder(nil)
            model.clearFileDiagnosis()
        }
    }

    @objc func showTranslation() {
        if translationWindow == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 590),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.contentMinSize = NSSize(width: 600, height: 495)
            window.delegate = self
            window.contentView = NSHostingView(rootView: TranslationPanel())
            if smoke == nil { window.center() }
            else { window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000)) }
            translationWindow = window
        }
        translationWindow?.title = model.t("Lumen 翻译", "Lumen Translation")
        if searchPresented { dismissSearch() }
        if smoke == nil {
            NSApp.activate()
            translationWindow?.makeKeyAndOrderFront(nil)
        }
    }

    #if LUMEN_EXTENSIONS
    @objc private func showExtensions() {
        if extensions == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.contentView = NSHostingView(rootView: LumenExtensionPanel())
            window.center()
            extensions = window
        }
        extensions?.title = model.t("Lumen 扩展", "Lumen Extensions")
        NSApp.activate()
        extensions?.makeKeyAndOrderFront(nil)
    }
    #endif

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
        #if LUMEN_EXTENSIONS
        menu.addItem(withTitle: model.t("扩展…", "Extensions…"), action: #selector(showExtensions), keyEquivalent: "").target = self
        #endif
        menu.addItem(withTitle: model.t("快捷链接…", "Quicklinks…"), action: #selector(showQuicklinks), keyEquivalent: "").target = self
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
        guard searchPresented else { return }
        var frame = panel.frame
        let height = SearchWindow.height(for: model, contextCount: contextActions.items.count)
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
    var onSettings: (() -> Void)?
    override var canBecomeKey: Bool { true }

    private func handleCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.type == .keyDown, (firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command] {
            if key == "," { onSettings?() }
            else if key == "y" { onFileAction?(.preview) }
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
        if event.type == .keyDown, event.keyCode == kVK_Escape, modifiers.isEmpty,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
}
