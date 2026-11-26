import AppKit
import Carbon
import Combine
import Foundation
import ImageIO
import SQLite3
import SwiftUI
import zlib

// Runs inside the built app with app-local AppKit and Carbon events and an isolated index.
@MainActor
final class LauncherSmoke {
    let corpus: URL
    let database: URL
    let executable: URL?
    let gemmaHome: URL
    let language: String
    let appRoots: [URL]
    let filePasteboard = NSPasteboard.withUniqueName()
    private let clipboardSession = NotificationCenter()
    private lazy var clipboardFixtureRoot = ClipboardStore.canonicalStorageAnchor(directory)
    private(set) var dispatchedActions: [LaunchAction.Destination] = []
    let usesOffscreenWindows: Bool
    private let directory: URL
    private let startsWithIndex: Bool
    private let controlledTiming: Bool
    var opened: URL?
    private var workspaceOpenPaths = Set<String>()

    func simulatesFileOpen(_ url: URL) -> Bool { !workspaceOpenPaths.contains(IndexScope.folderPath(url)) }

    var revealed: URL? {
        didSet { revealDispatch = revealed == nil ? nil : .now }
    }
    private var revealDispatch: ContinuousClock.Instant?
    var wasActivated = false
    var dispatchedQuicklinks: [URL] = []
    var chosenQuicklinkFolder: URL?
    var chosenSettingsDirectories: [URL]?
    var automaticIndexScenario: Bool { exists("automatic-index-scenario") }
    var chosenDiagnosticFile: URL?
    var chosenImageFolder: URL?
    var chosenImageProjector: URL?

    private lazy var translationSuite = "io.github.surfire.lumen.gui-smoke.\(UUID())"
    private lazy var translationPreferences = UserDefaults(suiteName: translationSuite)
    private let translationSecrets = SmokeTranslationSecrets()
    var shortcutFixturePreferences: UserDefaults? { exists("quicklinks-scenario") ? translationPreferences : nil }

    func makeClipboardManager() -> ClipboardManager {
        ClipboardManager(defaults: translationPreferences!, pasteboard: filePasteboard,
                         directory: clipboardFixtureRoot.appendingPathComponent("Clipboard", isDirectory: true),
                         automaticPolling: false, sessionCenter: clipboardSession, isConsoleSessionActive: { true })
    }

    func makeTranslationModel() -> TranslationPanelModel {
        TranslationPanelModel(defaults: translationPreferences, client: .init(secrets: translationSecrets, timeout: 3))
    }

    private init(_ directory: URL, language: String, usesOffscreenWindows: Bool) {
        self.directory = directory
        self.appRoots = [directory.appendingPathComponent("Applications", isDirectory: true)]
        gemmaHome = ProcessInfo.processInfo.environment["LUMEN_GEMMA_TEST_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? directory.appendingPathComponent("missing-gemma", isDirectory: true)
        corpus = directory.appendingPathComponent("corpus", isDirectory: true)
        database = directory.appendingPathComponent("index.sqlite")
        startsWithIndex = FileManager.default.fileExists(atPath: database.path)
        let fixture = directory.appendingPathComponent("fixture-engine")
        let live = directory.appendingPathComponent("watch-engine")
        controlledTiming = FileManager.default.isExecutableFile(atPath: fixture.path)
        executable = controlledTiming ? fixture
            : (FileManager.default.isExecutableFile(atPath: live.path) ? live : nil)
        self.language = language
        self.usesOffscreenWindows = usesOffscreenWindows
    }

    static func configuration() -> LauncherSmoke? {
        let arguments = CommandLine.arguments
        guard let mode = arguments.dropFirst().first, ["--gui-smoke", "--verify-resident-startup"].contains(mode) else { return nil }
        guard arguments.count == 4, ["en", "zh"].contains(arguments[3]) else {
            fputs("usage: Lumen --gui-smoke TEMP_DIRECTORY en|zh\n", stderr)
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true).resolvingSymlinksInPath()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let corpus = directory.appendingPathComponent("corpus", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard directory.path.hasPrefix(temp + "/"), corpus.resolvingSymlinksInPath() == corpus,
              FileManager.default.fileExists(atPath: corpus.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            fputs("GUI smoke requires an isolated temporary directory with a synthetic corpus.\n", stderr)
            exit(2)
        }
        return LauncherSmoke(directory, language: arguments[3], usesOffscreenWindows: mode == "--gui-smoke")
    }

    func dispatch(_ action: LaunchAction, completion: @escaping (Bool) -> Void) {
        dispatchedActions.append(action.destination)
        switch action.destination {
        case .application(let url, _) where url.resolvingSymlinksInPath().path ==
            appRoots[0].appendingPathComponent("Lumen Action Probe.app").resolvingSymlinksInPath().path:
            LaunchDispatcher.perform(action, activates: false, completion: completion)
        default:
            completion(true)
        }
    }

    func run(_ app: AppDelegate) async {
        do {
            if !usesOffscreenWindows {
                try await Task.sleep(for: .milliseconds(150))
                try check(NSApp.activationPolicy() == .accessory && !wasActivated && !NSApp.isActive && !app.searchPresented &&
                          NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                          !NSApp.windows.contains { $0 is SearchPanel }, "ordinary launch activated or created a search panel")
                try check(app.statusMenu?.items.first?.action == #selector(AppDelegate.showSearch),
                          "ordinary launch did not expose the menu fallback")
                print("Accessory startup passed without panel creation or activation")
                NSApp.terminate(nil)
                return
            }
            defer { translationPreferences?.removePersistentDomain(forName: translationSuite) }
            try await verify(app)
            translationPreferences?.removePersistentDomain(forName: translationSuite)
            let engine = controlledTiming ? "controlled timing fixture" : (executable == nil ? "bundled engine" : "live engine")
            print("GUI smoke passed (\(language), \(engine), \(startsWithIndex ? "existing index" : "first run"))")
            NSApp.terminate(nil)
        } catch {
            fputs("GUI smoke failed: \(error)\n", stderr)
            app.model.close()
            app.globalHotKey.close()
            exit(1)
        }
    }

    private func verify(_ app: AppDelegate) async throws {
        if exists("cooperative-pipe-scenario") {
            try await verifyCooperativePipeProgress()
            return
        }
        let model = app.model
        var observedScan: [IndexProgress] = []
        var observedWatch: [IndexProgress] = []
        let scanObservation = model.$scanProgress.compactMap { $0 }.sink { observedScan.append($0) }
        let watchObservation = model.$watchProgress.compactMap { $0 }.sink { observedWatch.append($0) }
        defer { scanObservation.cancel(); watchObservation.cancel() }
        try check(!app.searchPresented && !NSApp.windows.contains { $0 is SearchPanel }, "startup opened the search panel")
        guard let search = app.statusMenu?.items.first, let action = search.action else { throw Failure("missing status menu item") }
        try check(NSApp.sendAction(action, to: search.target, from: search), "menu fallback did not open search")
        app.panel.contentView?.layoutSubtreeIfNeeded()
        defer { app.globalHotKey.close() }
        try check(NSApp.activationPolicy() == .prohibited && !NSApp.isActive, "test app became active")
        try check(app.searchField.placeholderString == (language == "zh" ? "搜索文件、应用和系统设置" : "Search files, apps, and system settings"),
                  "search field did not use requested language")
        _ = try editor(app)
        try check(app.panel.styleMask.contains(.nonactivatingPanel) &&
                  app.panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle],
                  "search panel was activating or had incorrect Spaces behavior")
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            try check(abs(app.panel.frame.midX - visible.midX) <= 1 &&
                      abs(app.panel.frame.maxY - (visible.maxY - visible.height / 3)) <= 1,
                      "search panel was not anchored in the upper third of the pointer's screen")
        }

        if exists("streaming-scenario") {
            try await verifyStreaming(app)
            return
        }
        if exists("image-scenario") {
            try await verifyImageSearch(app)
            return
        }
        if exists("reopen-scenario") {
            let timer = ContinuousClock.now
            try type("existing-reopen-fixture", into: app)
            try await until("searchable saved catalog on reopen") {
                model.hits.contains { $0.name == "existing-reopen-fixture.txt" }
            }
            let elapsed = timer.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            let fallback = exists("reopen-fallback")
            if fallback {
                try await until("fallback traversal reached its held extractor") { self.exists("reopen-helper-started") }
                try check(model.watchState == .starting, "saved lookup waited for the fallback traversal")
                try signal("finish-reopen")
            }
            try await until("catch-up finished") { model.watchState == .running }
            try type("new-offline-reopen-fixture", into: app)
            try await until("name added while the app was stopped") {
                model.hits.contains { $0.name == "new-offline-reopen-fixture.txt" }
            }
            try type("deleted-reopen-fixture", into: app)
            try await until("deleted name was removed") { !model.searching && model.hits.isEmpty }
            try await Task.sleep(for: .milliseconds(350))
            try check(model.watchProgress == nil, "idle watcher kept emitting startup progress")
            print("Native cached reopen first filename: \(milliseconds) ms, fallback: \(fallback)")
            return
        }

        if exists("content-scenario") {
            try await verifyContentPipeline(app)
            return
        }
        if automaticIndexScenario {
            app.showSearch()
            try type("archive", into: app)
            try await until("automatic name indexing reports progress without dismissing the search") {
                model.scanProgress?.entries == 17 && model.isIndexing && app.searchPresented
            }
            try signal("finish-cold-progress")
            try await until("automatic first launch returned names without reopening") {
                model.watchState == .running && model.hits.contains { $0.name == "archive-one.txt" }
            }
            try check(app.searchPresented && model.query == "archive" && model.savedScope?.documents == false,
                      "automatic indexing stole focus, cleared input, or enabled document indexing")
            return
        }

        if exists("action-scenario") {
            try verifyClipboardOptIn(app.clipboard)
            try writeClipboardText("External copy fixture")
            app.clipboard.poll()
            try check(app.clipboard.items.map(\.text) == ["External copy fixture"], "copy regression did not start with active capture")
            try await verifyActions(app)
            app.clipboard.clearAll()
            try await verifyClipboardHistory(app)
            return
        }

        if exists("external-volume-scenario") {
            try await verifyExternalVolumes(app)
            return
        }

        if controlledTiming && startsWithIndex {
            if exists("settings-scenario") {
                try await verifySettings(app)
                return
            }
            if exists("legacy-bge-consent") {
                if exists("hold-startup-watch") {
                    try await until("startup permission verification held") { model.indexPhase == .ready && self.exists("startup-watch-started") }
                    try type("archive", into: app)
                    try await Task.sleep(for: .milliseconds(170))
                    try check(!model.canSearch && model.hits.isEmpty, "cached names became visible before scope verification")
                    try signal("finish-startup-watch")
                    try await until("startup scope verified") { model.canSearch && model.hits.contains { $0.name == "archive-one.txt" } }
                }
                try await verifyLegacyMigration(app)
                return
            }
            try await verifyFailedScopeRelaunch(app)
            return
        }

        if startsWithIndex {
            try await until("existing index recognized") { model.indexPhase == .ready }
        } else {
            try check(model.indexPhase == .needsIndex, "first run did not enter the index guide")
            try type("archive", into: app)
            try check(model.query == "archive" && model.hits.isEmpty, "search input did not reach first-run state")
            if controlledTiming { model.scope.content_roots = nil }
            model.scope.documents = controlledTiming
            app.startBackgroundIndex()
            try check(model.isIndexing && app.searchPresented, "starting the name index dismissed the launcher")
            if controlledTiming {
                try await until("cold progress available while launcher stays open") {
                    model.scanProgress?.entries == 17 && app.searchPresented &&
                        app.statusMenu?.items.contains(where: { $0.title.contains("剩余时间待估") }) == true
                }
                try check(model.scanProgress?.fraction == nil && model.scanProgress?.eta == nil &&
                          app.statusMenu?.items.contains(where: { $0.title.contains("剩余时间待估") }) == true,
                          "cold progress showed an estimate or was missing from menu")
                try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
                try check(!app.searchPresented && model.isIndexing, "Escape canceled background indexing")
                try signal("finish-cold-progress")
            }
            do {
                try await until("first names snapshot ready") { model.indexPhase == .ready }
                if controlledTiming {
                    try check(!app.searchPresented, "completing the scan reopened a dismissed panel")
                    app.showSearch()
                    try type("archive", into: app)
                } else {
                    try check(app.searchPresented && model.query == "archive", "completing the scan reset launcher input")
                }
                try await until("names searchable after the first scan") { model.hits.contains { $0.name == "archive-one.txt" } }
            } catch {
                let detail = model.indexNotice?.detail ?? model.searchNotice?.detail ?? "no engine error"
                throw Failure("\(error) (phase \(model.indexPhase), work \(String(describing: model.indexWork)), searching \(model.searching): \(detail))")
            }
        }

        if controlledTiming {
            try await until("document task held by fixture") { self.exists("documents-started") }
            try await until("engine estimate rendered during document pass") {
                model.scanProgress?.eta == 12 && model.activityMetrics?.contains("剩余时间待估") == false
            }
            try check(model.indexWork == .documents, "names were not searchable during document indexing")
            try check(model.hits.allSatisfy { $0.matched_by != "text" }, "first scan included text")
            try signal("finish-documents")
            try await until("watch process started") { model.indexWork == nil && model.watchState == .running }
            try await verifyTiming(app)
            try await verifyWatch(app)
            try await verifyModelResources(app)
            try await verifyStaleBeforeDisplay(app)
            try await verifyReplacedDocument(app)
            try await verifyMissingPath(app)
            try await verifyEmbeddingRun(app)
            try await verifySemanticInvalidation(app)
            if exists("capture-snapshots") { try await captureSnapshots(app) }
        } else {
            try await until("watch capability checked") { model.watchState != .checking }
            if model.watchState == .unavailable {
                try check(executable == nil, "the supplied watch engine did not expose the watch command")
                print("Bundled engine reports manual index updates")
                model.verifyLocalModel()
                try await until("baseline engine reports missing Gemma support") {
                    model.localModelState == .unavailable(.unsupported)
                }
            } else if exists("legacy-expected") {
                try await until("legacy index requires a new explicit scope") { model.watchState == .needsSetup }
                app.startBackgroundIndex()
                try check(app.settings != nil && app.settingsSession.page == .index &&
                          app.settingsSession.canApply && !app.settingsSession.canRebuild && !model.isIndexing,
                          "legacy index could rebuild with an inferred scope")
                return
            } else {
                try await until("real watch ready event received") { model.watchState == .running }
                if exists("verify-engine-progress") {
                    try await until("real engine progress reached the launcher from both processes") {
                        observedScan.contains { $0.phase == "done" && $0.entries > 0 } && !observedWatch.isEmpty
                    }
                }
                if exists("actual-gemma") {
                    try await verifyInstalledModel(app)
                    return
                }
                if executable == nil && !startsWithIndex { try await measureBundledHan(app) }
                try await verifyWatch(app)
                try await verifyAppliedScope(app)
            }
        }

        try await verifyCloudAction(app)
        try type("archive", into: app)
        try await until("strong archive titles precede any body hits") {
            !model.searching && model.hits.prefix(2).map(\.name) == ["archive-one.txt", "archive-two.txt"]
        }
        let expected = model.hits[1].path
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try check(model.selection == expected, "down arrow did not select the second row")
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("Command–Return selected a local file in Finder") { self.revealed?.path == expected }
        try check(opened == nil && model.query == "archive", "Finder shortcut opened the file or changed the query")
        revealed = nil
        try key(kVK_UpArrow, "\u{f700}", in: app)
        try check(model.selection == model.hits.first?.path, "up arrow did not restore the first row")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_Return, "\r", in: app)
        try await until("Return opened the selected synthetic file and cleared the session") {
            self.opened?.path == expected && model.query.isEmpty && model.hits.isEmpty
        }

        app.showSearch()
        try type("青山月报", into: app)
        try await until("Chinese filename found") { model.hits.first?.name == "青山月报.md" }
        let fieldEditor = try editor(app)
        fieldEditor.setMarkedText("qing", selectedRange: NSRange(location: 4, length: 0),
                                  replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        try check(fieldEditor.hasMarkedText(), "could not exercise marked-text routing")
        try check(!app.control(app.searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.moveDown(_:))),
                  "down arrow intercepted marked text")
        try check(!app.control(app.searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                  "Return intercepted marked text")
        try check(!app.control(app.searchField, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
                  "Escape intercepted marked text")
        let revealKey = try event(kVK_Return, "\r", in: app, flags: [.command])
        _ = app.panel.performKeyEquivalent(with: revealKey)
        try check(revealed == nil, "Command–Return interrupted IME composition")
        let priorPasteboard = filePasteboard.string(forType: .string)
        let previewKey = try event(kVK_ANSI_Y, "y", in: app, flags: [.command])
        let pathKey = try event(kVK_ANSI_C, "c", in: app, flags: [.command, .option])
        _ = app.panel.performKeyEquivalent(with: previewKey)
        _ = app.panel.performKeyEquivalent(with: pathKey)
        try check(fieldEditor.hasMarkedText() && app.localPreview == nil &&
                  filePasteboard.string(forType: .string) == priorPasteboard, "file action interrupted IME composition")
        fieldEditor.unmarkText()
        try type("qingshan", into: app)
        try await until("pinyin filename found") { model.hits.first?.matched_by == "pinyin" }
        try type("", into: app)
        try check(model.hits.isEmpty && model.selection == nil && model.query.isEmpty, "native query clear left results")

        try type("archive", into: app)
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(model.query.isEmpty && model.hits.isEmpty && app.searchField.currentEditor() == nil,
                  "Escape did not dismiss the panel and reset the editor")
        if executable == nil && !startsWithIndex {
            try verifyShortcut(app)
        } else {
            app.showSearch()
        }
        _ = try editor(app)
        try check(!NSApp.isActive && model.indexPhase == .ready, "reopening broke residency or background isolation")

        if controlledTiming {
            try await verifyFailedScopeApply(app)
            try await verifyInterruptedScopeApply(app)
        }
    }

    private func verifyInternalCopy(_ app: AppDelegate, _ label: String) throws {
        try check(filePasteboard.types?.contains(ClipboardManager.internalType) == true, "\(label) was not marked internal")
        app.clipboard.poll()
        try check(app.clipboard.items.map(\.text) == ["External copy fixture"], "\(label) leaked into clipboard history")
    }

    private func writeClipboardText(_ text: String, marker: String? = nil) throws {
        let item = NSPasteboardItem()
        try check(item.setString(text, forType: .string), "could not write text fixture")
        filePasteboard.clearContents()
        if let marker {
            let tagged = NSPasteboardItem()
            try check(tagged.setData(Data(), forType: .init(marker)), "could not write marker fixture")
            // A marker on another item must protect the entire pasteboard change.
            try check(filePasteboard.writeObjects([item, tagged]), "could not write marked pasteboard fixture")
        } else {
            try check(filePasteboard.writeObjects([item]), "could not write text to the named pasteboard")
        }
    }

    private func verifyClipboardOptIn(_ history: ClipboardManager) throws {
        try check(!history.enabled && history.limit == 200, "clipboard capture was not opt-in with a 200-item default")
        try writeClipboardText("before opt-in")
        history.poll()
        history.setEnabled(true)
        try check(makeClipboardManager().enabled, "clipboard opt-in did not persist")
        history.poll()
        try writeClipboardText(" \n\t ")
        history.poll()
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                       "org.nspasteboard.AutoGeneratedType", "com.apple.is-sensitive", ClipboardManager.internalType.rawValue] {
            try writeClipboardText("protected fixture", marker: marker)
            history.poll()
            try check(history.items.isEmpty, "clipboard history captured a change marked \(marker)")
        }
        clipboardSession.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try writeClipboardText("inactive session")
        history.poll()
        clipboardSession.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        history.poll()
        try check(history.items.isEmpty && !FileManager.default.fileExists(atPath: history.store.directory.path),
                  "a skipped clipboard change created private storage")
    }

    private func verifyClipboardHistory(_ app: AppDelegate) async throws {
        try verifyClipboardStorageLinks()
        try verifyClipboardDeduplication()
        try verifyInactiveClipboardStartup()
        try verifyClipboardFilterLatency()
        try await verifyOriginalClipboardPNG()
        app.showSearch()
        let history = app.clipboard
        let store = history.store
        let board = filePasteboard
        let fm = FileManager.default
        func write(_ text: String) throws { try writeClipboardText(text) }

        for text in ["A café receipt", "Côté açai frais", "Frequently asked cases"] {
            try write(text)
            history.poll()
        }
        try type("cb cÁf", into: app)
        try check(app.commands.clipboardRows.map(\.text) == ["A café receipt", "Côté açai frais"] && app.model.query.isEmpty,
                  "history search did not rank substrings over ordered fuzzy matches or ignored case/diacritics")
        history.clearAll()

        let invoice = "October Invoice\nSynthetic line two"
        let earliestCapture = Date.now
        try write(invoice)
        history.poll()
        guard let pinned = history.items.first else { throw Failure("text capture did not reach history") }
        try check(history.items.count == 1 && pinned.text == invoice && pinned.capturedAt >= earliestCapture,
                  "captured text or timestamp did not round-trip")
        try write(invoice)
        history.poll()
        try check(history.items == [pinned], "consecutive identical text captured twice")
        try type("?", into: app)
        guard let discoveryIndex = app.commands.entries.firstIndex(where: { $0.commandID == "clipboard" }) else {
            throw Failure("clipboard missing from discovery")
        }
        let entry = app.commands.entries[discoveryIndex]
        for (chinese, title) in [(true, "剪贴板历史"), (false, "Clipboard History")] {
            let card = LauncherCommandCard(commands: app.commands, provider: app.translation, chinese: chinese,
                                           activate: {}, openSettings: {})
            try check(card.entryTitle(entry) == title, "clipboard discovery did not localize")
        }
        for _ in 0..<discoveryIndex { try key(kVK_DownArrow, "\u{f701}", in: app) }
        try key(kVK_Return, "\r", in: app)
        try check(try editor(app).string == "cb " && app.commands.resolution == .clipboard(""),
                  "discovery did not open clipboard history")
        for verb in ["cb", "cb ", "clip", "CLIP\t"] {
            try type(verb, into: app)
            try check(app.commands.resolution == .clipboard("") && app.commands.clipboardSelection == pinned.id,
                      "clipboard verb did not immediately select a row")
        }
        for verb in ["cb", "clip"] {
            try type(verb, into: app)
            try activateClipboardFileFallback(app)
            try check(try editor(app).string == verb && app.commands.resolution == .search && app.model.query == verb,
                      "Search Files did not keep the bare \(verb) query and return focus to file search")
            try await until("Search Files did not find the literal file named \(verb)") {
                app.model.hits.contains { $0.name == verb }
            }
        }
        try type("cb ", into: app)
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.shift])
        try check(app.contextActions.items.map(\.id) == ["copy-clip", "pin-clip", "delete-clip"],
                  "Shift–Return did not show clipboard actions")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_Return, "\r", in: app)
        try check(history.items.first?.pinned == true && app.searchPresented && !app.contextActions.isOpen,
                  "clipboard Pin action failed")

        history.setLimit(3)
        for text in ["oldest unpinned", "to be pruned", "recent text"] {
            try write(text)
            history.poll()
        }
        try check(history.items.map(\.text) == ["recent text", "to be pruned", invoice] && history.items.last?.pinned == true,
                  "LRU did not preserve the oldest pin")
        let editorBefore = try editor(app)
        let image = NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation else { throw Failure("could not encode TIFF fixture") }
        func writeImage() throws {
            board.clearContents()
            try check(board.setData(tiff, forType: .tiff), "could not put TIFF fixture on the named pasteboard")
        }
        try writeImage()
        await history.poll()?.value
        guard let clip = history.items.first, clip.text == nil,
              let png = try store.image(id: clip.id), let thumbnail = try store.thumbnail(id: clip.id),
              let full = NSBitmapImageRep(data: png), let thumb = NSBitmapImageRep(data: thumbnail) else {
            throw Failure("image capture did not produce a PNG and thumbnail")
        }
        try check(full.pixelsWide > thumb.pixelsWide && thumb.pixelsWide <= 240 && png.count <= 2 * 1024 * 1024 &&
                  png.starts(with: [137, 80, 78, 71]) && thumbnail.starts(with: [137, 80, 78, 71]),
                  "image payload or thumbnail had the wrong format or dimensions")
        try writeImage()
        await history.poll()?.value
        try check(history.items.map(\.id).first == clip.id && history.items.count == 3,
                  "consecutive identical image was not deduplicated")
        try type("cb INVOICE", into: app)
        try check(app.commands.clipboardRows.map(\.id) == [pinned.id] && app.model.query.isEmpty,
                  "clipboard substring filter failed or ran a file search")
        try type("clip", into: app)
        try check(app.commands.clipboardSelection == clip.id && app.commands.clipboardRows.count == 3,
                  "clearing filter did not select the newest image")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try check(app.commands.selectedClipboardItem?.text == "recent text", "Down did not select the second clipboard row")
        try key(kVK_UpArrow, "\u{f700}", in: app)
        try check(app.commands.clipboardSelection == clip.id, "Up did not restore the first clipboard row")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_DownArrow, "\u{f701}", in: app)
        func preview(_ view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if view.identifier?.rawValue == "clipboard-text-preview" {
                return (view as? NSScrollView)?.documentView as? NSTextView
            }
            return view.subviews.lazy.compactMap { preview($0) }.first
        }
        try await until("the actual clipboard preview did not show the selected row's full text") {
            app.panel.contentView?.layoutSubtreeIfNeeded()
            return preview(app.panel.contentView)?.string == invoice
        }
        try check(app.panel.firstResponder === editorBefore, "clipboard navigation stole field focus")
        try key(kVK_Return, "\r", in: app)
        try check(!app.searchPresented && board.string(forType: .string) == invoice &&
                  board.types?.contains(ClipboardManager.internalType) == true,
                  "Return did not copy the selected text with the internal marker and dismiss")
        history.poll()
        try check(history.items.first?.id == pinned.id && history.items.count == 3,
                  "reusing a clip did not touch its LRU position, or captured a duplicate")

        let files = try fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        let mode = try fm.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber
        let permissions = try files.map { try fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber }
        try check(mode?.intValue == 0o700 && !files.isEmpty && permissions.allSatisfy { $0?.intValue == 0o600 },
                  "clipboard storage permissions were not private")
        try check(try ClipboardStore(directory: store.directory).items() == history.items,
                  "a reopened store lost entries, metadata, or pins")
        app.showSearch()
        try type("cb", into: app)
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_Return, "\r", in: app)
        try check(!app.searchPresented && board.data(forType: .png) == png && board.types?.contains(ClipboardManager.internalType) == true,
                  "Return did not copy the bounded PNG with the internal marker")
        try write(String(repeating: "界", count: 16_384))
        history.poll()
        try check(history.items.first?.text?.utf8.count == 32_766 && history.items.contains(where: { $0.id == clip.id }) &&
                  !history.items.contains(where: { $0.text == "recent text" }), "UTF-8 cap or LRU reuse failed")
        app.showSearch()
        try type("clip", into: app)
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_Return, "\r", in: app)
        try check(try store.image(id: clip.id) == nil && !app.commands.clipboardRows.contains { $0.id == clip.id },
                  "Delete did not remove the selected image")

        try store.clearUnpinned()
        try check(try store.items().map(\.id) == [pinned.id], "clearUnpinned deleted a pin or retained a recent clip")
        try writeImage()
        let inFlightImage = history.poll()
        history.clearAll()
        await inFlightImage?.value
        try check(try history.items.isEmpty && ClipboardStore(directory: store.directory).items().isEmpty &&
                  app.commands.clipboardRows.isEmpty, "Clear All did not remove pins and persisted history")
        try key(kVK_ANSI_Comma, ",", in: app, throughPanel: true, flags: [.command])
        try check(app.settingsSession.page == .general && !app.searchPresented, "clipboard Settings did not open General")
        if let file = files.first {
            chosenDiagnosticFile = file
            app.chooseDiagnosticFile()
            if case .idle = app.model.fileDiagnosis {} else { throw Failure("clipboard store was passed to diagnostics") }
        }
        history.setEnabled(false)
        try write("after opting out")
        history.poll()
        let reopened = makeClipboardManager()
        try check(history.items.isEmpty && !reopened.enabled && reopened.limit == 3,
                  "capture continued after opt-out or settings did not persist")
        print("Clipboard history passed: named pasteboard capture, five privacy markers, session pause, private persistence, LRU, command routing, preview selection, copy and deletion")
    }

    private func activateClipboardFileFallback(_ app: AppDelegate) throws {
        // Activate the Search Files button's bound action in the live, offscreen SwiftUI view.
        guard let results = app.panel.contentView?.subviews.compactMap({ $0 as? NSHostingView<SearchWindow> }).first else {
            throw Failure("could not find the launcher results view")
        }
        results.rootView.searchCommandAsFiles()
    }

    private func verifyInactiveClipboardStartup() throws {
        let session = NotificationCenter()
        let board = NSPasteboard.withUniqueName()
        var onConsole = true
        var samples = 0
        let history = ClipboardManager(defaults: translationPreferences!, pasteboard: board,
            directory: clipboardFixtureRoot.appendingPathComponent("inactive-startup/Clipboard"), automaticPolling: false,
            sessionCenter: session, isConsoleSessionActive: { samples += 1; return onConsole })
        defer { history.stop() }
        try check(history.enabled && samples == 0, "session was sampled before clipboard capture started")
        // The session can change after construction but before notification registration.
        onConsole = false
        history.start()
        try check(samples == 1, "start did not sample the initial session state")
        func write(_ text: String) throws {
            board.clearContents()
            try check(board.setString(text, forType: .string), "could not write startup session fixture")
            history.poll()
        }
        try write("inactive at launch")
        session.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        history.poll()
        try check(history.items.isEmpty && !FileManager.default.fileExists(atPath: history.store.directory.path),
                  "inactive startup captured a change before the session became active")
        try write("active after launch")
        try check(history.items.map(\.text) == ["active after launch"], "capture did not resume on session activation")
    }

    private func verifyClipboardDeduplication() throws {
        let store = ClipboardStore(directory: clipboardFixtureRoot.appendingPathComponent("dedup/Clipboard"), limit: 2)
        for pinned in [false, true] {
            try store.clearAll()
            let start = Date(timeIntervalSince1970: 1234)
            try check(try store.addText("A", capturedAt: start, bundleID: nil, appName: nil), "could not insert A")
            guard let a = try store.items().first else { throw Failure("missing deduplication fixture A") }
            if pinned { try store.togglePin(id: a.id) }
            try check(try store.addText("B", capturedAt: start + 1, bundleID: nil, appName: nil), "could not insert B")
            try check(try store.addText("A", capturedAt: start + 2, bundleID: "test.recapture", appName: nil), "could not recapture A")
            let rows = try store.items()
            try check(rows.map(\.text) == ["A", "B"] && rows.first?.id == a.id && rows.first?.pinned == pinned &&
                      rows.first?.capturedAt == start + 2 && rows.first?.sourceBundleID == "test.recapture",
                      "A, B, A did not refresh the existing row without evicting B (pinned: \(pinned))")
        }
    }

    private func verifyClipboardFilterLatency() throws {
        let text = String(repeating: "A", count: ClipboardStore.maximumTextBytes - 9) + " tail hit"
        let items = (0..<500).map { id in
            ClipboardItem(id: Int64(id), text: text, capturedAt: .now, sourceBundleID: "org.lumen.fixture",
                          sourceAppName: "Fixture Editor", pinned: false)
        }
        try check(ClipboardItem.filtered(items, for: "fíxture editor").count == 500 &&
                  ClipboardItem.filtered(items, for: "tail hit").isEmpty && items.first?.text == text,
                  "search should fold metadata, index only the text prefix, and preserve the full payload")
        // Nearly matching substring and fuzzy needles both fail at the last scalar.
        let query = String(repeating: "a", count: 31) + "z"
        let clock = ContinuousClock()
        let samples = try (0..<20).map { _ in
            let start = clock.now
            let rows = ClipboardItem.filtered(items, for: query)
            let elapsed = start.duration(to: clock.now)
            try check(rows.isEmpty, "worst-case clipboard filter unexpectedly matched")
            return elapsed
        }.sorted()
        let p95 = samples[18]
        try check(p95 < .milliseconds(15), "500-item clipboard search exceeded 15 ms (p95: \(p95))")
        print("500-item clipboard no-match search: p95 \(p95)")
    }

    private func verifyClipboardStorageLinks() throws {
        let fm = FileManager.default
        let root = clipboardFixtureRoot.appendingPathComponent("linked-storage")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        let original = Data("outside clipboard storage".utf8)
        try original.write(to: sentinel)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sentinel.path)
        func reject(_ location: URL) throws {
            let store = ClipboardStore(directory: location)
            do { _ = try store.items() }
            catch {
                do { _ = try store.addText("private", capturedAt: .now, bundleID: nil, appName: nil) }
                catch { return }
                throw Failure("clipboard write accepted unsafe storage at \(location.path)")
            }
            throw Failure("clipboard read accepted unsafe storage at \(location.path)")
        }
        let linkedDirectory = root.appendingPathComponent("Clipboard")
        try fm.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
        try reject(linkedDirectory)
        try reject(linkedDirectory.appendingPathComponent("nested/Clipboard"))
        let index = outside.appendingPathComponent("index.sqlite")
        func makeIndexFixture() throws {
            var handle: OpaquePointer?
            defer { sqlite3_close(handle) }
            try check(sqlite3_open(index.path, &handle) == SQLITE_OK &&
                      sqlite3_exec(handle, "CREATE TABLE search_index (name TEXT)", nil, nil, nil) == SQLITE_OK,
                      "could not create the hardlink target database")
        }
        try makeIndexFixture()
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index.path)
        let indexBytes = try Data(contentsOf: index)
        for hardlink in [false, true] {
            for name in [".history.sqlite", ".history.sqlite-wal", ".history.sqlite-shm", ".history.sqlite-journal"] {
                let location = root.appendingPathComponent("\(hardlink ? "hardlink" : "symlink")-\(name)")
                let store = ClipboardStore(directory: location)
                try check(try store.addText("initial", capturedAt: .now, bundleID: nil, appName: nil), "could not seed link fixture")
                let link = location.appendingPathComponent(name)
                if name == ".history.sqlite" { try fm.removeItem(at: link) }
                if hardlink { try fm.linkItem(at: index, to: link) }
                else { try fm.createSymbolicLink(at: link, withDestinationURL: sentinel) }
                try reject(location)
                if hardlink {
                    // The original connection must also stop before clearing any blobs.
                    let refusedCleanup: Bool
                    do { try store.clearAll(); refusedCleanup = false }
                    catch { refusedCleanup = true }
                    try check(refusedCleanup && Data(contentsOf: link) == indexBytes,
                              "clipboard cleanup accepted, changed, or removed the hardlink")
                }
            }
        }
        try check(try Data(contentsOf: sentinel) == original && Data(contentsOf: index) == indexBytes &&
                  Set(fm.contentsOfDirectory(atPath: outside.path)) == ["sentinel", "index.sqlite"] &&
                  [sentinel, index].allSatisfy {
                      (try fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue == 0o644
                  }, "unsafe storage modified files outside the clipboard directory")
    }

    private func verifyOriginalClipboardPNG() async throws {
        let board = NSPasteboard.withUniqueName()
        let storeDirectory = clipboardFixtureRoot.appendingPathComponent("png-fidelity/Clipboard")
        let history = ClipboardManager(defaults: translationPreferences!, pasteboard: board, directory: storeDirectory,
            automaticPolling: false, sessionCenter: NotificationCenter(), isConsoleSessionActive: { true })
        history.start()
        defer { history.stop() }
        // Force explicit pixel dimensions regardless of the display's backing scale.
        let width = 1800
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 24, bitsPerSample: 8,
                                           samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData else {
            throw Failure("could not create original PNG fixture")
        }
        memset(pixels, 90, bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= ClipboardStore.maximumImageBytes else {
            throw Failure("original PNG fixture exceeded the byte budget")
        }
        board.clearContents()
        try check(board.setData(png, forType: .png), "could not put original PNG on pasteboard")
        await history.poll()?.value
        guard let clip = history.items.first else { throw Failure("valid PNG was not captured") }
        try check(try history.store.image(id: clip.id) == png && history.copy(id: clip.id) && board.data(forType: .png) == png,
                  "bounded original PNG was resized or re-encoded")

        // A valid, highly compressible PNG just above the pixel budget. Build it from
        // packed 1-bit scanlines so the fixture itself never allocates a large raster.
        let oversizedPNG = try makeOversizedClipboardPNG()
        board.clearContents()
        try check(board.setData(oversizedPNG, forType: .png), "could not put oversized PNG on pasteboard")
        await history.poll()?.value
        try check(history.items == [clip], "oversized PNG was captured or resized instead of being rejected")

        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        let path = storeDirectory.appendingPathComponent(".history.sqlite").path
        try check(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, "could not open corrupt blob fixture")
        let marker = board.changeCount
        let oversizedHex = oversizedPNG.map { String(format: "%02x", $0) }.joined()
        for blob in ["X'89504e470d0a1a0a'", "X'\(oversizedHex)'", "zeroblob(\(ClipboardStore.maximumImageBytes + 1))"] {
            try check(sqlite3_exec(handle, "UPDATE clips SET image = \(blob) WHERE id = \(clip.id)", nil, nil, nil) == SQLITE_OK,
                      "could not inject an invalid image row")
            try check(try history.store.image(id: clip.id) == nil && !history.copy(id: clip.id) && board.changeCount == marker,
                      "an invalid stored image could be copied to the pasteboard")
        }
    }

    private func makeOversizedClipboardPNG() throws -> Data {
        let width = 8_000, height = 4_001
        let scanlines = Data(count: (width / 8 + 1) * height) // One filter byte per row.
        var size = compressBound(uLong(scanlines.count))
        var compressed = Data(count: Int(size))
        let status = scanlines.withUnsafeBytes { input in
            compressed.withUnsafeMutableBytes { output in
                compress(output.bindMemory(to: UInt8.self).baseAddress, &size,
                         input.bindMemory(to: UInt8.self).baseAddress, uLong(input.count))
            }
        }
        try check(status == Z_OK, "could not compress oversized PNG fixture")
        compressed.count = Int(size)

        func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        func appendChunk(_ type: String, _ payload: Data) {
            let bytes = Data(type.utf8) + payload
            let checksum = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
            png.append(bigEndian(UInt32(payload.count)))
            png.append(bytes)
            png.append(bigEndian(UInt32(checksum)))
        }
        appendChunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + Data([1, 0, 0, 0, 0]))
        appendChunk("IDAT", compressed)
        appendChunk("IEND", Data())
        guard let source = ClipboardStore.imageSource(png),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw Failure("could not read oversized PNG fixture metadata")
        }
        try check(png.count <= ClipboardStore.maximumImageBytes && CGImageSourceGetStatus(source) == .statusComplete &&
                  properties[kCGImagePropertyPixelWidth] as? Int == width && properties[kCGImagePropertyPixelHeight] as? Int == height,
                  "oversized PNG fixture did not have the expected dimensions and byte size")
        return png
    }

    private func verifyActions(_ app: AppDelegate) async throws {
        let model = app.model
        try await verifyCatalogRegressions()
        try await verifyEngineRegressions()
        try check(model.indexPhase == .needsIndex && !model.canSearch, "action smoke unexpectedly had a file index")
        func chosen() -> LaunchAction? {
            if case .action(let action)? = model.selectedResult { return action }
            return nil
        }

        // All typed text passes through the real AppKit field editor.
        let top = app.panel.frame.maxY
        try type("lumen action probe", into: app)
        try await until("a discovered application is selectable before any file index exists") {
            chosen()?.english == "Lumen Action Probe" && app.panel.frame.height == 436
        }
        try check(app.panel.frame.maxY == top, "growing the results panel moved its top edge")
        try type("lap", into: app)
        try await until("an application initialism is selectable") { chosen()?.english == "Lumen Action Probe" }
        guard let probe = chosen(), case .application = probe.destination else {
            throw Failure("selected app reused the file-open route")
        }
        let selectedBeforeArtwork = model.selection
        let orderBeforeArtwork = model.visibleResults.map(\.id)
        let frameBeforeArtwork = app.panel.frame
        guard let artworkKey = ApplicationIcons.Key(probe) else { throw Failure("missing app artwork key") }
        try await until("the visible app row received its bundle artwork") { app.applicationIcons.images[artworkKey] != nil }
        try await until("the actual app row painted its bundle artwork") { self.hasProbeIcon(in: app.panel) }
        app.panel.appearance = nil
        try check(model.selection == selectedBeforeArtwork && model.visibleResults.map(\.id) == orderBeforeArtwork &&
                  app.panel.frame == frameBeforeArtwork,
                  "icon loading changed search order, selection, or the window frame")
        if exists("capture-icons") { try capture("lumen-app-icon.png", appearance: .aqua, window: app.panel) }
        try check(!exists("app-started"), "app launched during lookup")
        if case .application(let url, let stamp) = probe.destination {
            try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
            try check(SearchHit.pathStamp(at: url.path, kind: "directory") != stamp, "failed to update the app stamp")
        }
        try key(kVK_Return, "\r", in: app)
        try await until("a real application launched through NSWorkspace without activation") {
            self.exists("app-started") && !app.searchPresented
        }
        try check(dispatchedActions.first == probe.destination && !NSApp.isActive && !wasActivated,
                  "the app action dispatched elsewhere or activated Lumen")
        if let defaults = shortcutFixturePreferences {
            let reloaded = LauncherFrecency(defaults: defaults)
            try check(reloaded.boost(probe.id) > 0 &&
                      reloaded.boost(probe.id, now: .now.addingTimeInterval(100 * 86_400)) == 0,
                      "the real application launch did not persist app frecency or decay")
        }

        try verifyUnconfiguredQA(app)
        try await verifyInlineTranslation(app)
        try await verifyLauncherCommands(app)
        try verifyProviderDeletion(app.translation)

        for (term, expected) in [
            ("无线局域网", "com.apple.wifi-settings-extension"),
            ("bluetooth", "com.apple.BluetoothSettings"),
            ("系统设置", ""),
        ] {
            app.showSearch()
            try type(term, into: app)
            guard let action = chosen(), case .settings(let url) = action.destination else {
                throw Failure("setting alias was not actionable")
            }
            try check(url.absoluteString == "x-apple.systempreferences:" + expected, "setting alias targeted the wrong destination")
            guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
                  Bundle(url: handler)?.bundleIdentifier == LaunchCatalog.settingsBundleID else {
                throw Failure("Launch Services did not route the URL to Apple System Settings")
            }
            if term == "无线局域网" && exists("capture-icons") {
                try await until("the setting row is laid out offscreen") { app.panel.frame.height == 436 }
                try capture("lumen-setting-icon.png", appearance: .aqua, window: app.panel)
            }
            try key(kVK_Return, "\r", in: app)
            try check(dispatchedActions.last == .settings(url) && !app.searchPresented,
                      "the Return key did not pass the Settings URL to the dispatch seam")
        }

        app.showSearch()
        try type("twin preview", into: app)
        try await until("same-title applications remain separate by bundle identifier and path") {
            model.launchMatches.filter { $0.action.english == "Twin Preview" }.count == 2
        }
        let twins = model.launchMatches.map(\.action).filter { $0.english == "Twin Preview" }
        try check(twins[0].id != twins[1].id && twins[0].destination != twins[1].destination,
                  "same-title applications shared a result identity")
        let icons = ApplicationIcons()
        for twin in twins {
            guard let key = ApplicationIcons.Key(twin) else { throw Failure("missing application icon key") }
            let icon = await icons.image(for: key)
            var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
            let workspaceIcon = NSWorkspace.shared.icon(forFile: key.url.path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
            func png(_ image: CGImage?) -> Data? {
                image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
            }
            try check(icon != nil && png(icon) == png(workspaceIcon),
                      "a local resource link or missing artwork did not use the NSWorkspace icon")
        }
        guard case .action(let second)? = model.visibleResults.dropFirst().first,
              model.selection != second.id else { throw Failure("missing unselected application row") }
        let dispatchCount = dispatchedActions.count
        let rowCenter = NSPoint(x: 160, y: app.panel.frame.height - SearchWindow.headerHeight - 66)
        try await until("the second action row was not hit-testable") {
            app.panel.contentView?.layoutSubtreeIfNeeded()
            return app.panel.contentView?.hitTest(rowCenter) is ActionRowClickTarget
        }
        try click(count: 1, at: rowCenter, in: app.panel)
        try check(model.selection == second.id && dispatchedActions.count == dispatchCount,
                  "single click did not select the row immediately without opening it (selected: \(model.selection ?? "none"))")
        try click(count: 2, at: rowCenter, in: app.panel)
        try check(dispatchedActions.count == dispatchCount + 1 && dispatchedActions.last == second.destination &&
                  !app.searchPresented, "double click did not open the selected row exactly once")
        app.showSearch()
        try type("Wi-Fi", into: app)
        let count = dispatchedActions.count
        try type("not a registered action", into: app)
        try key(kVK_Return, "\r", in: app)
        try check(dispatchedActions.count == count, "Return dispatched an action from a previous query")

        let frecencyFixtures = exists("quicklinks-scenario") ? try makeFileFrecencyFixtures() : nil
        for verb in ["cb", "clip"] {
            try "Literal command name fixture".write(to: corpus.appendingPathComponent(verb), atomically: true, encoding: .utf8)
        }
        app.startBackgroundIndex()
        try await until("the isolated file index became available alongside actions") { model.canSearch && model.watchState == .running }
        try check(model.launcherActivityTitle == nil && model.activityTitle == model.t("正在监听文件变化", "Watching file changes"),
                  "normal watching remained in the launcher or was lost from diagnostics")
        app.showSearch()
        try type("lumen action probe", into: app)
        try await until("file and app results share the same visible list") {
            if case .action(let action)? = model.visibleResults.first, action.id == probe.id {
                return model.hits.contains { $0.name == "Lumen Action Probe notes.txt" }
            }
            return false
        }
        try check(chosen()?.id == probe.id, "late file results moved selection from the application")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try check(model.selectedHit?.name == "Lumen Action Probe notes.txt", "arrow selection did not reach the file result")
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("the file retained its normal Finder route") { self.revealed?.lastPathComponent == "Lumen Action Probe notes.txt" }
        try check(dispatchedActions.count == count, "a file Finder action unexpectedly dispatched a quick action")
        guard let expected = model.selectedHit else { throw Failure("lost the selected file") }
        try key(kVK_ANSI_C, "C", in: app, throughPanel: true, flags: [.command, .shift])
        try await until("Command–Shift–C copied the selected file's name") {
            self.filePasteboard.string(forType: .string) == expected.name && app.searchPresented
        }
        try verifyInternalCopy(app, "Copy File Name")
        try key(kVK_ANSI_C, "c", in: app, throughPanel: true, flags: [.command, .option])
        try await until("Command–Option–C copied the selected file's exact path") {
            self.filePasteboard.string(forType: .string) == expected.path
        }
        try verifyInternalCopy(app, "Copy File Path")
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("Command–Y assigned a local item to the native Quick Look view") { app.localPreview?.previewURL != nil }
        guard let preview = app.localPreview, let snapshot = preview.previewURL else { throw Failure("Quick Look had no item") }
        let snapshotContents = try String(contentsOf: snapshot, encoding: .utf8)
        try check(snapshot.path != expected.path && snapshot.lastPathComponent == expected.name &&
                  snapshotContents == "Synthetic unified search fixture." && !preview.isVisible && !NSApp.isActive,
                  "Quick Look received the original path, bad contents or a visible window")
        let mode = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "Quick Look snapshot had broad file permissions")
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try check(app.localPreview == nil && app.searchPresented && !FileManager.default.fileExists(atPath: snapshot.path),
                  "Command–Y did not toggle the snapshot away while leaving the search open")
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try await until("Space in browse mode toggles real Quick Look") { app.localPreview?.previewURL != nil }
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try check(app.localPreview == nil && app.searchPresented, "Space closed the search rather than just the preview")
        try check(LocalFile.dragURL(for: expected)?.path == expected.path, "the local file did not export a drag URL")
        let similarlyNamed = directory.appendingPathComponent("local/Library/CloudStorage/resident.txt")
        try FileManager.default.createDirectory(at: similarlyNamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local fixture".utf8).write(to: similarlyNamed)
        let residentPath = IndexScope.folderPath(similarlyNamed)
        func dragHit(availability: String) -> SearchHit {
            SearchHit(path: residentPath, name: similarlyNamed.lastPathComponent, kind: "file",
                      availability: availability, matched_by: "name", snippet: nil, document_stamp: nil, pdf_page: nil)
        }
        let resident = dragHit(availability: "local")
        try check(LocalFile.dragURL(for: resident)?.path == residentPath &&
                  LocalFile.dragURL(for: dragHit(availability: "provider_metadata_only")) == nil,
                  "drag eligibility followed the spelling of a local path instead of its residency")
        // Supply provider metadata without relying on a signed-in iCloud account.
        let ubiquitous = LocalFile.dragURL(for: resident) { _, _ in
            [.isUbiquitousItemKey: true, .volumeIsLocalKey: true]
        }
        try check(ubiquitous?.path == residentPath, "a resident iCloud file did not export a drag URL")
        try type("lumen action", into: app)
        try check(!app.panel.browsing, "editing the search field did not return to typing mode")
        try key(kVK_Space, " ", in: app)
        try check(try editor(app).string.hasSuffix(" ") && app.localPreview == nil, "Space did not insert whitespace while typing")

        let definition = "A synthetic definition\nwith a second line."
        let definitionAlert = LauncherSystemActions.definitionAlert(word: "fixture", definition: definition, chinese: false)
        let definitionText = (definitionAlert.accessoryView as? NSScrollView)?.documentView as? NSTextView
        try check(definitionAlert.messageText == "fixture" && definitionText?.string == definition &&
                  definitionText?.isEditable == false && definitionText?.isSelectable == true,
                  "the definition was not presented as selectable plain text")
        let operations: [(String, LauncherSystemActions.Operation)] = [
            ("suoping", .lock), ("睡眠", .sleep), ("empty trash", .emptyTrash), ("切换深色模式", .darkMode),
            ("mute", .mute), ("quxiaojingyin", .unmute), ("eject", .eject), ("define macintosh", .define("macintosh")),
        ]
        for (term, operation) in operations {
            app.showSearch()
            try type(term, into: app)
            guard chosen()?.destination == .system(operation) else { throw Failure("System action not found: \(term)") }
            try key(kVK_Return, "\r", in: app)
            try check(dispatchedActions.last == .system(operation), "System action did not route: \(term)")
        }
        if let defaults = shortcutFixturePreferences {
            try check(LauncherFrecency(defaults: defaults).boost("system:lock") > 0,
                      "a completed system action was not saved to the shared frecency store")
        }
        app.showSearch()

        if exists("syntax-scenario") { try await verifyRawFileQuery(app) }
        if let fixtures = frecencyFixtures {
            try await verifyFileFrecency(app, project: fixtures.project, success: fixtures.success, failure: fixtures.failure)
            app.showSearch()
            try await verifyQuicklinks(app)
        }
        print("Unified actions passed: real background app launch, routed Settings URLs, isolated file copies, and native local Quick Look input")
    }

    private func verifyCatalogRegressions() async throws {
        let manager = FileManager.default
        let roots = directory.appendingPathComponent("Linked Apps", isDirectory: true)
        let target = directory.appendingPathComponent("Visual Studio Code.app", isDirectory: true)
        let contents = target.appendingPathComponent("Contents", isDirectory: true)
        try manager.createDirectory(at: roots, withIntermediateDirectories: true)
        let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
        try manager.createDirectory(at: executables, withIntermediateDirectories: true)
        let probeExecutable = appRoots[0].appendingPathComponent("Lumen Action Probe.app/Contents/MacOS/probe")
        try manager.copyItem(at: probeExecutable, to: executables.appendingPathComponent("resident-probe"))
        try manager.createSymbolicLink(atPath: executables.appendingPathComponent("probe").path,
                                       withDestinationPath: "resident-probe")
        let info: [String: Any] = ["CFBundleIdentifier": "io.github.surfire.lumen.fixture.vsc.\(directory.lastPathComponent)",
                                   "CFBundlePackageType": "APPL", "CFBundleDisplayName": "Visual Studio Code",
                                   "CFBundleExecutable": "probe", "LSBackgroundOnly": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let link = roots.appendingPathComponent("Editor.app")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        let secondLink = roots.appendingPathComponent("Two Hops.app")
        try manager.createSymbolicLink(at: secondLink, withDestinationURL: link)
        let apps = LaunchCatalog.discoverApplications(roots: [roots], extraApps: [])
        try check(apps.count == 1 && ApplicationIcons.Key(apps[0])?.url.path == IndexScope.folderPath(target),
                  "catalog did not resolve the one-level application link: \(apps.map(\.id))")
        try check(LaunchCatalog.discoverApplications(roots: [], extraApps: [secondLink]).isEmpty,
                  "catalog followed a second application link")
        let safari = LaunchAction(id: "app:safari-fixture", english: "Safari", chinese: "Safari", symbol: "app",
                                  destination: apps[0].destination, aliases: [])
        try check(LaunchCatalog.matches("s", actions: [safari]).first?.action == safari &&
                  LaunchCatalog.matches("vsc", actions: apps).first?.action == apps[0],
                  "single-letter prefix or nonconsecutive application match was missing")
        guard let key = ApplicationIcons.Key(apps[0]) else { throw Failure("missing linked bundle icon key") }
        let icon = await ApplicationIcons().image(for: key)
        try check(icon != nil, "an app without a standalone declared image did not get its NSWorkspace icon")
        var launched: Bool?
        LaunchDispatcher.perform(apps[0], activates: false) { launched = $0 }
        try await until("the linked application's resident symlink executable did not launch") {
            launched == false || (launched == true && self.exists("app-started"))
        }
        try check(launched == true, "NSWorkspace did not launch the app through its symlinked executable")
        try manager.removeItem(at: directory.appendingPathComponent("app-started"))
    }

    private func makeFileFrecencyFixtures() throws -> (project: URL, success: URL, failure: URL) {
        let manager = FileManager.default
        let project = corpus.appendingPathComponent("Frecency Pin Project", isDirectory: true)
        let success = corpus.appendingPathComponent("Frecency Open Probe.app", isDirectory: true)
        // A random extension has no registered handler. Non-text bytes avoid a text-editor fallback.
        let failure = corpus.appendingPathComponent("Frecency Unhandled Document.lumensmoke-\(UUID().uuidString)")
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        try manager.copyItem(at: appRoots[0].appendingPathComponent("Lumen Action Probe.app"), to: success)
        try Data([7, 0, 1]).write(to: failure)
        return (project, success, failure)
    }

    private func verifyFileFrecency(_ app: AppDelegate, project: URL, success: URL, failure: URL) async throws {
        guard let defaults = shortcutFixturePreferences else { throw Failure("missing isolated frecency preferences") }
        let model = app.model
        func select(_ term: String, _ url: URL) async throws -> SearchHit {
            app.showSearch()
            try type(term, into: app)
            let path = IndexScope.folderPath(url)
            try await until("frecency fixture was not indexed: \(url.lastPathComponent)") {
                model.hits.contains { $0.path == path }
            }
            if model.selectedHit?.path != path { model.selection = path }
            guard let hit = model.selectedHit, hit.path == path else { throw Failure("missing selected frecency fixture") }
            return hit
        }
        func boost(_ hit: SearchHit) -> Int {
            LauncherFrecency(defaults: defaults).boost(LauncherFrecency.fileID(hit.path))
        }

        let pinned = try await select("frecency pin project", project)
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        guard let pin = app.contextActions.items.firstIndex(where: { $0.id == "pin-folder" }) else {
            throw Failure("the folder result did not offer Pin Project Folder")
        }
        app.contextActions.run(pin)
        try await until("the real Pin Folder action did not save a shortcut") {
            model.shortcuts.entries.contains { $0.target == .folder(pinned.path) && $0.pinned }
        }
        try check(boost(pinned) == 0, "pinning a validated project counted as a file open")
        if let shortcut = model.shortcuts.entries.first(where: { $0.target == .folder(pinned.path) }) {
            model.shortcuts.remove(shortcut)
        }

        workspaceOpenPaths = [IndexScope.folderPath(success), IndexScope.folderPath(failure)]
        defer { workspaceOpenPaths.removeAll() }
        let failed = try await select("frecency unhandled document", failure)
        try key(kVK_Return, "\r", in: app)
        try await until("NSWorkspace did not report the unhandled document's failed file open") {
            model.searchNotice?.problem == .opening
        }
        try check(app.searchPresented && boost(failed) == 0, "a validated but failed workspace open counted as a file open")

        let openedHit = try await select("frecency open probe.app", success)
        try check(boost(openedHit) == 0, "searching for a file counted as opening it")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("app-started"))
        try key(kVK_Return, "\r", in: app)
        try await until("Return did not launch the file result through NSWorkspace") {
            !app.searchPresented && self.exists("app-started")
        }
        let reloaded = LauncherFrecency(defaults: defaults)
        try check(boost(openedHit) > 0 && reloaded.rankFiles([failed, openedHit]).first == openedHit,
                  "a successful workspace open did not persist and affect file ranking")
    }

    private func verifyEngineRegressions() async throws {
        for (raw, expected) in [
            (#"/Projects path:"/Archive Reports/" /Projects report"#, #"/Projects "/Archive Reports/" /Projects report"#),
            ("KIND:Directory kind:folder KIND:Doc report", "kind:folder kind:folder kind:doc report"),
            ("EXT:.TXT ext:txt EXT:.PDF report", "ext:txt ext:txt ext:pdf report"),
        ] {
            let query = LauncherFileQuery(raw)
            try check(query.isFiltered && query.engineQuery == expected,
                      "repeated qualifiers were not preserved in the engine query: \(query.engineQuery)")
        }
        let root = directory.appendingPathComponent("engine-regressions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("engine")
        let source = #"""
        #!/usr/bin/python3
        import json, os, shlex, signal, sys, time
        from pathlib import Path
        root = Path(__file__).parent
        db, command, *args = sys.argv[2:]
        def mark(name):
            (root / name).touch()
        def stamp(path):
            stat = path.stat()
            return ':'.join(map(str, (stat.st_dev % 2**64, stat.st_ino, stat.st_size,
                                     *divmod(stat.st_mtime_ns, 10**9), *divmod(stat.st_ctime_ns, 10**9))))
        def hold(name):
            def stopped(*_):
                mark(name + '-terminated')
                sys.exit(0)
            signal.signal(signal.SIGTERM, stopped)
            mark(name + '-started')
            signal.pause()
        if command == 'status':
            if Path(db).name == 'unreadable':
                mark('status-started')
                limit = time.monotonic() + 10
                while not (root / 'release-status').exists() and time.monotonic() < limit:
                    time.sleep(.01)
                sys.exit('fixture index could not be opened')
            print('{"items":1}')
        elif command == 'watch':
            if '--help' in args:
                print('--cached-start --progress')
            else:
                mark(Path(db).name + '-watch-started')
                print('{"event":"cached"}', flush=True)
                while not (root / 'release-cached').exists():
                    time.sleep(.01)
                print('{"event":"ready"}', flush=True)
                signal.pause()
        elif command == 'serve':
            long_validation = []
            frame_count = 0
            for line in sys.stdin.buffer:
                assert len(line) <= 12 * 1024, len(line)
                request = json.loads(line)
                if Path(db).name == 'legacy':
                    reply = dict(id=request['id'], hits=[])
                    if request.get('op') == 'validate':
                        reply = dict(id=request['id'], error='missing field `query`')
                    elif request['query'] == 'legacy probe' and request['mode'] == 'text':
                        paths = [root.resolve() / name for name in ('legacy.txt', 'legacy.PNG')]
                        reply['hits'] = [dict(path=str(path), name=path.name, kind='file', availability='local',
                                              matched_by='text', snippet='legacy probe', document_stamp=stamp(path))
                                         for path in paths]
                    print(json.dumps(reply), flush=True)
                    continue
                if request.get('op') == 'validate':
                    assert set(request) == {'id', 'op', 'hits'}
                    hits = request['hits']
                    names = [Path(hit['path']).stem for hit in hits]
                    assert all(hit['document_stamp'] == 'fixture' for hit in hits)
                    if [hit['path'] for hit in hits] == ['/scope with spaces/keep.txt']:
                        print(json.dumps(dict(id=request['id'], valid=[True])), flush=True)
                        continue
                    if names[0].startswith('long-'):
                        indices = [int(name.removeprefix('long-')) for name in names]
                        long_validation.extend(indices)
                        frame_count += 1
                        print(json.dumps(dict(id=request['id'], valid=[i % 3 != 1 for i in indices])), flush=True)
                        continue
                    if names[0].startswith('hold-'):
                        hold(names[0])
                    assert names == ['keep', 'drop'], names
                    mark('one-image-batch')
                    print(json.dumps(dict(id=request['id'], valid=[True, False])), flush=True)
                    continue
                query = request['query']
                assert request['check_access'] == (query == 'cached probe'), request
                assert request['check_access'] == ('--check-access' in args), args
                if query == 'validation tail':
                    assert frame_count > 1 and long_validation == list(range(26)), (frame_count, long_validation)
                    mark('validated-all-on-one-connection')
                if 'limit-probe' in query:
                    tokens = shlex.split(query)
                    mode, limit = request['mode'], request['limit']
                    assert limit == {'name': 60, 'text': 24}[mode]
                    assert tokens in (['limit-probe'], ['kind:folder', 'limit-probe'],
                                      ['/scope with spaces/', 'kind:doc', 'ext:txt', 'limit-probe']), tokens
                    def hit(path, kind='file'):
                        return dict(path=path, name=Path(path).name, kind=kind, availability='local',
                                    matched_by=mode, **(dict(snippet='limit-probe', document_stamp='fixture')
                                                        if mode == 'text' else {}))
                    if mode == 'name':
                        hits = [hit(f'/other/limit-probe-{i}.txt') for i in range(61)]
                        hits += [hit('/other/limit-probe-folder', 'directory')]
                    else:
                        hits = [hit(f'/other/global-{i}.txt') for i in range(25)]
                        hits += [hit('/scope with spaces/keep.md'), hit('/scope with spaces/keep.txt')]
                    # Mirror the M2 wire contract; apply all constraints before slicing the fixture ranking.
                    if 'kind:folder' in tokens:
                        hits = [h for h in hits if h['kind'] == 'directory']
                    if 'kind:doc' in tokens:
                        hits = [h for h in hits if h['path'].endswith(('.txt', '.md'))]
                    if 'ext:txt' in tokens:
                        hits = [h for h in hits if h['path'].endswith('.txt')]
                    if '/scope with spaces/' in tokens:
                        hits = [h for h in hits if h['path'].startswith('/scope with spaces/')]
                        mark('scoped-' + mode)
                    print(json.dumps(dict(id=request['id'], hits=hits[:limit])), flush=True)
                    continue
                if query == 'cached probe':
                    mark('checked-cached-' + request['mode'])
                if query == 'stall':
                    mark(f'stalled-pid-{os.getpid()}')
                    hold('stalled-request')
                if query == 'superseded':
                    mark('unexpected-superseded-request')
                if query == 'recover' and not (root / f'stalled-pid-{os.getpid()}').exists():
                    mark('fresh-worker-recovered')
                reply = {'id': request['id']}
                if query in ('x', 'no text matches') and request['mode'] == 'name':
                    reply['error'] = 'fixture name search failed'
                else:
                    reply['hits'] = []
                print(json.dumps(reply), flush=True)
        elif command == 'image-serve':
            for line in sys.stdin:
                request = json.loads(line)
                names = ['keep.jpg', 'drop.jpg'] if request['query'] == 'accept' else [request['query'] + '.jpg']
                hits = [dict(path=str(root / name), name=name, kind='file', availability='local',
                             matched_by='image_embedding', document_stamp='fixture') for name in names]
                print(json.dumps(dict(id=request['id'], hits=hits)), flush=True)
        elif command == 'validate-hit' and Path(db).name == 'legacy':
            path = Path(args[-1])
            expected = ['--kind', 'file', '--availability', 'local', '--document-stamp', stamp(path)]
            if '--matched-by' in args:
                assert args == expected + ['--matched-by', 'text', '--', str(path)], args
                mark(path.name + '-typed-rejected')
                sys.exit(2)
            assert args == expected + ['--', str(path)], args
            # Untyped validation accepts either current stamp, even for the OCR hit.
            print('{"valid":true}')
        elif command in ('query', 'validate-hit'):
            mark('unexpected-standalone-query')
            sys.exit(1)
        elif command == 'pipes':
            os.write(2, b'e' * 131072 + b'error tail')
            os.write(1, b'o' * 131072 + b'output tail')
        elif command == 'hold-pipes':
            print('ready', flush=True)
            print('{"event":"progress","phase":"held","entries":1,"elapsed_ms":0}', file=sys.stderr, flush=True)
            hold('held-pipe')
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        func testEngine(_ name: String) throws -> LauncherEngine {
            let db = root.appendingPathComponent(name)
            try Data().write(to: db)
            return LauncherEngine(executable: executable, database: db, requestTimeout: .milliseconds(500))
        }
        func marked(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }

        let bad = Launcher(engine: try testEngine("unreadable"), defaults: nil)
        defer { bad.close() }
        bad.start()
        try await until("the failed status and watch capability probes did not start") {
            marked("status-started") && bad.watchState != .checking
        }
        try check(bad.watchState == .needsSetup && !marked("unreadable-watch-started"),
                  "a watcher started before the saved index status was known")
        try Data().write(to: root.appendingPathComponent("release-status"))
        try await until("status failure did not leave the index unreadable") { bad.indexPhase == .unreadable }
        try check(bad.indexNotice?.problem == .status && !marked("unreadable-watch-started"),
                  "a failed startup status still let watch trust the index")

        let engine = try testEngine("readable")
        let model = Launcher(engine: engine, defaults: nil)
        defer { model.close() }
        model.start()
        try await until("the cached snapshot did not become searchable") {
            model.canSearch && model.watchState == .starting
        }
        model.setQuery("cached probe")
        try await until("cached searches did not pass access checks for both modes") {
            marked("checked-cached-name") && marked("checked-cached-text") && !model.searching
        }
        model.clear()
        try Data().write(to: root.appendingPathComponent("release-cached"))
        try await until("valid startup did not reach a searchable watcher") { model.canSearch && model.watchState == .running }
        for query in ["x", "no text matches"] {
            model.setQuery(query)
            try await until("name failure did not finish") { !model.searching }
            try check(model.hits.isEmpty && model.searchNotice?.detail == "fixture name search failed",
                      "a name-search error was hidden by an empty text branch")
        }

        // This branch still bundles the M1 engine. Exercise the Swift launcher against a
        // fixture serving the M2 query contract, with the matching rows ranked below each cap.
        for (mode, limit, wanted) in [("name", 60, "/other/limit-probe-folder"), ("text", 24, "/scope with spaces/keep.txt")] {
            var baseline: Result<[SearchHit], SearchFailure>?
            engine.search("limit-probe", mode: mode) { baseline = $0 }
            try await until("the unfiltered \(mode) request did not finish") { baseline != nil }
            let hits = try baseline?.get()
            try check(hits?.count == limit && hits?.contains { $0.path == wanted } == false,
                      "the fixture did not hide the matching \(mode) row behind the unfiltered limit")
        }
        model.setQuery("KIND:Directory limit-probe")
        try await until("the folder behind 60 file names was not returned") {
            !model.searching && model.hits.map(\.path) == ["/other/limit-probe-folder"]
        }
        model.setQuery("kind:doc EXT:.TXT path:\"/scope with spaces/\" limit-probe")
        try await until("the in-scope text result behind 24 global hits was not returned") {
            !model.searching && marked("scoped-name") && marked("scoped-text") &&
                model.hits.map(\.path) == ["/scope with spaces/keep.txt"] && model.hits.first?.hasPreview == true
        }
        model.clear()

        let longComponent = String(repeating: "界\\\"z", count: 38)
        let longPrefix = String(repeating: "/" + longComponent, count: 4)
        let longHits = (0..<26).map { i in
            SearchHit(path: longPrefix + "/long-\(i).txt", name: "long-\(i).txt", kind: "file", availability: "local",
                      matched_by: "text", snippet: "fixture", document_stamp: "fixture", pdf_page: nil)
        }
        var validation: Result<[Bool]?, SearchFailure>?
        engine.validate(longHits) { validation = $0 }
        try await until("the long-path validation did not finish") { validation != nil }
        try check(try validation?.get() == (0..<26).map { $0 % 3 != 1 },
                  "chunked validation lost or reordered flags")
        var tail: Result<[SearchHit], SearchFailure>?
        engine.search("validation tail", mode: "name") { tail = $0 }
        try await until("the same validation connection did not survive for a follow-up query") { tail != nil }
        try check(try tail?.get() == [] && marked("validated-all-on-one-connection"),
                  "validation did not split into bounded frames on one persistent server")

        var stalled: [Result<[SearchHit], SearchFailure>] = []
        engine.search("stall", mode: "name") { stalled.append($0) }
        try await until("the active search did not stall inside serve") { marked("stalled-request-started") }
        try check(stalled.isEmpty && engine.nameSearchBusy, "search was not active when its successor was queued")
        var superseded = false
        engine.search("superseded", mode: "name") { _ in superseded = true }
        var successor: [Result<[SearchHit], SearchFailure>] = []
        engine.search("recover", mode: "name") { successor.append($0) }
        try await until("the stall did not settle both the active search and its queued successor") {
            !stalled.isEmpty && !successor.isEmpty
        }
        guard stalled.count == 1, case .failure(let failure) = stalled[0], failure.detail.contains("timed out") else {
            throw Failure("the actual stalled search did not get its timeout")
        }
        try await until("serve did not terminate the stalled worker") { marked("stalled-request-terminated") }
        try check(successor.count == 1 && (try? successor[0].get()) == [] && marked("fresh-worker-recovered") &&
                  !superseded && !marked("unexpected-superseded-request"),
                  "timeout did not dispatch only the latest queued search on a fresh worker")
        var pipes: EngineResponse?
        _ = engine.run(["pipes"]) { pipes = $0 }
        try await until("large stdout and stderr pipes did not both drain") { pipes != nil }
        try check(pipes?.output.count == 131083 && pipes?.errors.count == 65_536 &&
                  pipes?.diagnostic.hasSuffix("error tail") == true, "pipe draining lost output or stderr tail")

        let projector = root.appendingPathComponent("projector")
        model.setImageQuery("hold-query", projector: projector)
        try await until("image hit validation did not start") { marked("hold-query-started") }
        model.setImageQuery("accept", projector: projector)
        try await until("timed-out image batch did not terminate or replacement hits were wrong") {
            marked("hold-query-terminated") && marked("one-image-batch") && !model.searching && model.hits.map(\.name) == ["keep.jpg"]
        }
        try check(!marked("unexpected-standalone-query"), "search or batch validation spawned a standalone CLI")
        model.setImageQuery("hold-close", projector: projector)
        try await until("image hit validation did not restart") { marked("hold-close-started") }
        model.close()
        try await until("closing the launcher leaked image hit validation") { marked("hold-close-terminated") }

        let legacy = Launcher(engine: try testEngine("legacy"), defaults: nil)
        defer { legacy.close() }
        let legacyRoot = URL(fileURLWithPath: IndexScope.folderPath(root), isDirectory: true)
        let textFile = legacyRoot.appendingPathComponent("legacy.txt")
        let imageFile = legacyRoot.appendingPathComponent("legacy.PNG")
        for file in [textFile, imageFile] { try Data("legacy probe".utf8).write(to: file) }
        legacy.start()
        try await until("the legacy engine did not become searchable") { legacy.canSearch && legacy.watchState == .running }
        legacy.setQuery("legacy probe")
        try await until("the legacy engine did not publish both stamped text and OCR hits") {
            !legacy.searching && Set(legacy.hits.map(\.path)) == Set([textFile.path, imageFile.path])
        }
        guard let textHit = legacy.hits.first(where: { $0.path == textFile.path }),
              let imageHit = legacy.hits.first(where: { $0.path == imageFile.path }) else {
            throw Failure("missing legacy validation fixtures")
        }
        var resolved: URL?
        legacy.resolve(textHit, action: .open) { resolved = $0 }
        try await until("legacy text validation did not finish") { resolved != nil || legacy.searchNotice?.problem == .stale }
        try check(resolved == textFile, "legacy validate-hit rejected an unchanged stamped .txt hit")

        resolved = nil
        legacy.resolve(imageHit, action: .open) { resolved = $0 }
        try await until("legacy image validation did not finish") { resolved != nil || legacy.searchNotice?.problem == .stale }
        try check(marked("legacy.PNG-typed-rejected") && resolved == nil && !legacy.hits.contains(imageHit),
                  "a stamped OCR image did not fail safely when legacy validate-hit rejected --matched-by")
        legacy.close()

        // libdispatch reads this setting at process startup. One cooperative worker is
        // enough to expose starvation without racing to saturate a machine-sized pool.
        let probe = root.appendingPathComponent("cooperative", isDirectory: true)
        try FileManager.default.createDirectory(at: probe.appendingPathComponent("corpus"), withIntermediateDirectories: true)
        try Data().write(to: probe.appendingPathComponent("cooperative-pipe-scenario"))
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--gui-smoke", probe.path, "en"]
        child.environment = ProcessInfo.processInfo.environment.merging(["LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1"]) { _, strict in strict }
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        try await until("the strict cooperative-pool smoke process did not finish", seconds: 15) { !child.isRunning }
        try check(child.terminationStatus == 0, "long-lived pipes starved the strict cooperative pool")
    }

    private func verifyCooperativePipeProgress() async throws {
        let engine = LauncherEngine(executable: directory.deletingLastPathComponent().appendingPathComponent("engine"), database: database)
        var stdoutReady = false, stderrReady = false, completed = false
        guard let child = engine.run(["hold-pipes"], onLine: { stdoutReady = String(decoding: $0, as: UTF8.self) == "ready" },
                                     onProgress: { stderrReady = $0.phase == "held" },
                                     complete: { _ in completed = true }) else { throw Failure("could not start pipe fixture") }
        defer { if child.isRunning { child.terminate() } }
        try await until("both long-lived pipe readers did not start") { stdoutReady && stderrReady }
        var progressed = false
        let task = Task.detached(priority: .utility) { await MainActor.run { progressed = true } }
        defer { task.cancel() }
        try await until("a detached task could not progress while both engine pipes were open") { progressed }
        try check(child.isRunning && !completed, "the cooperative task only progressed after a pipe closed")
        child.terminate()
        try await until("the held pipe fixture did not finish after termination") { completed }
    }

    private func verifyUnconfiguredQA(_ app: AppDelegate) throws {
        app.showSearch()
        try type("qa 还没有配置", into: app)
        try key(kVK_Return, "\r", in: app)
        try check(app.commands.answer == .idle && !exists("translation-request-started"),
                  "unconfigured QA sent a request")
        if exists("capture-icons") {
            try capture("lumen-qa-unconfigured.png", appearance: .aqua, window: app.panel)
            app.panel.appearance = nil
        }
        app.dismissSearch()
    }

    private func verifyLauncherCommands(_ app: AppDelegate) async throws {
        let commands = app.commands
        let panel = app.panel
        app.showSearch()
        try type("?", into: app)
        try check(commands.resolution == .discovery && commands.selectedEntry?.keyword == "qa", "missing command chooser")
        if exists("capture-icons") {
            try capture("lumen-command-chooser.png", appearance: .aqua, window: panel)
            panel.appearance = nil
        }
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try check(commands.selectedEntry?.keyword == "tr", "arrows did not move in the chooser")
        try key(kVK_UpArrow, "\u{f700}", in: app)
        try key(kVK_Return, "\r", in: app)
        try check(commands.resolution == .missingArgument(commandID: "qa"), "chooser submitted rather than filling")
        let browserCount = dispatchedQuicklinks.count
        try type("g 武汉 C++ &next=https://example.invalid/#猫", into: app)
        try check(dispatchedQuicklinks.count == browserCount, "typing opened a browser")
        try key(kVK_Return, "\r", in: app)
        let destination = dispatchedQuicklinks.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        try check(dispatchedQuicklinks.count == browserCount + 1 && destination?.host == "www.google.com" &&
                  destination?.queryItems == [URLQueryItem(name: "q", value: "武汉 C++ &next=https://example.invalid/#猫")],
                  "Google command split or changed the argument")
        let shortcut = SavedShortcut(id: UUID(), title: "Synthetic Docs", alias: "docs",
                                     target: .web(URL(string: "https://example.invalid/search")!),
                                     pinned: false, lastOpened: nil, queryParameter: "keywords")
        try check(app.model.shortcuts.save(shortcut), "could not save parameterized shortcut")
        app.showSearch()
        try type("docs 样本 & test", into: app)
        try check(dispatchedQuicklinks.count == browserCount + 1, "shortcut opened while typing")
        try key(kVK_Return, "\r", in: app)
        let custom = dispatchedQuicklinks.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        try check(dispatchedQuicklinks.count == browserCount + 2 && custom?.host == "example.invalid" &&
                  custom?.queryItems == [URLQueryItem(name: "keywords", value: "样本 & test")], "custom command encoded incorrectly")
        app.model.shortcuts.remove(shortcut)
        dispatchedQuicklinks.removeLast(2)

        app.showSearch()
        let input = try editor(app)
        let question = "qa 長い回答"
        try type(question, into: app)
        input.setMarkedText("kota", selectedRange: NSRange(location: 4, length: 0),
                            replacementRange: NSRange(location: question.utf16.count - 1, length: 1))
        try check(!app.control(app.searchField, textView: input, doCommandBy: #selector(NSResponder.insertNewline(_:))) &&
                  !exists("qa-request"), "the marked question was sent")
        input.insertText("答", replacementRange: input.markedRange())
        input.unmarkText()
        try check(input.string == question && !exists("qa-request"), "committing input contacted the QA provider")
        try key(kVK_Return, "\r", in: app)
        try await until("QA did not return a Japanese and Chinese answer") {
            if case .answer(let output) = commands.answer { return output.contains("回答") && output.count > 400 }
            return false
        }
        if exists("capture-icons") {
            try capture("lumen-qa-answer.png", appearance: .aqua, window: panel)
            try capture("lumen-qa-answer-dark.png", appearance: .darkAqua, window: panel)
            panel.appearance = nil
        }
        try key(kVK_PageDown, "\u{f72d}", in: app, throughPanel: true)
        try await until("Page Down did not scroll the actual answer") {
            (answerScroll(in: panel.contentView)?.contentView.bounds.minY ?? 0) > 0
        }
        try check(panel.firstResponder === input, "Page Down changed search focus")
        try key(kVK_PageUp, "\u{f72c}", in: app, throughPanel: true)
        try await until("Page Up did not return to the answer start") {
            answerScroll(in: panel.contentView)?.contentView.bounds.minY == 0
        }
        try key(kVK_Return, "\r", in: app)
        try check(commands.copied && filePasteboard.string(forType: .string)?.contains("回答") == true &&
                  panel.firstResponder === input && app.searchPresented, "second Return did not copy in place")
        try verifyInternalCopy(app, "Copy QA Answer")

        try type("qa synthetic error", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("QA provider error was not shown") { commands.answer == .failed }
        if exists("capture-icons") {
            try capture("lumen-qa-error.png", appearance: .aqua, window: panel)
            panel.appearance = nil
        }
        try type("qa synthetic slow", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("QA did not reach loading") { commands.answer == .loading && self.exists("qa-slow") }
        if exists("capture-icons") {
            try capture("lumen-qa-loading.png", appearance: .aqua, window: panel)
            panel.appearance = nil
        }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(commands.answer == .idle && app.searchPresented, "Esc did not cancel QA in place")
        try type("qa newer question", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("new QA answer was not delivered") { commands.answer == .answer("Current answer") }
        try await until("old QA reply was not exercised") { self.exists("qa-late") }
        try check(commands.answer == .answer("Current answer") && panel.firstResponder === input,
                  "late QA answer or rendering changed the current result or focus")
        try type("lumen action probe", into: app)
        try check(commands.resolution == .search && commands.answer == .idle, "ordinary search did not recover")
    }

    private func answerScroll(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == "qa-answer-scroll" { return view as? NSScrollView }
        return view.subviews.lazy.compactMap { self.answerScroll(in: $0) }.first
    }

    private func verifyStreaming(_ app: AppDelegate) async throws {
        let translation = app.translation
        let commands = app.commands
        let base = try String(contentsOf: directory.appendingPathComponent("translation-endpoint"), encoding: .utf8)
        translation.editDraft(\.endpoint, value: base + "/stream/v1")
        translation.editDraft(\.model, value: "fixture-chat")
        translation.saveProvider()
        let field = try editor(app)
        let pasteboardText = "unchanged during streaming"
        filePasteboard.setString(pasteboardText, forType: .string)

        for verb in ["tr", "qa"] {
            let isTranslation = verb == "tr"
            func working() -> Bool { isTranslation ? translation.activity == .translating : commands.answer == .loading }
            func output() -> String { isTranslation ? translation.output : commands.answerText }
            for mode in ["finish", "bom", "cancel", "edit", "json", "mislabeled"] {
                let id = "\(verb)-\(mode)"
                try type("\(verb) \(mode)", into: app)
                try key(kVK_Return, "\r", in: app)
                if mode == "json" || mode == "mislabeled" {
                    try await until("\(id) did not decode JSON fallback") { !working() && output() == "JSON fallback" }
                    continue
                }
                try await until("\(id) did not deliver the first chunk before completion") {
                    guard working(), output() == "第一段 🦌" else { return false }
                    if isTranslation { return true }
                    let display = self.answerScroll(in: app.panel.contentView)?.documentView as? NSTextView
                    return display?.string == output()
                }
                try key(kVK_Return, "\r", in: app)
                try check(working() && filePasteboard.string(forType: .string) == pasteboardText,
                          "Return copied a partial result or submitted again")
                switch mode {
                case "finish", "bom":
                    try signal("release-\(id)")
                    try await until("\(id) did not finish with the assembled result") {
                        !working() && output() == "第一段 🦌 / second chunk"
                    }
                    try signal("finished-\(id)")
                case "cancel":
                    try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
                    try check(!working() && output().isEmpty && app.searchPresented && field.string == "\(verb) cancel",
                              "Escape did not clear the partial \(verb) result in place")
                    try await until("Escape left the \(verb) HTTP connection open", seconds: 2) { self.exists("closed-\(id)") }
                default:
                    try type("\(verb) edited query", into: app)
                    try check(!working() && output().isEmpty && field.string == "\(verb) edited query",
                              "editing did not clear the partial \(verb) result")
                    try await until("editing left the \(verb) HTTP connection open", seconds: 2) { self.exists("closed-\(id)") }
                }
                try check(app.panel.firstResponder === field, "streaming moved focus away from search")
            }
        }
        print("Streaming passed: tr/qa incremental SSE with and without a BOM, finish_reason/[DONE], Escape/edit socket cancellation, and JSON fallback")
    }

    private func verifyInlineTranslation(_ app: AppDelegate) async throws {
        let mdl = app.translation
        let originalPanel = app.panel
        let backdrop = originalPanel.contentView
        try check(TranslationClient.sessionConfiguration(timeout: 3).connectionProxyDictionary == nil,
                  "translation session replaced the system proxy configuration")
        guard let local = mdl.provider, local.name == "oMLX", local.endpoint == "http://127.0.0.1:8000/v1",
              mdl.activity == nil else { throw Failure("missing saved oMLX preset") }

        app.showSearch()
        for term in ["tree", "translate.pdf", "translate notes.pdf", "trailer", "翻译稿"] {
            try type(term, into: app)
            try check(mdl.command == nil && app.model.query == term, "a normal file search was treated as translation")
        }
        try type("翻译", into: app)
        try check(mdl.command?.text == "" && app.panel === originalPanel && app.panel.contentView === backdrop,
                  "translation guidance moved out of the original launcher")
        try key(kVK_Return, "\r", in: app)
        try check(app.searchPresented && mdl.activity == nil, "translation guidance submitted without source text")

        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        try key(kVK_ANSI_Comma, ",", in: app, throughPanel: true, flags: [.command])
        guard let settings = app.settings else { throw Failure("missing shared Settings window") }
        try check(app.settingsSession.page == .translation && !app.searchPresented &&
                  Set(NSApp.windows.map(ObjectIdentifier.init)).subtracting(windows) == [ObjectIdentifier(settings)],
                  "translation configuration did not open the shared window")
        let endpoint = try String(contentsOf: directory.appendingPathComponent("translation-endpoint"), encoding: .utf8)
        mdl.newProvider()
        mdl.editDraft(\.name, value: "Synthetic Translation Provider")
        mdl.editDraft(\.endpoint, value: endpoint + "/translated/v1")
        mdl.editDraft(\.model, value: "sandbox-model")
        mdl.keyInput = "synthetic-smoke-key"
        mdl.saveProvider()
        guard let saved = mdl.provider else { throw Failure("translation provider was not saved") }
        let restored = makeTranslationModel()
        try check(mdl.status == .saved && mdl.keyInput.isEmpty && restored.provider == saved &&
                  restored.providers.contains(local), "existing provider or draft state was changed")
        let savedEndpoint = try TranslationEndpoint(saved.endpoint)
        try check(translationSecrets.key(provider: saved.id, endpoint: savedEndpoint) == "synthetic-smoke-key",
                  "saving changed the endpoint-bound credential")
        try check(!exists("translation-request-started"), "configuring translation made a request")
        app.showSearch()
        try key(kVK_ANSI_Comma, ",", in: app, throughPanel: true, flags: [.command])
        try check(app.settings === settings, "ordinary Settings opened another window")
        app.showSearch()

        let aliasCases: [(String, TranslationLanguage, String)] = [
            ("译 今天下午三点开会", .english, "今天下午三点开会"),
            ("翻译 今天下午三点开会", .english, "今天下午三点开会"),
            ("translate it is fine", .simplifiedChinese, "it is fine"),
            ("tr see you tomorrow", .simplifiedChinese, "see you tomorrow"),
            ("tr it is fine", .simplifiedChinese, "it is fine"),
            ("tr made up language", .simplifiedChinese, "made up language"),
            ("tr 法 谢谢", .french, "谢谢"), ("tr 法语 谢谢", .french, "谢谢"),
            ("tr French 谢谢", .french, "谢谢"), ("tr法 谢谢", .french, "谢谢"),
            ("tr de 你好", .german, "你好"), ("tr German 你好", .german, "你好"),
            ("tr ja 早上好", .japanese, "早上好"), ("译日 谢谢", .japanese, "谢谢"),
            ("tr Russian 谢谢", .russian, "谢谢"), ("tr 韩语 谢谢", .korean, "谢谢"),
            ("tr es 谢谢", .spanish, "谢谢"), ("tr pt 谢谢", .portuguese, "谢谢"),
            ("tr 意大利语 谢谢", .italian, "谢谢"), ("tr:it 你好", .italian, "你好"),
            ("tr en 谢谢", .english, "谢谢"), ("tr 中文 Hello", .simplifiedChinese, "Hello"),
            ("tr zh-hant Hello", .traditionalChinese, "Hello"),
        ]
        let field = try editor(app)
        for (raw, target, sourceText) in aliasCases {
            try type(raw, into: app)
            try check(mdl.command?.target == target && mdl.command?.text == sourceText &&
                      mdl.command?.raw == field.string && app.model.query.isEmpty &&
                      app.panel.firstResponder === field && mdl.activity == nil,
                      "translation alias changed the source, target, or native responder: \(raw)")
        }
        try type("tr:unknown keep me", into: app)
        try key(kVK_Return, "\r", in: app)
        try check(mdl.command?.unsupportedLanguage == "unknown" && mdl.command?.text == "keep me" &&
                  !exists("translation-request-started"), "unknown explicit target submitted or lost source")

        try type("译 今天下午三点开会", into: app)
        let originalText = field.string
        field.setMarkedText("hui", selectedRange: NSRange(location: 3, length: 0),
                            replacementRange: NSRange(location: originalText.utf16.count - 1, length: 1))
        try check(field.hasMarkedText() &&
                  !app.control(app.searchField, textView: field, doCommandBy: #selector(NSResponder.insertNewline(_:))) &&
                  !exists("translation-request-started"), "Return submitted marked text")
        field.insertText("会", replacementRange: field.markedRange())
        field.unmarkText()
        try check(!field.hasMarkedText() && field.string == originalText, "IME did not restore the committed Chinese input")
        let originalFrame = app.panel.frame
        filePasteboard.clearContents()
        filePasteboard.setString("unchanged clipboard", forType: .string)
        try key(kVK_Return, "\r", in: app)
        try await until("Chinese input was not translated in the search result") {
            mdl.output == "Meeting at three this afternoon." && mdl.activity == nil
        }
        try check(filePasteboard.string(forType: .string) == "unchanged clipboard" &&
                  field.string == originalText && originalPanel.contentView === backdrop &&
                  app.panel.frame == originalFrame && app.panel.firstResponder === field,
                  "first Return copied, changed the search text, or disturbed its window")
        if exists("capture-icons") {
            try capture("lumen-translation-light.png", appearance: .aqua, window: originalPanel)
            try capture("lumen-translation-dark.png", appearance: .darkAqua, window: originalPanel)
            originalPanel.appearance = nil
        }
        try key(kVK_Return, "\r", in: app)
        try check(mdl.copied && filePasteboard.string(forType: .string) == mdl.output &&
                  field.string == originalText && app.searchPresented, "second Return did not copy in place")
        try verifyInternalCopy(app, "Copy Translation")

        try type("tr it is fine", into: app)
        try check(mdl.output.isEmpty && !mdl.copied, "edited text kept the old result or copy affordance")
        try key(kVK_Return, "\r", in: app)
        try await until("English input lost its leading it or default direction") {
            mdl.output == "没问题。" && mdl.activity == nil
        }

        try type("tr:it 你好", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("explicit Italian did not use the selected provider") { mdl.output == "Ciao!" }
        if exists("capture-icons") {
            try capture("lumen-translation-italian.png", appearance: .aqua, window: originalPanel)
            originalPanel.appearance = nil
        }

        try type("译 模拟错误", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("provider errors were lost or left an old result actionable") {
            mdl.status == .failure(.http(401)) && mdl.output.isEmpty && mdl.activity == nil
        }

        try type("译 取消翻译", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("slow request did not start") { mdl.activity == .translating && self.exists("slow-escape-started") }
        if exists("capture-icons") {
            try capture("lumen-translation-running.png", appearance: .aqua, window: originalPanel)
            originalPanel.appearance = nil
        }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(mdl.activity == nil && mdl.status == .canceled && app.searchPresented &&
                  field.string == "译 取消翻译", "Escape did not cancel in place")
        try await until("fixture did not attempt the canceled reply") { self.exists("slow-escape-replied") }
        try check(mdl.output.isEmpty, "the canceled reply appeared")

        try type("译 改字前", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("the request to supersede did not start") { self.exists("slow-edit-started") }
        try type("tr see you tomorrow", into: app)
        try check(mdl.activity == nil && mdl.output.isEmpty, "editing did not cancel the old work")
        try key(kVK_Return, "\r", in: app)
        try await until("new query did not translate") { mdl.output == "明天见。" && mdl.activity == nil }
        try await until("fixture did not attempt the superseded reply") { self.exists("slow-edit-replied") }
        try check(mdl.output == "明天见。" && app.panel.firstResponder === field, "late reply replaced the new query")

        try type("lumen action probe", into: app)
        try await until("normal search did not recover from translation") {
            app.model.selectedResult?.id != nil && mdl.command == nil && app.panel.firstResponder === field
        }
        try check(!NSApp.isActive && !app.panel.isVisible, "translation smoke activated a real window")
        print("Search-field translation passed: aliases, IME, Return to submit and copy, edit/Escape cancellation, Settings, and late replies")
    }

    private func verifyProviderDeletion(_ model: TranslationPanelModel) throws {
        guard let saved = model.provider, let local = model.providers.first(where: { $0 != saved }) else {
            throw Failure("no saved translation provider to delete")
        }
        let endpoint = try TranslationEndpoint(saved.endpoint)
        try check(model.canRemoveProvider, "saved provider was not removable")
        model.removeProvider()
        let afterDeletion = makeTranslationModel()
        try check(model.status == .removedProvider && model.provider == local && afterDeletion.providers == [local] &&
                  afterDeletion.provider == local && translationSecrets.key(provider: saved.id, endpoint: endpoint) == nil,
                  "provider deletion did not remove its credential, persist, or select a remaining provider")
        model.removeProvider()
        try check(model.provider == nil && makeTranslationModel().providers.isEmpty,
                  "deleting the last provider silently restored a preset")
    }

    private func verifyQuicklinks(_ app: AppDelegate) async throws {
        let model = app.model
        func actionName() -> String? {
            if case .action(let action)? = model.selectedResult { return action.english }
            return nil
        }
        try type("wx", into: app)
        try await until("exact app title beat the short pinyin initialism") {
            actionName() == "WX" && model.launchMatches.contains { $0.action.chinese == "微信" }
        }
        try type("weixin", into: app)
        try await until("full pinyin reached WeChat") { actionName() == "WeChat Fixture" }
        try type("lanya", into: app)
        try await until("full pinyin reached Bluetooth") { actionName() == "Bluetooth" }
        try type("ly", into: app)
        try await until("pinyin initials reached Bluetooth") { actionName() == "Bluetooth" }

        try type("lap", into: app)
        try await until("the app was ready to pin") { actionName() == "Lumen Action Probe" }
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.map(\.id) == ["open", "pin-app"],
                  "Command–K did not expose the selected app's actions")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_Return, "\r", in: app)
        try type("", into: app)
        try await until("manually pinned app appeared in empty search") { model.visibleResults.count == 1 }
        guard case .shortcut(let pinned)? = model.selectedResult else { throw Failure("pin was not selectable") }
        try check(pinned.pinned && pinned.title == "Lumen Action Probe", "unexpected empty-search pin")

        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.contextActions.isOpen && app.searchPresented, "Escape dismissed search instead of closing its action list")
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.map(\.id) == ["open", "toggle-pin"],
                  "actions for a pinned shortcut offered unrelated configuration")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try key(kVK_ANSI_Comma, ",", in: app, throughPanel: true, flags: [.command])
        guard let settings = app.settings else { throw Failure("Settings did not open") }
        app.settingsSession.page = .quicklinks
        let reopenedLibrary = ShortcutLibrary(defaults: shortcutFixturePreferences)
        try check(app.settings === settings && reopenedLibrary.entries.contains(pinned) &&
                  model.shortcuts.entries == reopenedLibrary.entries && !settings.isVisible,
                  "Quicklinks settings did not reuse the Settings window and library")
        try check(!SettingsPage.allCases.contains(where: { $0.rawValue == "extensions" }) &&
                  Bundle.main.url(forResource: "lumen-extensions", withExtension: nil) == nil,
                  "the app still exposed or bundled the retired Extensions feature")

        let builtIns = [("gh", "github", "github.com", "q", "搜索 GitHub"),
                        ("wiki", "wikipedia", "zh.wikipedia.org", "search", "搜索维基百科"),
                        ("map", "maps", "www.google.com", "query", "搜索 Google 地图")]
        let chineseCard = LauncherCommandCard(commands: app.commands, provider: app.translation, chinese: true,
                                              activate: {}, openSettings: {})
        let url = URL(string: "https://example.invalid/work")!
        func internalLink(_ alias: String) -> SavedShortcut {
            SavedShortcut(id: UUID(), title: "Internal Search", alias: alias, target: .web(url), pinned: false,
                          queryParameter: "term")
        }
        app.showSearch()
        for (alias, _, _, _, _) in builtIns {
            try type("\(alias) 示例", into: app)
            try check(app.commands.resolution == .search, "optional command \(alias) was on by default")
        }
        model.shortcuts.includeOptionalLinks = true
        try check(ShortcutLibrary(defaults: shortcutFixturePreferences).includeOptionalLinks,
                  "optional Quicklinks toggle did not persist")
        for (alias, id, host, key, chineseTitle) in builtIns {
            try type("\(alias) 示例", into: app)
            guard case .web(let commandID, _, let target) = app.commands.resolution else {
                throw Failure("optional command \(alias) did not resolve after enabling it")
            }
            let query = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems
            try check(commandID == id && target.host == host && query?.contains(URLQueryItem(name: key, value: "示例")) == true,
                      "optional command \(alias) resolved to the wrong URL")
            try check(chineseCard.title == chineseTitle, "command card did not localize \(alias) in Chinese")
        }
        try type("?", into: app)
        for (alias, id, _, _, chineseTitle) in builtIns {
            guard let entry = app.commands.entries.first(where: { $0.keyword == alias && $0.commandID == id }) else {
                throw Failure("enabled built-in \(alias) was missing from command discovery")
            }
            try check(chineseCard.entryTitle(entry) == chineseTitle, "discovery did not localize \(alias) in Chinese")
        }
        for alias in builtIns.map({ $0.0 }) + ["g", "qa", "tr", "translate", "img", "cb", "clip"] {
            let conflict = internalLink(" \(alias.uppercased()) ")
            try check(model.shortcuts.saveResult(conflict) == .aliasInUse(alias) &&
                      !model.shortcuts.entries.contains(where: { $0.id == conflict.id }),
                      "saving a query shortcut did not explicitly reject the alias \(alias)")
        }
        let plainWeb = SavedShortcut(id: UUID(), title: "Plain Website", alias: "g", target: .web(url), pinned: false)
        try check(model.shortcuts.saveResult(plainWeb) == .saved, "could not save a plain web shortcut with alias g")
        var convertedWeb = plainWeb
        convertedWeb.queryParameter = "term"
        try check(model.shortcuts.saveResult(convertedWeb) == .aliasInUse("g") &&
                  model.shortcuts.entries.contains(plainWeb),
                  "converting a plain web shortcut did not reject the built-in alias g and preserve the original")
        model.shortcuts.remove(plainWeb)
        model.shortcuts.includeOptionalLinks = false
        try check(!ShortcutLibrary(defaults: shortcutFixturePreferences).includeOptionalLinks &&
                  Set(builtIns.map { $0.0 }).isDisjoint(with: Set(app.commands.entries.map(\.keyword))),
                  "disabled built-ins remained enabled or visible")
        try type("map 示例", into: app)
        try check(app.commands.resolution == .search, "disabling built-ins did not restore normal search")

        var internalWiki = internalLink(" WiKi ")
        try check(model.shortcuts.saveResult(internalWiki) == .saved,
                  "could not save a custom alias while its built-in was disabled")
        model.shortcuts.includeOptionalLinks = true
        internalWiki.title = "Internal Wiki Search"
        try check(model.shortcuts.saveResult(internalWiki) == .saved,
                  "could not edit the existing wiki shortcut after enabling its built-in")
        let savedWiki = ShortcutLibrary(defaults: shortcutFixturePreferences).entries.first { $0.id == internalWiki.id }
        try check(savedWiki?.title == internalWiki.title, "the updated wiki title was not persisted")
        try type("wiki 示例", into: app)
        guard case .web(let wikiID, let wikiTitle, let wikiURL) = app.commands.resolution else {
            throw Failure("the edited wiki shortcut disappeared when built-ins were enabled")
        }
        try check(wikiID == internalWiki.rowID && wikiTitle == internalWiki.title &&
                  wikiURL.absoluteString == "https://example.invalid/work?term=%E7%A4%BA%E4%BE%8B",
                  "the edited wiki shortcut did not retain its title and destination")
        try type("?", into: app)
        try check(app.commands.entries.filter { $0.keyword == "wiki" }.map(\.commandID) == [internalWiki.rowID],
                  "discovery did not preserve the custom wiki shortcut as the only wiki alias")
        model.shortcuts.includeOptionalLinks = false
        model.shortcuts.remove(internalWiki)

        try check(SavedShortcut.webURL("javascript:alert(1)") == nil &&
                  SavedShortcut.webURL("https://someone:password@example.invalid/") == nil,
                  "Quicklinks allowed an unsafe URL")
        var appAlias = pinned
        appAlias.alias = "launchfixture"
        let web = SavedShortcut(id: UUID(), title: "Fixture Website", alias: "sw", target: .web(url), pinned: false)
        let directory = corpus.appendingPathComponent("Test Project Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = SavedShortcut(id: UUID(), title: "Fixture Project", alias: "pj",
                                    target: .folder(IndexScope.folderPath(directory)), pinned: false)
        try check(model.shortcuts.save(appAlias) && model.shortcuts.save(web) && model.shortcuts.save(project),
                  "could not save isolated app alias, web link, and selected project")
        app.showSearch()
        try type("launchfixture", into: app)
        guard case .shortcut(let alias)? = model.selectedResult else { throw Failure("saved app alias did not match") }
        try check(alias.id == pinned.id, "app alias selected a different target")
        try type("sw", into: app)
        try check(dispatchedQuicklinks.isEmpty, "typing a Quicklink alias opened a URL")
        try key(kVK_Return, "\r", in: app)
        try check(dispatchedQuicklinks == [url] && !app.searchPresented, "Return did not dispatch the requested website")
        let savedWeb = ShortcutLibrary(defaults: shortcutFixturePreferences).entries.first { $0.id == web.id }
        try check(savedWeb == web && model.shortcuts.matches("sw").first?.score == 105,
                  "opening a web shortcut recorded history or changed its lexical score")

        app.showSearch()
        try type("pj", into: app)
        try key(kVK_Return, "\r", in: app)
        try check(dispatchedQuicklinks.last.map(IndexScope.folderPath) == IndexScope.folderPath(directory),
                  "project alias did not dispatch the saved local path")
        app.showSearch()
        try await until("the explicitly opened project was recent below the manual pin") {
            model.visibleResults.map(\.id) == [pinned.rowID, project.rowID]
        }
        let clipboardBefore = filePasteboard.string(forType: .string)
        try type("（２＋３）×４", into: app)
        try check(model.calculation?.display == "20" && filePasteboard.string(forType: .string) == clipboardBefore,
                  "typing a calculation changed the clipboard")
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.first?.id == "copy", "calculator context did not offer Copy Result")
        try key(kVK_Return, "\r", in: app)
        try check(filePasteboard.string(forType: .string) == "20", "context menu did not copy the calculated value")
        try verifyInternalCopy(app, "Copy Calculator Result")
        app.showSearch()
        try type("10 公里 到 米", into: app)
        try check(model.calculation?.copyValue == "10000 m", "local Chinese unit conversion failed")
        try key(kVK_Return, "\r", in: app)
        try check(filePasteboard.string(forType: .string) == "10000 m" &&
                  CalculationResult.evaluate("1 m to kg") == nil && CalculationResult.evaluate("2/0") == nil &&
                  CalculationResult.evaluate("2026-11-25") == nil, "conversion or invalid-input boundary failed")
        try verifyInternalCopy(app, "Copy Unit Conversion")
        print("Quicklinks passed: gh/wiki/map toggle, alias conflicts and precedence, Chinese titles, pins, keyboard actions, recent projects, web dispatch, pinyin ranking, arithmetic and unit conversion")
    }

    private func verifyRawFileQuery(_ app: AppDelegate) async throws {
        let model = app.model
        let expected = Set(["成都 卫健委.PPTX", "卫健委成都方案.pptx"])
        let first = "成都　 卫健委   pptx"
        try type(first, into: app)
        try check(model.query == first, "the AppKit field rewrote the original multiword query")
        try await until("multiple Chinese words and bare extension matched real files together") {
            !model.searching && Set(model.hits.map(\.name)) == expected
        }
        try type("pptx 卫健委 成都", into: app)
        try await until("reordered words with a bare extension returned the same files") {
            !model.searching && Set(model.hits.map(\.name)) == expected
        }
        try type(".pptx", into: app)
        try await until("an explicit extension filtered by actual file suffix") {
            !model.searching && Set(model.hits.map(\.name)) == expected.union(["Other project.pptx"])
        }
        try type("ext:pptx", into: app)
        try await until("an ext: filter matched by actual file suffix") {
            !model.searching && Set(model.hits.map(\.name)) == expected.union(["Other project.pptx"])
        }
        try type("pptx", into: app)
        try await until("a bare single-word extension searched file and folder names") {
            !model.searching && Set(model.hits.map(\.name)) == expected.union(["Other project.pptx", "成都 卫健委.pptx.bak", "成都 卫健委目录.pptx"])
        }
        print("Raw AppKit multiword and bare-extension queries passed")
    }

    private func verifyLegacyMigration(_ app: AppDelegate) async throws {
        let model = app.model
        try await until("saved scope and watch became available") {
            model.gemmaCoverage != nil && model.watchState == .running
        }
        try type("archive", into: app)
        try await until("lexical results remained available during migration") {
            model.selectedHit?.name == "archive-one.txt" && !model.searching
        }
        if model.gemmaCoverage?.documents_enabled == false {
            try check(model.localModelState == .available && model.embeddingState == .idle &&
                      !model.canBuildEmbeddings && !exists("model-check-started") && !exists("embeddings-started"),
                      "legacy consent expanded a metadata-only scope")
            return
        }
        try await until("legacy BGE coverage automatically queued Gemma verification") { self.exists("model-check-started") }
        try check(model.embeddingState == .verifying && !exists("embeddings-started"),
                  "migration started writing before verification")
        try signal("finish-model-check")
        try await waitForEmbeddingBatch(1)
        model.pauseEmbeddings(userInitiated: true)
        try signal("finish-embedding-1")
        try await until("legacy migration kept completed work when paused") {
            model.embeddingState == .paused && model.gemmaCoverage?.embedded_chunks == 1
        }
        try check(!exists("embedding-2-started") && model.watchState == .running && watchLaunches() == 1,
                  "migration ignored pause or disrupted live updates")
    }

    private func verifyInstalledModel(_ app: AppDelegate) async throws {
        let model = app.model
        try await until("packaged GUI found offline Gemma resources and document scope") {
            model.localModelState == .available && model.canBuildEmbeddings
        }
        try check(model.embeddingState == .idle && model.gemmaCoverage?.embedded_chunks == 0,
                  "a fresh document index enabled semantic indexing without consent")
        model.buildEmbeddings()
        try await until("GUI built and verified the local Gemma index", seconds: 40) {
            model.localModelState == .ready && model.gemmaCoverage?.complete == true &&
                model.gemmaCoverage?.embedded_chunks == 2
        }
        let idleFrame = app.panel.frame
        try type("x", into: app)
        try await until("initial nonempty query expanded the launcher") { app.panel.frame.height > idleFrame.height }
        let frame = app.panel.frame
        for (query, filename, original) in [
            ("怎样摆放太阳能板才能让它朝着正午阳光？", "entry-a.md", "midday sun"),
            ("How do I get the clock to run after its battery died?", "entry-b.md", "换上新的电池"),
        ] {
            try type(query, into: app)
            try await until("real Gemma returned the cross-language source for \(filename)", seconds: 30) {
                model.selectedHit?.name == filename &&
                    model.selectedHit?.isSemanticCandidate == true &&
                    model.selectedHit?.snippet?.contains(original) == true
            }
            try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
            try await until("Finder action revalidated the real Gemma preview", seconds: 30) {
                self.revealed?.lastPathComponent == filename
            }
            revealed = nil
            try check(app.panel.frame == frame, "Gemma result resized the search panel")
        }
        let semanticQuery = model.query
        try type("x", into: app)
        let pending = corpus.appendingPathComponent("pending.md")
        try Data("A textbook on currents and seasonal ocean tides.".utf8).write(to: pending)
        try await until("the real watcher reported partial Gemma coverage", seconds: 15) {
            model.gemmaCoverage?.pending == true && model.gemmaCoverage?.embedded_chunks == 2
        }
        try type(semanticQuery, into: app)
        try await until("the real partial index still returned its covered source", seconds: 30) {
            model.selectedHit?.name == "entry-b.md" && model.selectedHit?.isSemanticCandidate == true
        }
        try check(app.panel.frame == frame, "the watcher or partial Gemma coverage resized the launcher")
        try check(!NSApp.isActive && opened == nil, "Gemma test activated the GUI or opened a document")
        print("Installed Gemma GUI smoke passed (Chinese-to-English, English-to-Chinese, and partial coverage)")
    }

    private func verifyTiming(_ app: AppDelegate) async throws {
        let model = app.model
        let frame = app.panel.frame
        let chrome = app.panel.contentView
        var resizeCount = 0
        let resize = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: app.panel)
            .sink { _ in resizeCount += 1 }
        defer { resize.cancel() }

        try signal("hold-archive-text")
        try type("archive x", into: app)
        try type("archive", into: app)
        try await until("body lane intentionally held") { self.exists("archive-text-started") }
        try await until("fast names published while the body lane was held") {
            model.selectedHit?.name == "archive-one.txt" && model.searching
        }
        try key(kVK_DownArrow, "\u{f701}", in: app)
        let selected = model.selection
        try signal("finish-archive-text")
        try await until("body results merged into the same field") {
            model.hits.contains { $0.matched_by == "text" } && !model.searching
        }
        try check(model.selection == selected, "body results stole selection")

        try type("waiting old name", into: app)
        try await until("an older name lookup was held") { self.exists("pre-han-name-started") }
        let began: ContinuousClock.Instant = .now
        var firstName: ContinuousClock.Instant?
        let observeFirst = model.$hits.sink { hits in
            if firstName == nil && hits.first?.name == "鹿鸣.md" {
                firstName = .now
            }
        }
        defer { observeFirst.cancel() }
        try type("鹿鸣", into: app)
        try check(model.selectedHit == nil, "the old in-flight name result stayed actionable")
        try signal("finish-pre-han-name")
        try await until("the Han filename became actionable while text was held on the shared server") {
            self.exists("han-body-started") && model.selectedHit?.name == "鹿鸣.md" && model.searching
        }
        let enter: ContinuousClock.Instant = .now
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try check(revealed == nil, "Finder dispatched without validating on the shared server")
        try signal("finish-han-body")
        try await until("Finder dispatched the validated filename") {
            self.revealed?.lastPathComponent == "鹿鸣.md" && self.exists("han-validation-started")
        }
        guard let firstName, let revealDispatch else { throw Failure("missing search or Finder timestamps") }
        print(String(format: "Han control-path timing: input to first name %.1f ms, Command–Return to dispatch %.1f ms",
                     milliseconds(began.duration(to: firstName)), milliseconds(enter.duration(to: revealDispatch))))
        revealed = nil
        try await until("the delayed Han body merged below the selected filename") {
            !model.searching && model.selectedHit?.name == "鹿鸣.md" &&
                model.hits.contains { $0.name == "local-field-notes.md" && $0.matched_by == "text" }
        }

        let stableHanRows = model.hits
        try signal("hold-han-refresh-body")
        try signal("update-watch")
        try await until("watch started rechecking the visible Han body result") { self.exists("han-refresh-body-started") }
        try check(model.hits == stableHanRows && model.selectedHit == nil,
                  "the same query flashed its old rows or left the prior revision actionable during watch refresh")
        try signal("finish-han-refresh-body")
        try await until("watch published the same complete rows") {
            !model.searching && model.hits == stableHanRows && model.selectedHit?.name == "鹿鸣.md"
        }

        try type("late lexical delivery", into: app)
        try await until("the lexical name lane was held") { self.exists("late-name-started") }
        try check(model.searching && model.selectedHit == nil, "blocked serve left old rows actionable")
        let bodyResponder = try editor(app)
        try signal("finish-late-name")
        try await until("strong names ranked first and body hits followed from the shared server") {
            !model.searching && model.hits.first?.name == "late lexical delivery.md" &&
                model.selectedHit?.name == "late lexical delivery.md" &&
                model.hits.contains { $0.name == "body-before-name.md" && $0.matched_by == "text" }
        }
        try check(app.panel.firstResponder === bodyResponder, "late lexical delivery stole the search field focus")
        let latestSelection = model.selection

        try type("obsolete", into: app)
        try await until("obsolete reply intentionally held") { self.exists("obsolete-started") }
        try type("qingshan", into: app)
        try check(model.selection == latestSelection && !model.hits.isEmpty && model.selectedHit == nil,
                  "editing cleared the previous rows or kept an obsolete result actionable")
        try key(kVK_Return, "\r", in: app)
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try check(opened == nil && revealed == nil, "a key action targeted the prior query")
        try signal("finish-obsolete")
        try await until("latest query survived an obsolete reply") {
            model.hits.count == 1 && model.hits.first?.name == "青山月报.md" && !model.searching
        }

        try type("crowded needle", into: app)
        try await until("body lane survived sixty weak path matches") {
            model.hits.count == 60 && !model.searching
        }
        guard let body = model.hits.firstIndex(where: { $0.name == "body-match.md" && $0.matched_by == "text" }),
              let weak = model.hits.firstIndex(where: { $0.matched_by == "path" })
        else { throw Failure("missing distinct body or weak path hit") }
        try check(model.hits.first?.name == "crowded needle spec.txt" && body < weak &&
                  model.hits.filter { $0.matched_by == "path" }.count >= 57,
                  "a weaker path match outranked text or a strong name")
        model.selection = model.hits[body].path
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("body hit revalidated in its source lane") {
            self.revealed?.lastPathComponent == "body-match.md" && self.exists("body-validation-started")
        }
        revealed = nil
        try check(app.panel.frame == frame && app.panel.contentView === chrome && resizeCount == 0,
                  "typing or result lane delivery resized or replaced the launcher")
    }

    private func measureBundledHan(_ app: AppDelegate) async throws {
        let model = app.model
        var firstName: ContinuousClock.Instant?
        let observe = model.$hits.sink { hits in
            if firstName == nil && hits.first?.name == "鹿鸣.md" { firstName = .now }
        }
        defer { observe.cancel() }
        let began: ContinuousClock.Instant = .now
        try type("鹿鸣", into: app)
        try await until("bundled engine returned the selected Han filename") {
            model.selectedHit?.name == "鹿鸣.md"
        }
        let enter: ContinuousClock.Instant = .now
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("bundled engine validated the Han Finder action") { self.revealed?.lastPathComponent == "鹿鸣.md" }
        guard let firstName, let revealDispatch else { throw Failure("missing bundled search or Finder timestamps") }
        print(String(format: "Bundled Han timing: input to first name %.1f ms, Command–Return to dispatch %.1f ms",
                     milliseconds(began.duration(to: firstName)), milliseconds(enter.duration(to: revealDispatch))))
        revealed = nil
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func verifyImageSearch(_ app: AppDelegate) async throws {
        let model = app.model
        let images = app.imageSearch
        let folder = corpus.appendingPathComponent("Chosen", isDirectory: true)
        let projector = try String(contentsOf: directory.appendingPathComponent("projector-path"), encoding: .utf8)
        try await until("image fixture filename index did not become trusted") { model.canSearch && model.watchState == .running }
        try type("img 浅蓝海面上有一条红色帆船", into: app)
        try await until("unconfigured image command did not settle") { images.scope != nil && !images.loading }
        try check(!model.isImageSearch && images.scope?.root == nil && !images.building, "image indexing started by default")
        try key(kVK_ANSI_Comma, ",", in: app, throughPanel: true, flags: [.command])
        try check(app.settingsSession.page == .index, "image settings opened outside Index & Privacy")
        chosenImageFolder = folder
        chosenImageProjector = URL(fileURLWithPath: projector)
        app.chooseImageResource(folder: true)
        try await until("explicit image folder was not saved") { images.scope?.root == IndexScope.folderPath(folder) && !images.loading }
        app.chooseImageResource(folder: false)
        try check(images.scope?.vectors == 0 && !images.building, "configuring resources read image pixels before Build")
        images.build()
        app.showSearch()
        try type("sentinel-local-note", into: app)
        try await until("name lookup stopped while indexing images") { model.selectedHit?.name == "sentinel-local-note.txt" }
        try await until("real image vectors were not generated", seconds: 120) {
            !images.building && !images.loading && (images.scope?.vectors ?? 0) == 4
        }

        let originalPanel = app.panel
        let field = try editor(app)
        let start = ContinuousClock.now
        try type("img 浅蓝海面上有一条红色帆船", into: app)
        try await until("cold image search did not settle", seconds: 34) {
            !model.searching && (model.selectedHit != nil || model.searchNotice != nil)
        }
        try check(model.selectedHit?.name == "93a2.png" && model.selectedHit?.isImageMatch == true,
                  "cold image search did not match the opaque red sailboat filename")
        let cold = milliseconds(start.duration(to: .now))
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("matching image did not preview in the original panel") {
            if case .ready(let selection, let preview) = app.inlinePreview.state,
               case .image? = preview.visual { return selection.id.hasSuffix("/93a2.png") && app.panel === originalPanel }
            return false
        }
        try check(app.panel.firstResponder === field, "image preview took search focus")
        if exists("capture-preview") {
            try capture("lumen-image-search-preview.png", appearance: .aqua, window: app.panel)
            app.panel.appearance = nil
        }
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("image match did not pass targeted Finder revalidation") { self.revealed?.lastPathComponent == "93a2.png" }
        let warmStart = ContinuousClock.now
        try type("img A black umbrella on a grey background", into: app)
        try await until("warm English image search did not rank the opaque umbrella filename first") {
            model.selectedHit?.name == "a48f.png" && !model.searching && !app.inlinePreview.isOpen
        }
        let warm = milliseconds(warmStart.duration(to: .now))
        try type("sentinel-local-note", into: app)
        try check(!model.hits.contains(where: \.isImageMatch), "name search kept visible image results")
        try type("img 黄色背景上放着三个蓝色圆形", into: app)
        try await Task.sleep(for: .milliseconds(190))
        try type("sentinel-local-note", into: app)
        try await until("ordinary names did not recover after leaving image search") {
            model.selectedHit?.name == "sentinel-local-note.txt" && !model.isImageSearch && !model.searching
        }
        try await Task.sleep(for: .milliseconds(350))
        try check(model.selectedHit?.name == "sentinel-local-note.txt" && !app.inlinePreview.isOpen,
                  "obsolete image results appeared in name search")
        images.setFolder(nil)
        try await until("image opt-out did not remove vectors") {
            images.scope?.root == nil && images.scope?.vectors == 0 && !images.loading
        }
        print(String(format: "Native local image search passed (cold %.1f ms, warm %.1f ms, in-panel preview and Finder)", cold, warm))
    }

    private func verifyContentPipeline(_ app: AppDelegate) async throws {
        let model = app.model
        let selected = corpus.appendingPathComponent("Chosen", isDirectory: true)
        let path = IndexScope.folderPath(selected)
        try await until("existing names verified") { model.canSearch && model.watchState == .running }
        app.showSettings()
        app.settingsSession.page = .index
        model.setContentPaused(true)
        chosenSettingsDirectories = [selected]
        app.chooseSettingsDirectories(.content)
        try check(app.settingsSession.scope.contentFolders == [path], "content folder picker changed the name scope")
        app.settingsSession.apply()
        try await until("saved explicit content roots with work paused") {
            !model.scopePending && model.savedScope?.contentFolders == [path] && (model.contentCoverage?.pending ?? 0) >= 2
        }
        app.showSearch()
        try type("outside-report", into: app)
        try await until("names searchable with document indexing paused") { model.selectedHit?.name == "outside-report.md" }
        try check(!model.contentRunning && model.contentCoverage?.checked == 0, "document indexing moved while paused")
        model.setContentPaused(false)
        try await until("resumed content run committed and kept live name search") {
            model.contentCoverage?.pending == 0 && (model.contentCoverage?.checked ?? 0) >= 2 &&
            model.selectedHit?.name == "outside-report.md"
        }
        func findPDF() async throws -> String {
            try type("zircon calibration", into: app)
            try await until("actual second-page text hit") {
                model.selectedHit?.name == "report.pdf" && model.selectedHit?.pdf_page == 2 &&
                    model.selectedHit?.snippet?.contains("zircon calibration") == true
            }
            guard let hit = model.selectedHit else { throw Failure("lost PDF hit") }
            return hit.path
        }
        let pdfPath = try await findPDF()
        let input = try editor(app)
        let marked = "qa nihao"
        input.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0),
                            replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        try check(input.hasMarkedText(), "could not start command-like marked text")
        app.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: app.searchField))
        if let action = app.searchField.action { _ = NSApp.sendAction(action, to: app, from: app.searchField) }
        try check(model.query == "zircon calibration" && model.selection == pdfPath &&
                  app.commands.resolution == .search && !app.commands.showsCard,
                  "marked text changed live results or switched to a command card")
        input.insertText("zircon calibration", replacementRange: input.markedRange())
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("inline PDF did not render the verified match page") {
            if case .ready(_, let document) = app.inlinePreview.state,
               case .pdf(_, 2, true)? = document.visual {
                return document.evidence?.text.contains("zircon calibration") == true
            }
            return false
        }
        if exists("capture-preview") {
            try capture("lumen-inline-pdf.png", appearance: .aqua, window: app.panel)
            app.panel.appearance = nil
        }
        guard let pdfImage = app.inlinePreview.image else { throw Failure("PDF bitmap was not decoded for the view") }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        try check(app.inlinePreview.image === pdfImage, "layout discarded the cached PDF bitmap")
        // Start from a taller frame and verify the close-button action recomputes the natural height.
        let frame = app.panel.frame
        app.panel.setFrame(frame.insetBy(dx: 0, dy: -16).offsetBy(dx: 0, dy: -16), display: false)
        app.closeInlinePreview()
        try check(!app.inlinePreview.isOpen && app.inlinePreview.image == nil && app.panel.frame == frame &&
                  model.query == "zircon calibration" && app.searchPresented,
                  "closing inline preview did not restore the anchored layout or retain the search")
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.inlinePreview.isOpen && model.query == "zircon calibration" && app.searchPresented,
                  "Escape closed the launcher rather than its preview")

        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        guard let windowPreview = app.contextActions.items.firstIndex(where: { $0.id == "quick-look" }) else {
            throw Failure("missing explicit window preview action")
        }
        app.contextActions.run(windowPreview)
        try await until("explicit Preview in Window opened the PDFKit view on page 2") { app.localPreview?.displayedPDFPage == 2 }
        guard let preview = app.localPreview else { throw Failure("preview panel missing") }
        // The titled preview needs an active app to remain key. Keep both windows offscreen.
        do {
            try check(NSApp.setActivationPolicy(.accessory), "could not enable activation for the preview focus test")
            defer {
                app.panel.orderOut(nil)
                preview.close()
                NSApp.setActivationPolicy(.prohibited)
            }
            func focusPreview(_ preview: LocalPreviewPanel) async throws {
                app.panel.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
                app.panel.makeKeyAndOrderFront(nil)
                try check(app.panel.isKeyWindow && !preview.isKeyWindow, "search was not key before the preview handoff")
                app.makeLocalPreviewKey()
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                try check(preview.isKeyWindow && !app.panel.isKeyWindow && app.searchPresented &&
                          model.query == "zircon calibration" && model.selection == pdfPath,
                          "settled focus did not move to the preview while preserving the search session")
            }
            func verifyFocusLeft(_ message: String) async throws {
                try await until(message) {
                    !app.panel.isKeyWindow && !preview.isKeyWindow && !app.searchPresented &&
                    model.query.isEmpty && model.selection == nil
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            try await until("app did not activate for the preview focus test") { NSApp.isActive }
            try await focusPreview(preview)
            NSApp.deactivate()
            try await verifyFocusLeft("focus leaving the preview did not dismiss and reset search")

            app.showSearch()
            _ = try await findPDF()
            try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
            guard let windowPreview = app.contextActions.items.firstIndex(where: { $0.id == "quick-look" }) else {
                throw Failure("missing explicit window preview action after focus loss")
            }
            app.contextActions.run(windowPreview)
            try await until("reopening after losing focus created a new preview") { app.localPreview != nil && app.localPreview !== preview }
            guard let nextPreview = app.localPreview else { throw Failure("second preview panel missing") }
            try await focusPreview(nextPreview)
            app.panel.orderOut(nil) // Prevent AppKit from restoring key focus to search when the preview closes.
            nextPreview.close()
            try await verifyFocusLeft("closing the preview without returning focus to search did not dismiss it")
        }
        app.showSearch()
        _ = try await findPDF()
        try key(kVK_Return, "\r", in: app)
        try await until("Return dispatched the original PDF to the default-open route") {
            self.opened?.path == pdfPath && app.localPreview == nil && !app.searchPresented
        }
        opened = nil
        app.showSearch()
        _ = try await findPDF()
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.first?.id == "open", "missing PDF Open action")
        try key(kVK_Return, "\r", in: app)
        try await until("Command–K Open dispatched the original PDF to the default-open route") {
            self.opened?.path == pdfPath && app.localPreview == nil && !app.searchPresented
        }
        app.showSearch()
        try type("included note", into: app)
        try await until("verified text excerpt became selectable") { model.selectedHit?.snippet?.contains("included note") == true }
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("inline text excerpt reused verified evidence") {
            if case .ready(_, let result) = app.inlinePreview.state {
                return result.visual == nil && result.evidence?.match == .literal
            }
            return false
        }

        try type("preview-fixture-", into: app)
        try await until("local image fixtures became selectable") {
            model.hits.filter { $0.name.hasPrefix("preview-fixture-") }.count == 2 && model.selectedHit != nil
        }
        try check(!app.inlinePreview.isOpen, "a query change retained the prior preview")
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try key(kVK_DownArrow, "\u{f701}", in: app)
        guard let selectedImage = model.selectedHit?.path else { throw Failure("image navigation lost selection") }
        try await until("rapid selection did not show the new image") {
            if case .ready(let selection, let preview) = app.inlinePreview.state,
               case .image? = preview.visual { return selection.id == selectedImage }
            return false
        }
        if exists("capture-preview") {
            try capture("lumen-inline-image.png", appearance: .darkAqua, window: app.panel)
            app.panel.appearance = nil
        }

        try type("cloud-preview-known", into: app)
        try await until("cloud fixture was not metadata only") { model.selectedHit?.isCloudReference == true }
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try check({
            if case .unavailable(_, .notLocal) = app.inlinePreview.state { return true }
            return false
        }() && app.localPreview == nil, "cloud preview did not decline before reading")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try type("outsideexclusivebody", into: app)
        try await until("body remained outside the chosen scope") { !model.searching }
        try check(model.hits.isEmpty, "unselected text appeared as a hit")
        app.showSettings()
        app.settingsSession.page = .index
        app.settingsSession.remove(path, from: .content)
        app.settingsSession.apply()
        try await until("narrowed document scope committed") {
            !model.scopePending && model.savedScope?.content_roots == [] && model.watchState == .running
        }
        app.showSearch()
        try type("zircon calibration", into: app)
        try await until("removed body stopped matching") { !model.searching }
        try check(model.hits.isEmpty, "narrowed scope retained the page result")
        try type("report.pdf", into: app)
        try await until("removed document still searchable by name") { model.hits.contains { $0.name == "report.pdf" && $0.pdf_page == nil } }
    }

    private func verifySettings(_ app: AppDelegate) async throws {
        let model = app.model
        let session = app.settingsSession
        let excluded = corpus.appendingPathComponent("Excluded", isDirectory: true)
        let protected = corpus.appendingPathComponent("Scoped", isDirectory: true)
        let child = protected.appendingPathComponent("Allowed Child", isDirectory: true)
        let file = child.appendingPathComponent("protected-neighbor.md")
        let excludedPath = IndexScope.folderPath(excluded)
        let protectedPath = IndexScope.folderPath(protected)
        let childPath = IndexScope.folderPath(child)
        try await until("saved index scope loaded before editing") {
            model.canSearch && model.savedScope?.deny == [excludedPath]
        }
        let settingsKey = try event(kVK_ANSI_Comma, ",", in: app, flags: [.command])
        try check(app.panel.performKeyEquivalent(with: settingsKey) && app.settings != nil && !app.searchPresented,
                  "Command–comma did not open settings from Search")
        guard let settings = app.settings else { throw Failure("settings panel is missing") }
        try check(!settings.isVisible && !NSApp.isActive && !wasActivated,
                  "settings smoke activated the app or displayed a window")
        try check(session.page == .general &&
                  NSApp.mainMenu?.items.first?.submenu?.items.contains(where: {
                      $0.action == #selector(AppDelegate.showSettings) && $0.keyEquivalent == ","
                  }) == true, "the initial page or the app menu Settings shortcut is missing")
        app.recordShortcut(settingsKey)
        guard case .app? = model.hotKeyIssue else { throw Failure("launcher shortcut could override Settings") }
        app.disableShortcut()

        session.page = .index
        let original = model.savedScope
        let initialWatchStarts = watchLaunches()
        try check(!session.canApply && session.scope.deny == [excludedPath],
                  "the editor did not start with the persisted scope")
        chosenSettingsDirectories = [child, child]
        app.chooseSettingsDirectories(.include)
        try check(session.scope.allow == [childPath], "directory selection was duplicated or altered")
        session.remove(childPath, from: .include)
        try check(!session.hasChanges, "removing a staged folder did not restore the initial scope")
        app.chooseSettingsDirectories(.exclude)
        try check(!session.hasChanges, "canceling the directory selector edited scope")

        chosenSettingsDirectories = [child]
        app.chooseSettingsDirectories(.include)
        chosenSettingsDirectories = [protected]
        app.chooseSettingsDirectories(.exclude)
        session.setDocuments(true)
        session.setDocuments(false)
        try check(session.hasChanges && model.savedScope == original && watchLaunches() == initialWatchStarts &&
                  !model.scopePending && model.canSearch,
                  "a draft changed the active index or watcher")
        session.page = .advanced
        chosenDiagnosticFile = file
        app.chooseDiagnosticFile()
        try await until("the signed CLI diagnosed the explicitly selected synthetic file") {
            if case .result(file.lastPathComponent, let result) = model.fileDiagnosis {
                return result.name == "indexed" && result.text == "text_disabled" && result.semantic == "text_disabled"
            }
            return false
        }
        if exists("capture-settings") { try await captureSettings(settings, session: session) }

        app.showSearch()
        try type("protected-neighbor", into: app)
        try await until("the draft did not hide live results") {
            !model.searching && model.selectedHit?.name == "protected-neighbor.md"
        }
        try check(!exists("metadata-only-body-started"), "metadata-only scope launched a text query")
        session.page = .advanced
        try check(session.canRebuild, "advanced maintenance did not recognize a saved scope")
        model.rebuildSavedIndex()
        try await until("rebuild used the saved scope and resumed watch") {
            model.indexWork == nil && model.watchState == .running && self.watchLaunches() == initialWatchStarts + 1
        }
        try check(model.savedScope == original && session.hasChanges,
                  "maintenance used or discarded the unapplied draft")
        try await until("the existing scope survived rebuilding") { model.selectedHit?.name == "protected-neighbor.md" }

        session.page = .index
        session.apply()
        try check(model.scopePending && model.hits.isEmpty && !session.hasChanges,
                  "Apply did not immediately retire results or committed the wrong draft")
        try await until("Apply persisted the two lists and resumed watch") {
            model.indexWork == nil && model.watchState == .running && !model.searching &&
                model.savedScope?.deny.contains(protectedPath) == true && model.savedScope?.allow == [childPath]
        }
        try check(model.canSearch && model.hits.isEmpty,
                  "a selected child overrode its excluded parent")
        session.page = .advanced
        chosenDiagnosticFile = file
        app.chooseDiagnosticFile()
        try await until("file diagnostics reflected the newly saved exclusion") {
            if case .result(file.lastPathComponent, let result) = model.fileDiagnosis {
                return [result.name, result.text, result.semantic].allSatisfy { $0 == "excluded" }
            }
            return false
        }
        settings.close()
        if case .idle = model.fileDiagnosis {} else { throw Failure("closing settings retained a selected file report") }
        try signal("fail-watch")
        try await until("the launcher still has an activity notice when watching fails") {
            model.watchState == .failed &&
                model.launcherActivityTitle == model.t("文件监听已停止", "File watching stopped")
        }
        print("Settings smoke passed (shared window, shortcut, draft, exact-scope rebuild, Apply, and file diagnostics)")
    }

    private func captureSettings(_ window: NSPanel, session: SettingsSession) async throws {
        for page in SettingsPage.allCases {
            session.page = page
            try await Task.sleep(for: .milliseconds(100))
            for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try capture("settings-\(page.rawValue)-\(style).png", appearance: appearance, window: window)
            }
        }
        window.appearance = nil
        try check(!window.isVisible && !NSApp.isActive, "settings screenshots activated the app")
    }

    private func captureSnapshots(_ app: AppDelegate) async throws {
        try type("", into: app)
        try await until("idle launcher is 84 points tall") { app.panel.frame.height == 84 }
        try capture("lumen-idle-light.png", appearance: .aqua, window: app.panel)
        try type("design", into: app)
        try await until("eight visible result rows are laid out") {
            app.model.hits.count >= 8 && !app.model.searching && app.panel.frame.height == 436
        }
        try capture("lumen-results-light.png", appearance: .aqua, window: app.panel)
        try capture("lumen-results-dark.png", appearance: .darkAqua, window: app.panel)
        app.panel.appearance = nil
        try check(!NSApp.isActive && !app.panel.isVisible, "offscreen snapshots activated the app")
    }

    private func hasProbeIcon(in window: NSWindow) -> Bool {
        guard let surface = window.contentView, let appearance = NSAppearance(named: .aqua) else { return false }
        window.appearance = appearance
        surface.layoutSubtreeIfNeeded()
        let bounds = surface.bounds
        guard let backing = surface.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        appearance.performAsCurrentDrawingAppearance { surface.cacheDisplay(in: bounds, to: backing) }
        guard let png = backing.representation(using: .png, properties: [:]),
              let image = NSBitmapImageRep(data: png) else { return false }
        var pixels = 0
        for x in stride(from: 0, to: min(110, image.pixelsWide), by: 3) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 3) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent - color.greenComponent > 0.35 &&
                    color.blueComponent - color.greenComponent > 0.25 {
                    pixels += 1
                    if pixels >= 30 { return true }
                }
            }
        }
        return false
    }

    private func capture(_ filename: String, appearance: NSAppearance.Name, window: NSWindow) throws {
        guard let surface = window.contentView, let appearance = NSAppearance(named: appearance) else {
            throw Failure("could not configure snapshot appearance")
        }
        window.appearance = appearance
        surface.layoutSubtreeIfNeeded()
        let bounds = surface.bounds
        guard let image = surface.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw Failure("could not allocate offscreen snapshot")
        }
        appearance.performAsCurrentDrawingAppearance { surface.cacheDisplay(in: bounds, to: image) }
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw Failure("could not encode offscreen snapshot")
        }
        try png.write(to: directory.appendingPathComponent(filename))
    }

    private func verifyWatch(_ app: AppDelegate) async throws {
        let model = app.model
        try type("watchneedle", into: app)
        try await until("watch query starts with no results") { model.hits.isEmpty && !model.searching }
        let frame = app.panel.frame
        var resizeCount = 0
        let resize = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: app.panel)
            .sink { _ in resizeCount += 1 }
        defer { resize.cancel() }
        let file = corpus.appendingPathComponent("watchneedle.txt")
        try Data().write(to: file)
        if controlledTiming {
            try signal("hold-watch-progress")
            try signal("update-watch")
            try await until("watch progress streamed independently of stdout") {
                model.watchProgress?.entries == 6 && model.watchState == .running && model.hits.isEmpty &&
                    model.launcherActivityTitle == model.t("正在扫描文件…", "Scanning files…")
            }
            try signal("finish-watch-progress")
        }
        try await until("watch notification refreshed active results") { model.hits.first?.name == "watchneedle.txt" }
        try check(model.watchProgress == nil, "watch completion left progress busy")
        if !controlledTiming {
            try FileManager.default.removeItem(at: file)
            try await until("watch notification removed deleted result") { model.hits.isEmpty && !model.searching }
        }
        try check(app.panel.frame == frame && resizeCount == 0, "watch events resized the launcher")
    }

    private func verifyCloudAction(_ app: AppDelegate) async throws {
        let model = app.model
        try type("cloudledger", into: app)
        try await until("provider metadata result") {
            model.selectedHit?.availability == "provider_metadata_only" && !model.searching
        }
        guard let hit = model.selectedHit else { throw Failure("missing cloud result") }
        try check(LocalFile.dragURL(for: hit) == nil, "a cloud-only row exported a file drag URL")
        try key(kVK_Return, "\r", in: app)
        try check(model.searchNotice?.problem == .online && opened == nil && revealed == nil,
                  "Return activated a cloud reference")
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try check(app.localPreview == nil && model.searchNotice?.problem == .online,
                  "Quick Look accepted online-only metadata")
        if controlledTiming { try signal("hold-cloud-reveal") }
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        if controlledTiming {
            try await until("Finder action held for a concurrent watch event") { self.exists("cloud-reveal-started") }
            var refreshed = false
            let refresh = model.$searching.sink { if $0 { refreshed = true } }
            defer { refresh.cancel() }
            try signal("update-watch")
            try await until("watch invalidated the current query during Finder validation") {
                refreshed && model.selectedHit == nil
            }
            try check(revealed == nil, "Finder received a result from the superseded watch revision")
            try signal("finish-cloud-reveal")
            try await until("shared serve finished the watch refresh") { !model.searching }
        }
        try await until("Command–Return revealed the cloud reference") { self.revealed?.path == hit.path }
        try check(opened == nil && model.query == "cloudledger", "Finder action opened the file or closed search")
    }

    private func verifySemanticInvalidation(_ app: AppDelegate) async throws {
        let model = app.model
        let frame = app.panel.frame
        try type("health examination", into: app)
        try await until("related excerpts started automatically after direct results") { self.exists("semantic-enrichment-started") }
        let direct = model.hits.map(\.path)
        try check(direct.count == 2 && model.hits.allSatisfy { !$0.isSemanticCandidate },
                  "direct hits were delayed or replaced by the optional lane")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        let selected = model.selection
        let responder = try editor(app)
        try signal("finish-semantic-enrichment")
        try await until("bounded related excerpts appended") {
            model.hits.filter(\.isSemanticCandidate).count == 3 && !model.semanticBusy
        }
        try check(Array(model.hits.prefix(direct.count)).map(\.path) == direct && model.selection == selected &&
                  Set(model.hits.map(\.path)).count == model.hits.count && app.panel.frame == frame &&
                  app.panel.firstResponder === responder,
                  "related excerpts duplicated results, changed direct rank, focus, selection, or panel size")
        guard let hit = model.hits.first(where: { $0.name == "notes.md" && $0.isSemanticCandidate })
        else { throw Failure("missing Gemma candidate") }
        try check(model.relatedExcerptsLabel == "相关原文", "candidate label did not say related excerpts")
        var resolved: URL?
        model.resolve(hit, action: .open) { resolved = $0 }
        try await until("candidate action validated the indexed document snapshot") { resolved?.path == hit.path }
        try Data("Replacement body".utf8).write(to: corpus.appendingPathComponent("notes.md"), options: .atomic)
        try signal("update-watch")
        try await until("watch replaced a stale semantic excerpt") {
            model.hits.contains { $0.name == "notes.md" && $0.snippet == "Replacement body" } && !model.searching
        }
        try check(model.selection == selected && app.panel.frame == frame,
                  "watch refresh stole selection or resized the panel")

        try type("outdated semantic request", into: app)
        try await until("old related query held by fixture") { self.exists("stale-semantic-started") }
        try type("qingshan", into: app)
        try signal("finish-stale-semantic")
        try await until("obsolete related query could not attach to newly typed text") {
            model.hits.count == 1 && model.selectedHit?.name == "青山月报.md" && !model.semanticBusy
        }
        try check(lineCount("semantic-serve-launches") == 1 && exists("semantic-batch-validated"),
                  "refinements did not reuse one worker or semantic result skipped batch validation")

        try signal("gemma-cap")
        try signal("update-watch")
        try await until("watch reported the Gemma storage limit") {
            model.gemmaCoverage?.limited == true && model.gemmaCoverage?.hasResults == true
        }
        try check(!model.canBuildEmbeddings, "capped coverage would start more embedding batches")
        try type("health examination", into: app)
        try await until("stored Gemma vectors remained searchable at the storage cap") {
            model.hits.contains { $0.isSemanticCandidate && $0.name == "notes.md" } &&
                self.exists("capped-gemma-query-started")
        }
        try check(lineCount("semantic-serve-launches") == 1 && app.panel.frame == frame,
                  "capped search restarted the worker or resized the panel")

    }

    private func verifyMissingPath(_ app: AppDelegate) async throws {
        let model = app.model
        try type("open-safety", into: app)
        try await until("local result visible before deletion") { model.selectedHit?.name == "open-safety.txt" }
        try FileManager.default.removeItem(at: corpus.appendingPathComponent("open-safety.txt"))
        try key(kVK_Return, "\r", in: app)
        try await until("open rechecked the missing filesystem path before watch updated") { model.searchNotice?.problem == .stale }
        try check(opened == nil && model.hits.isEmpty && model.selection == nil, "removed path remained actionable")

        if controlledTiming {
            try type("preview-safety", into: app)
            try await until("a local result was visible before symlink replacement") {
                model.selectedHit?.name == "preview-safety.txt"
            }
            let replaced = corpus.appendingPathComponent("preview-safety.txt")
            try FileManager.default.removeItem(at: replaced)
            try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: corpus.appendingPathComponent("notes.md"))
            try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
            try await until("Quick Look rejected the replacement before the watcher ran") {
                model.searchNotice?.problem == .stale
            }
            try check(app.localPreview == nil && !model.hits.contains { $0.name == "preview-safety.txt" },
                      "a stale result could preview a replacement symlink")
        }
    }

    private func verifyReplacedDocument(_ app: AppDelegate) async throws {
        let model = app.model
        try type("safety original paragraph", into: app)
        try await until("preview visible before replacing a same-name file") {
            model.selectedHit?.snippet?.contains("safety original paragraph") == true
        }
        let file = corpus.appendingPathComponent("content-safety-source.md")
        try Data("Different file at the same path.".utf8).write(to: file, options: .atomic)
        try key(kVK_Return, "\r", in: app)
        try await until("same-name replacement was refused before the watcher event") { model.searchNotice?.problem == .stale }
        try check(opened == nil && model.selection == nil, "the old preview opened a replacement file")
    }

    private func verifyStaleBeforeDisplay(_ app: AppDelegate) async throws {
        let model = app.model
        try type("before render original", into: app)
        try await until("old preview and its indexed stamp held before first display") { self.exists("before-render-started") }
        let file = corpus.appendingPathComponent("before-render.md")
        try Data("A new file at the same path.".utf8).write(to: file, options: .atomic)
        try signal("finish-before-render")
        try await until("stale preview discarded before first display") { !model.searching }
        try check(model.hits.isEmpty && model.selection == nil, "stale snippet was displayed for the replacement file")
        try key(kVK_Return, "\r", in: app)
        try check(opened == nil, "stale result authorized opening the replacement")

        try type("missing stamp original", into: app)
        try await until("preview without a stamp was rejected") { !model.searching }
        try check(model.hits.isEmpty && model.selection == nil, "an unstamped snippet appeared as an actionable result")
    }

    private func verifyEmbeddingRun(_ app: AppDelegate) async throws {
        let model = app.model
        try await until("document coverage permits an intentional build") { model.canBuildEmbeddings }
        try check(!exists("embeddings-started"), "first use enabled semantic indexing without consent")
        model.buildEmbeddings()
        try await waitForEmbeddingBatch(1)
        try type("duringbatch", into: app)
        try Data().write(to: corpus.appendingPathComponent("duringbatch.txt"))
        try signal("update-watch")
        try await until("watch and name search continued during embedding") { model.selectedHit?.name == "duringbatch.txt" }
        try check(model.embeddingState == .running && model.watchState == .running, "embedding interrupted the watcher")
        try signal("finish-embedding-1")
        try await waitForEmbeddingBatch(2)
        try signal("finish-embedding-2")
        try await waitForEmbeddingBatch(3)
        try check(model.embeddingBatch?.new_embeddings == 0 && model.embeddingBatch?.skipped_chunks == 2,
                  "a batch that saved skips did not count as progress")

        model.pauseEmbeddings()
        try check(model.embeddingState == .pausing, "pause did not wait for the current batch")
        try signal("finish-embedding-3")
        try await until("completed batch saved before pausing") {
            model.indexWork == nil && model.embeddingState == .paused && model.embeddingBatch?.new_embeddings == 1
        }
        try check(!exists("embedding-4-started"), "pause queued another batch")
        model.buildEmbeddings()
        try await waitForEmbeddingBatch(4)
        try signal("finish-embedding-4")
        try await until("resumed embedding stopped when complete") {
            model.indexWork == nil && model.embeddingState == .finished && model.embeddingBatch?.has_more == false
        }
        try check(!exists("embedding-5-started"), "completed indexing queued another batch")

        try await until("coverage reports current indexed text") { model.gemmaCoverage?.complete == true }
        try check(!model.canBuildEmbeddings, "completed coverage offered another full build")
        try signal("gemma-pending")
        try signal("update-watch")
        try await until("new text became eligible for embedding") { model.canBuildEmbeddings }
        model.buildEmbeddings()
        try await waitForEmbeddingBatch(5)
        try signal("finish-embedding-5")
        try await until("zero progress stopped with an explanation") {
            model.indexWork == nil && model.embeddingNotice?.problem == .embeddingNoProgress
        }
        try check(!exists("embedding-6-started"), "zero progress looped into another batch")

        model.buildEmbeddings()
        try await waitForEmbeddingBatch(6)
        try signal("finish-embedding-6")
        try await until("model failure stopped with a local diagnosis") {
            model.indexWork == nil && model.embeddingNotice?.problem == .embeddings &&
                model.localModelState == .unavailable(.runtime)
        }
        try check(!exists("embedding-7-started"), "model failure queued another batch")

        model.buildEmbeddings()
        try await waitForEmbeddingBatch(7)
        model.scope.deny = [corpus.appendingPathComponent("Excluded").path]
        try check(model.embeddingState == .pausing, "editing scope did not stop future batches")
        try signal("finish-embedding-7")
        (try? FileManager.default.removeItem(at: directory.appendingPathComponent("gemma-pending")))
        try signal("update-watch")
        try await until("old scope batch drained") { model.indexWork == nil && model.embeddingState == .paused }
        try check(!exists("embedding-8-started"), "editing scope queued a batch for the old scope")
        try await until("document coverage settled after controlled batches") { model.gemmaCoverage?.complete == true }
        try check(model.watchState == .running && watchLaunches() == 1, "embedding generation restarted the watcher")
    }

    private func verifyExternalVolumes(_ app: AppDelegate) async throws {
        let model = app.model
        let catalog = app.externalVolumes
        try await until("the synthetic main index is available") { model.canSearch }
        guard let menu = app.statusMenu?.items.first(where: { $0.action == #selector(AppDelegate.showSettings) }),
              let action = menu.action
        else { throw Failure("settings menu item is missing") }
        try check(NSApp.sendAction(action, to: menu.target, from: menu), "Settings menu did not open")
        app.settingsSession.page = .index
        app.settings?.contentView?.layoutSubtreeIfNeeded()
        try await until("eligible volume was listed") { !catalog.refreshing && catalog.volumes.count == 1 }
        guard let offered = catalog.volumes.first else { throw Failure("eligible volume list was empty") }
        try check(offered.available && !offered.indexed && !offered.needs_refresh, "new volume was not opt-in")

        app.showSearch()
        try type("external-volume-fixture", into: app)
        try await until("unregistered volume remained hidden") { !model.searching }
        try check(model.hits.isEmpty, "unregistered external volume appeared")
        catalog.index(offered, changed: model.externalVolumesChanged)
        try await until("explicit volume index was applied") {
            catalog.editing == nil && catalog.volumes.first?.indexed == true &&
                model.hits.contains { $0.name == "external-volume-fixture.txt" }
        }

        try signal("volume-disconnected")
        app.externalVolumeStateChanged()
        try check(model.hits.isEmpty, "disconnected volume lingered in existing results")
        catalog.reload()
        try await until("disconnected snapshot was listed") {
            catalog.volumes.first?.available == false && catalog.volumes.first?.needs_refresh == true
        }
        guard let oldVolume = catalog.volumes.first else { throw Failure("saved unavailable volume was missing") }
        catalog.forget(oldVolume, changed: model.externalVolumesChanged)
        try await until("external index was removed") {
            catalog.editing == nil && !catalog.refreshing && catalog.volumes.isEmpty
        }
        try check(!catalog.failed && model.hits.isEmpty, "forget left external results behind")
    }

    private func waitForEmbeddingBatch(_ batch: Int) async throws {
        try await until("embedding batch \(batch) started") { self.exists("embedding-\(batch)-started") }
    }

    private func verifyModelResources(_ app: AppDelegate) async throws {
        let model = app.model
        try type("archive", into: app)
        try await until("name results visible without model resources") { model.selectedHit?.name == "archive-one.txt" }
        model.verifyLocalModel()
        try await until("missing local runtime diagnosed") { model.localModelState == .unavailable(.runtime) }
        let label = model.modelDiagnostic(.runtime)
        try check(label.contains("Gemma") && !label.contains("synthetic-account") && !label.contains("/Users/"),
                  "model diagnostic exposed a raw path or account")
        try check(model.selectedHit?.name == "archive-one.txt" && !exists("semantic-serve-launches"),
                  "missing model cleared lexical results or started the semantic backend")
        model.buildEmbeddings()
        try await until("missing resources prevented embedding") { model.localModelState == .unavailable(.runtime) }
        try check(!exists("embeddings-started"), "embedding ran without a verified model")

        try signal("gemma-unverified")
        model.verifyLocalModel()
        try await until("present but unverified model rejected") { model.localModelState == .unavailable(.verification) }
        try type("archive appears", into: app)
        try await until("full-text search still worked with an unverified model") { model.selectedHit?.matched_by == "text" }

        try signal("gemma-present")
        model.verifyLocalModel()
        try await until("Gemma verification held by fixture") { self.exists("model-check-started") }
        try type("archive", into: app)
        try await until("name search continued during model verification") {
            !model.searching && model.hits.prefix(2).map(\.name) == ["archive-one.txt", "archive-two.txt"]
        }
        let selected = model.selection
        try signal("finish-model-check")
        try await until("verified Gemma backend is ready") { model.localModelState == .ready }
        try check(!exists("semantic-serve-launches") && model.selection == selected,
                  "verification launched an unrelated semantic request or moved the selection")
    }

    private func verifyAppliedScope(_ app: AppDelegate) async throws {
        let model = app.model
        let excluded = corpus.appendingPathComponent("Excluded")
        try type("privateneedle", into: app)
        if !startsWithIndex {
            try await until("excluded target visible before applying scope") { model.selectedHit?.name == "privateneedle.txt" }
            model.scope.deny = [excluded.path]
            model.buildIndex()
            try check(model.scopePending && model.hits.isEmpty && model.selection == nil, "applying scope retained a visible result")
            try await until("narrowed scope committed and watch resumed") {
                !model.scopePending && model.indexWork == nil && model.watchState == .running
            }
        }
        try Data().write(to: excluded.appendingPathComponent("privateneedle-new.txt"))
        // A witness update in the same batch proves the resumed watcher is processing events.
        try Data().write(to: corpus.appendingPathComponent("privateneedle-witness.txt"))
        try await until("watch used persisted scope and hid denied items") {
            model.hits.map(\.name) == ["privateneedle-witness.txt"] && !model.searching
        }
        try FileManager.default.removeItem(at: corpus.appendingPathComponent("privateneedle-witness.txt"))
        try await until("watch still hid excluded paths after removing the witness") { model.hits.isEmpty && !model.searching }
    }

    private func verifyFailedScopeApply(_ app: AppDelegate) async throws {
        let model = app.model
        try signal("hold-scope-search")
        try type("privateneedle", into: app)
        try await until("old scope result visible with a follow-up query in flight") {
            model.selectedHit != nil && self.exists("scope-search-started")
        }
        opened = nil
        try signal("reject-scope")
        model.scope.deny = [corpus.appendingPathComponent("Excluded").path]
        model.buildIndex()
        try check(model.scopePending && !model.canSearch && model.hits.isEmpty && model.selection == nil,
                  "applying scope did not immediately block old results")
        try await until("scope application held before writing the database") { self.exists("scope-started") }
        try type("archive", into: app)
        try key(kVK_Return, "\r", in: app)
        try check(opened == nil && model.hits.isEmpty, "old scope opened a result during apply")
        try signal("finish-scope")
        try await until("failed application did not restart old watcher") {
            model.indexWork == nil && model.indexNotice?.problem == .indexing && model.watchState == .paused
        }
        try check(model.scopePending && !model.canSearch && watchLaunches() == 1,
                  "failed application resumed the previous scope")
    }

    private func verifyInterruptedScopeApply(_ app: AppDelegate) async throws {
        let model = app.model
        for name in ["reject-scope", "scope-started", "finish-scope"] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        model.buildIndex()
        try await until("an explicit retry applied the new scope") {
            !model.scopePending && model.watchState == .running && self.watchLaunches() == 2
        }
        try signal("reject-scope")
        model.scope.deny = [corpus.path]
        model.buildIndex()
        try await until("second apply held before commit for process termination") { self.exists("scope-started") }
        try check(model.scopePending && !model.canSearch && model.hits.isEmpty && model.selection == nil,
                  "interrupted apply left the previous results visible")
        // End the app with the scope writer still blocked, then the script reopens the same index.
    }

    private func verifyFailedScopeRelaunch(_ app: AppDelegate) async throws {
        let model = app.model
        try await until("pending scope restored across app launches") {
            model.indexPhase == .ready && model.watchState == .paused
        }
        try type("privateneedle", into: app)
        try check(model.scopePending && !model.canSearch && model.hits.isEmpty && model.selection == nil && watchLaunches() == 2,
                  "relaunch searched or launched a watcher with the previous scope")
    }

    private func watchLaunches() -> Int { lineCount("watch-launches") }

    private func lineCount(_ file: String) -> Int {
        let url = directory.appendingPathComponent(file)
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).count
    }

    private func verifyShortcut(_ app: AppDelegate) throws {
        let grave = try HotKey(event: event(kVK_ANSI_Grave, "`", in: app, flags: [.command]))
        try grave.checkSystemShortcut()
        try check(grave.cyclesMacWindows && grave.label == "⌘`", "single-modifier Command–grave was rejected")
        var symbolic: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&symbolic) == noErr,
              let bindings = symbolic?.takeRetainedValue() as? [[String: Any]] else {
            throw Failure("could not read the live system shortcut catalog")
        }
        let spaceChords = [cmdKey, cmdKey | optionKey, cmdKey | shiftKey, controlKey, controlKey | optionKey]
            .map { HotKey(code: UInt32(kVK_Space), modifiers: UInt32($0), key: "␣") }
        let voiceOver = try HotKey(event: event(kVK_ANSI_G, "G", in: app, flags: [.control, .option]))
        for chord in spaceChords + [voiceOver] {
            let enabled = bindings.contains { entry in
                (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true &&
                    (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value == chord.code &&
                    (entry["kHISymbolicHotKeyModifiers"] as? NSNumber).map { $0.uint32Value & HotKey.mask } == chord.modifiers
            }
            var reserved = false
            do { try chord.checkSystemShortcut() }
            catch HotKeyIssue.system { reserved = true }
            try check(reserved == enabled, "\(chord.label) conflict did not match the system shortcut catalog")
        }
        app.recordShortcut(try event(kVK_ANSI_Comma, ",", in: app, flags: [.command]))
        guard case .app? = app.model.hotKeyIssue else { throw Failure("Command–comma did not retain the Settings binding") }

        // Reserve two test chords only for this synchronous check. No key is sent to the OS.
        let flags: NSEvent.ModifierFlags = [.command, .control, .shift]
        let modifiers = UInt32(cmdKey | controlKey | shiftKey)
        let available = try event(kVK_ANSI_Z, "Z", in: app, flags: flags)
        app.recordShortcut(available)
        guard let working = app.model.hotKey, var identifier = app.globalHotKey.identifier
        else { throw Failure("cannot register isolated hotkey fixture: \(String(describing: app.model.hotKeyIssue))") }
        defer { app.disableShortcut() }

        var occupied: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_X), modifiers, EventHotKeyID(signature: 0x54657374, id: 1),
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &occupied)
        try check(status == noErr && occupied != nil, "cannot reserve conflict fixture (\(status))")
        defer { if let occupied { UnregisterEventHotKey(occupied) } }
        app.recordShortcut(try event(kVK_ANSI_X, "X", in: app, flags: flags))
        guard case .occupied? = app.model.hotKeyIssue else {
            throw Failure("occupied chord was not diagnosed (\(String(describing: app.model.hotKeyIssue)))")
        }
        try check(app.model.hotKey == working, "failed registration removed a working shortcut")

        var carbon: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), 0, &carbon)
        guard created == noErr, let carbon else { throw Failure("cannot create app-local Carbon notification") }
        defer { ReleaseEvent(carbon) }
        try check(SetEventParameter(carbon, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    MemoryLayout<EventHotKeyID>.size, &identifier) == noErr, "cannot set Carbon hotkey ID")
        try check(SendEventToEventTarget(carbon, GetApplicationEventTarget()) == noErr, "Carbon hotkey handler did not accept the event")
        _ = try editor(app)
        try type("archive", into: app)
        // Become key without ordering the test panel or activating the app.
        app.panel.becomeKey()
        try check(app.panel.isKeyWindow, "could not simulate a focused search panel")
        try check(SendEventToEventTarget(carbon, GetApplicationEventTarget()) == noErr &&
                  !app.searchPresented && app.model.query.isEmpty,
                  "the repeat hotkey did not dismiss and reset the key search panel")
        if app.panel.isKeyWindow { app.panel.resignKey() }
        try check(SendEventToEventTarget(carbon, GetApplicationEventTarget()) == noErr && app.searchPresented,
                  "a missing release event suppressed the next shortcut")
    }

    private func click(count: Int, at point: NSPoint, in window: NSWindow) throws {
        // Hit-test the live row, then deliver AppKit events to that responder. The
        // app-local event does not depend on desktop focus or the global mouse queue.
        guard let target = window.contentView?.hitTest(point) as? ActionRowClickTarget else {
            throw Failure("the fixture row was not hit-testable")
        }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: count,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else {
                throw Failure("cannot make in-process mouse event")
            }
            if type == .leftMouseDown { target.mouseDown(with: event) }
            else { target.mouseUp(with: event) }
        }
    }

    private func type(_ text: String, into app: AppDelegate) throws {
        let editor = try editor(app)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func key(_ code: Int, _ character: String, in app: AppDelegate, throughPanel: Bool = false,
                     flags: NSEvent.ModifierFlags = []) throws {
        let event = try event(code, character, in: app, flags: flags)
        if throughPanel { app.panel.sendEvent(event) }
        else { try editor(app).keyDown(with: event) }
    }

    private func event(_ code: Int, _ character: String, in app: AppDelegate, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: app.panel.windowNumber, context: nil, characters: character,
                                           charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(code))
        else { throw Failure("cannot make in-process key event") }
        return event
    }

    private func editor(_ app: AppDelegate) throws -> NSTextView {
        guard let editor = app.searchField.currentEditor() as? NSTextView, app.panel.firstResponder === editor
        else { throw Failure("search field is not the first responder") }
        return editor
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    private func signal(_ name: String) throws {
        try Data().write(to: directory.appendingPathComponent(name))
    }

    private func until(_ message: String, seconds: Int = 6, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(condition(), message)
    }

    private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

private final class SmokeTranslationSecrets: TranslationSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: (endpoint: TranslationEndpoint, key: String)] = [:]

    func key(provider: UUID, endpoint: TranslationEndpoint) -> String? {
        lock.withLock {
            guard let saved = values[provider], saved.endpoint == endpoint else { return nil }
            return saved.key
        }
    }

    func save(_ key: String, provider: UUID, endpoint: TranslationEndpoint) {
        lock.withLock { values[provider] = (endpoint, key) }
    }

    func remove(provider: UUID) {
        lock.withLock { _ = values.removeValue(forKey: provider) }
    }
}
