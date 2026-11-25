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
        application.setActivationPolicy(smoke == nil ? .accessory : .prohibited)
        withExtendedLifetime(launcher) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSearchFieldDelegate {
    let model: Launcher
    let smoke: LauncherSmoke?
    private let defaults: UserDefaults?
    private(set) lazy var globalHotKey = GlobalHotKey { [weak self] in self?.showSearch() }
    private var statusItem: NSStatusItem?
    private var languageChange: AnyCancellable?
    private var settings: NSPanel?
    private var configuredKey: HotKey?
    #if LUMEN_EXTENSIONS
    private var extensions: NSPanel?
    #endif

    lazy var searchField: NSSearchField = {
        let field = NSSearchField()
        field.delegate = self
        field.target = self
        field.action = #selector(searchFieldAction)
        field.font = .systemFont(ofSize: 21)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private(set) lazy var panel: SearchPanel = {
        let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 450),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.title = "Lumen"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 530, height: 360)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismissSearch() }
        let content = NSView()
        let results = NSHostingView(rootView: SearchWindow(
            model: model,
            showSettings: { [weak self] in self?.showSettings() },
            open: { [weak self] in self?.open($0) },
            revealInFinder: { [weak self] in self?.revealInFinder($0) }
        ))
        results.translatesAutoresizingMaskIntoConstraints = false
        results.sizingOptions = []
        content.addSubview(searchField)
        content.addSubview(results)
        panel.contentView = content
        panel.initialFirstResponder = searchField
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            results.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            results.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            results.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            results.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
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
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Lumen")
            statusItem?.button?.image?.isTemplate = true
            loadShortcut()
        }
        languageChange = model.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updateLanguage() }
        }
        updateLanguage()
        model.start()
        showSearch()
        if let smoke { Task { @MainActor in await smoke.run(self) } }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
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
        if (notification.object as? NSWindow) === panel { focusSearch() }
    }

    private func focusSearch() {
        panel.makeFirstResponder(searchField)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender !== panel { return true }
        dismissSearch()
        return false
    }

    func dismissSearch() {
        // Release the field editor first so an earlier composition cannot be restored on reopen.
        panel.makeFirstResponder(nil)
        searchField.stringValue = ""
        model.clear()
        panel.orderOut(nil)
        if smoke == nil, NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) {
            NSApp.deactivate()
        }
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
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: model.t("打开搜索", "Open Search"), action: #selector(showSearch), keyEquivalent: "").target = self
        #if LUMEN_EXTENSIONS
        menu.addItem(withTitle: model.t("扩展…", "Extensions…"), action: #selector(showExtensions), keyEquivalent: "").target = self
        #endif
        menu.addItem(withTitle: model.t("设置…", "Settings…"), action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: model.t("退出 Lumen", "Quit Lumen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
        statusItem.menu = menu
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
final class SearchPanel: NSPanel {
    var onCancel: (() -> Void)?

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
