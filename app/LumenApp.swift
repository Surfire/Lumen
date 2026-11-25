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
    private var settings: NSPanel?
    private var configuredKey: HotKey?
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
        panel.onCancel = { [weak self] in self?.dismissSearch() }
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
            showSettings: { [weak self] in self?.showSettings() },
            beginIndex: { [weak self] in self?.startBackgroundIndex() },
            open: { [weak self] in self?.open($0) },
            revealInFinder: { [weak self] in self?.revealInFinder($0) }
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
        let engine = LauncherEngine(executable: executable, database: database, syntheticRoot: smoke?.corpus)
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
            DispatchQueue.main.async { [weak self] in self?.updatePresentation() }
        }
        updateLanguage()
        model.start()
        if let smoke { Task { @MainActor in await smoke.run(self) } }
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
        model.buildIndex()
        if model.isIndexing { dismissSearch() }
    }

    func controlTextDidChange(_ notification: Notification) {
        model.setQuery(searchField.stringValue)
    }

    @objc private func searchFieldAction() { model.setQuery(searchField.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): model.moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): model.moveSelection(1)
        case #selector(NSResponder.insertNewline(_:)): openSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismissSearch()
        default: return false
        }
        return true
    }

    private func openSelection() {
        if let selected = model.selectedHit { open(selected) }
    }

    private func open(_ hit: SearchHit) {
        model.resolve(hit, revealInFinder: false) { [weak self] url in
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
        model.resolve(hit, revealInFinder: true) { [weak self] url in
            guard let self else { return }
            if let smoke = self.smoke {
                smoke.revealed = url
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    @objc func showSettings() {
        if smoke == nil { NSApp.activate() }
        if settings == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: 570),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.minSize = NSSize(width: 480, height: 450)
            window.delegate = self
            window.contentView = NSHostingView(rootView: LauncherSettings(
                model: model,
                recordShortcut: { [weak self] in self?.recordShortcut($0) },
                disableShortcut: { [weak self] in self?.disableShortcut() }
            ))
            window.center()
            settings = window
        }
        settings?.title = model.t("Lumen 设置", "Lumen Settings")
        if smoke == nil { settings?.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        if let settings, (notification.object as? NSWindow) === settings { settings.makeFirstResponder(nil) }
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
        searchField.placeholderString = model.t("搜索本机文件和文件夹", "Search local files and folders")
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
        #if LUMEN_EXTENSIONS
        menu.addItem(withTitle: model.t("扩展…", "Extensions…"), action: #selector(showExtensions), keyEquivalent: "").target = self
        #endif
        menu.addItem(withTitle: model.t("设置…", "Settings…"), action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: model.t("退出 Lumen", "Quit Lumen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
        statusItem?.menu = menu
        statusMenu = menu
        updatePresentation()
    }

    private func updatePresentation() {
        activityItem?.title = model.activityTitle
        metricsItem?.title = model.activityMetrics ?? ""
        metricsItem?.isHidden = model.activityMetrics == nil
        buildIndexItem?.isHidden = !model.canStartIndexFromLauncher
        if let button = statusItem?.button {
            let symbol = model.activityBusy ? "arrow.triangle.2.circlepath" : "magnifyingglass"
            if statusSymbol != symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                button.image?.isTemplate = true
                statusSymbol = symbol
            }
            button.title = model.activeProgress?.entries.formatted(.number.notation(.compactName)) ?? ""
            let summary = ["Lumen", model.activityTitle, model.activityMetrics].compactMap { $0 }.joined(separator: " · ")
            button.toolTip = summary
            button.setAccessibilityLabel(summary)
        }
        guard searchPresented else { return }
        var frame = panel.frame
        let height = SearchWindow.height(for: model)
        guard frame.height != height else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func installEditMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
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
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, event.keyCode == kVK_Escape, modifiers.isEmpty,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
}
