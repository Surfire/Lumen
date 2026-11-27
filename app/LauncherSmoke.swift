#if LUMEN_SMOKE
import AppKit
import Carbon
import Combine
import Darwin
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
    var chosenScriptsFolder: URL?
    var chosenSettingsDirectories: [URL]?
    var automaticIndexScenario: Bool { exists("automatic-index-scenario") }
    var chosenDiagnosticFile: URL?
    var chosenImageFolder: URL?
    var chosenImageProjector: URL?
    var definitionProvider: (@Sendable (String) -> String?)?
    private var previewDownloadRelease: AsyncStream<Void>.Continuation?
    private var previewDownloadsStarted = 0
    private var previewDownloadsCancelled = 0
    nonisolated private static func previewHydrated(_ url: URL, in directory: URL) -> URL {
        directory.appendingPathComponent("preview-hydrated-" + url.lastPathComponent)
    }

    var previewDownloads: LauncherInlinePreview.DownloadProvider? {
        guard exists("content-scenario") else { return nil }
        let directory = directory
        return .init(isPending: { url in
            ["cloud-preview-placeholder.png", "cloud-quick-look-placeholder.txt"].contains(url.lastPathComponent) &&
            !FileManager.default.fileExists(atPath: Self.previewHydrated(url, in: directory).path)
        }, download: { [weak self] url, report in
            guard let self else { throw CancellationError() }
            try await self.hydratePreviewFixture(url, report: report)
        })
    }

    private func hydratePreviewFixture(_ url: URL, report: InlinePreviewCoordinator.DownloadProgress) async throws {
        let (stream, release) = AsyncStream<Void>.makeStream()
        previewDownloadRelease = release
        previewDownloadsStarted += 1
        defer {
            previewDownloadRelease = nil
            if Task.isCancelled { previewDownloadsCancelled += 1 }
        }
        report(0.4)
        for await _ in stream {
            try Task.checkCancellation()
            let bytes: Data
            if url.pathExtension == "png" {
                bytes = try Data(contentsOf: corpus.appendingPathComponent("Dropbox/cloud-preview-known.png"))
            } else {
                bytes = Data("Hydrated Quick Look text fixture.".utf8)
            }
            try bytes.write(to: url)
            try Data().write(to: Self.previewHydrated(url, in: directory))
            return
        }
        throw CancellationError()
    }

    private var frontmostWindowPID: pid_t? = 42_001
    private let windowAdapter = SmokeWindowAccess()
    private var openedAccessibilitySettings: [URL] = []

    func makeWindowManagement() -> WindowManagement {
        WindowManagement(adapter: windowAdapter, frontmostPID: { [weak self] in self?.frontmostWindowPID },
                         layout: { Self.windowPlanner }, openSettings: { [weak self] in self?.openedAccessibilitySettings.append($0) })
    }

    private lazy var translationSuite = "io.github.surfire.lumen.gui-smoke.\(UUID())"
    private lazy var translationPreferences = UserDefaults(suiteName: translationSuite)
    private let translationSecrets = SmokeTranslationSecrets()
    var shortcutFixturePreferences: UserDefaults? { exists("quicklinks-scenario") ? translationPreferences : nil }

    func makeScriptCatalog() -> LauncherScriptCatalog {
        LauncherScriptCatalog(defaults: translationPreferences, shortcutsExecutable: directory.appendingPathComponent("shortcuts-fixture"))
    }

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

    static func runUpdaterIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--updater-smoke" else { return }
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard (2...3).contains(args.count), args.count == 2 || args[2] == "fail-after-swap",
              bundle.path.hasPrefix(temp + "/"), bundle.lastPathComponent == "Lumen.app",
              bundle.deletingLastPathComponent().lastPathComponent == "Applications",
              let feed = URL(string: args[1]) else {
            fputs("Updater smoke requires an isolated temporary Applications/Lumen.app and loopback feed.\n", stderr)
            exit(2)
        }
        Task {
            do {
                let production = UpdateTransport(loopbackOnly: false)
                let smoke = UpdateTransport(loopbackOnly: true)
                guard production.allows(URL(string: "https://github.com/")!),
                      !production.allows(URL(string: "http://github.com/")!),
                      !production.allows(URL(string: "http://127.0.0.1/")!),
                      smoke.allows(feed), !smoke.allows(URL(string: "https://github.com/")!) else {
                    throw Failure("Incorrect updater URL policy")
                }
                let updater = LauncherUpdater(smokeFeed: feed)
                if let release = try await updater.check() {
                    let backup = try await updater.install(release, smokeFailAfterSwap: args.count == 3)
                    print("Installed \(release.version) (build \(release.build)); backup: \(backup.path)")
                } else { print("No newer release") }
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
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
        let scanObservation = model.indexStatus.$scanProgress.compactMap { $0 }.sink { observedScan.append($0) }
        let watchObservation = model.indexStatus.$watchProgress.compactMap { $0 }.sink { observedWatch.append($0) }
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
        try check(app.panel.alphaValue == 1 && !app.panel.isVisible, "smoke presentation ordered in or faded the panel")
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
            try verifyWindowGeometry()
            try verifyWindowAccess()
            try await verifyWindowActions(app)
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
                try check(app.searchPresented && model.query.isEmpty && model.isIndexing,
                          "First Escape on a non-empty query did not clear the query in place")
                try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
                try check(!app.searchPresented && model.isIndexing, "Second Escape canceled background indexing or failed to dismiss")
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
        try check(model.query.isEmpty && model.hits.isEmpty && app.searchPresented,
                  "First Escape did not clear the non-empty query while keeping the panel open")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.searchPresented && model.query.isEmpty && model.hits.isEmpty && app.searchField.currentEditor() == nil,
                  "Second Escape did not dismiss the panel and reset the editor")
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
        try await until("Delete did not remove the selected image from clipboard rows") {
            !app.commands.clipboardRows.contains { $0.id == clip.id }
        }
        try check(try store.image(id: clip.id) == nil, "Delete did not remove the selected image from storage")

        try store.clearUnpinned()
        try check(try store.items().map(\.id) == [pinned.id], "clearUnpinned deleted a pin or retained a recent clip")
        try writeImage()
        let inFlightImage = history.poll()
        history.clearAll()
        await inFlightImage?.value
        try await until("Clear All did not clear clipboard rows") {
            history.items.isEmpty && app.commands.clipboardRows.isEmpty
        }
        try check(try ClipboardStore(directory: store.directory).items().isEmpty,
                  "Clear All did not remove pins and persisted history")
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
        try check(ClipboardItem.filtered(items, for: "fíxture editor").count == 500,
                  "clipboard search did not fold metadata")
        try check(ClipboardItem.filtered(items, for: "tail hit").count == 500 && items.first?.text == text,
                  "clipboard search did not index and preserve the full payload")
        let longFuzzyQuery = String(repeating: "a", count: 32) + "h"
        try check(ClipboardItem.filtered(items, for: longFuzzyQuery).count == 500,
                  "clipboard search missed a 33-scalar fuzzy match")

        let rankedItems = [
            ClipboardItem(id: 1, text: "界 / 🙂", capturedAt: .now, sourceBundleID: nil, sourceAppName: nil, pinned: false),
            ClipboardItem(id: 2, text: "界 / 🙂", capturedAt: .now, sourceBundleID: nil, sourceAppName: "界🙂 Editor", pinned: false),
        ]
        try check(ClipboardItem.filtered(rankedItems, for: "界🙂").map(\.id) == [2, 1],
                  "a literal app name match did not outrank a fuzzy text match")

        let clock = ContinuousClock()
        func verifyLatency(_ items: [ClipboardItem], query: String, label: String, expectedCount: Int) throws {
            let samples = try (0..<20).map { _ in
                let start = clock.now
                let rows = ClipboardItem.filtered(items, for: query)
                let elapsed = start.duration(to: clock.now)
                try check(rows.count == expectedCount,
                          "500-item clipboard search (\(label)) returned \(rows.count) matches, expected \(expectedCount)")
                return elapsed
            }.sorted()
            let p95 = samples[18]
            try check(p95 < .milliseconds(15), "500-item clipboard search (\(label)) exceeded 15 ms (p95: \(p95))")
            print("500-item clipboard search (\(label)): p95 \(p95)")
        }
        func nearCapItems(afterID: String = "", repeating pattern: String = "a", suffix: String = "") -> [ClipboardItem] {
            (0..<500).map { id in
                let prefix = "\(id)\(afterID)"
                let budget = ClipboardStore.maximumTextBytes - prefix.utf8.count - suffix.utf8.count
                let width = pattern.utf8.count // These fixtures are ASCII, so characters and bytes coincide.
                let padding = String(repeating: pattern, count: (budget + width - 1) / width).prefix(budget)
                return ClipboardItem(id: Int64(id), text: prefix + padding + suffix, capturedAt: .now,
                                     sourceBundleID: nil, sourceAppName: nil, pinned: false)
            }
        }
        func verifyFuzzyLatency(_ items: [ClipboardItem], query: String, label: String) throws {
            // A literal appended after the fixture must outrank every fuzzy match.
            let literal = ClipboardItem(id: -1, text: query, capturedAt: .now, sourceBundleID: nil,
                                        sourceAppName: nil, pinned: false)
            try check(ClipboardItem.filtered(items + [literal], for: query).map(\.id) == [literal.id] + items.map(\.id),
                      "500-item clipboard search (\(label)) did not return only fuzzy matches in order")
            try verifyLatency(items, query: query, label: label, expectedCount: 500)
        }

        let periodicQuery = String(repeating: "a", count: 31) + "z"
        try verifyLatency(items, query: periodicQuery, label: "absent character", expectedCount: 0)
        // All bytes are present, but the first 't' is near the end with no 'a' after it.
        try verifyLatency(items, query: "t" + String(repeating: "a", count: 32), label: "all bytes present", expectedCount: 0)
        try verifyLatency(nearCapItems(afterID: "z"), query: periodicQuery, label: "reverse late mismatch", expectedCount: 0)
        try verifyLatency(nearCapItems(suffix: "xz"), query: periodicQuery, label: "fuzzy hit without substring", expectedCount: 500)
        try verifyFuzzyLatency(nearCapItems(repeating: "az"), query: periodicQuery, label: "Astra dense anchor")

        let ys = String(repeating: "y", count: 14)
        let xs = String(repeating: "x", count: 14)
        let collisionQuery = "aa" + ys + "a" + ys + "z"
        let collisionBlock = "aa" + xs + "a" + xs + "z"
        // Every block passes the four probes but fails the full comparison. The suffix supplies
        // the ordered y runs for fuzzy matching, with x preventing a literal across the boundary.
        let collisionItems = nearCapItems(afterID: ys + ys, repeating: collisionBlock, suffix: "x" + ys + "a" + ys + "z")
        try verifyFuzzyLatency(collisionItems, query: collisionQuery, label: "four-point collision (KMP fallback)")
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
        try verifyHighlights()
        try await verifyCatalogRegressions()
        try await verifyEngineRegressions()
        try await verifyBackgroundEmbeddingInterleavesContent()
        try await verifyPhase1Regressions()
        try await verifyPhase2Regressions(app)
        try await verifyPhase3Regressions(app)
        try check(model.indexPhase == .needsIndex && !model.canSearch, "action smoke unexpectedly had a file index")
        func chosen() -> LaunchAction? {
            if case .action(let action)? = model.selectedResult { return action }
            return nil
        }

        // All typed text passes through the real AppKit field editor.
        let top = app.panel.frame.maxY
        try type("lumen action probe", into: app)
        try await until("a discovered application is selectable before any file index exists") {
            let expected = PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
            return chosen()?.english == "Lumen Action Probe" && app.panel.frame.size == expected
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
        try await verifyLocalExecutables(app)

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
                try await until("the setting row is laid out offscreen") {
                    app.panel.frame.size == PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
                }
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
        try await until("app and direct file rows painted category labels at the trailing edge") {
            let widths = self.categoryInkWidths(in: app.panel, rowHeights: [44, 44])
            return widths.count == 2 && widths.allSatisfy { $0 > 18 }
        }
        app.panel.appearance = nil
        if exists("capture-icons") {
            try capture("lumen-mixed-light.png", appearance: .aqua, window: app.panel)
            try capture("lumen-mixed-dark.png", appearance: .darkAqua, window: app.panel)
            app.panel.appearance = nil
        }
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
        guard let preview = app.localPreview, let url = preview.previewURL else { throw Failure("Quick Look had no item") }
        let previewContents = try String(contentsOf: url, encoding: .utf8)
        try check(url.path == expected.path && previewContents == "Synthetic unified search fixture." &&
                  !preview.isVisible && !NSApp.isActive, "Quick Look did not use the original file offscreen")
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try check(app.localPreview == nil && preview.previewURL == nil && app.searchPresented &&
                  FileManager.default.fileExists(atPath: expected.path),
                  "Command–Y did not release the Quick Look item while leaving search and the original intact")
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
        let residentCloud = dragHit(availability: "provider_metadata_only")
        let placeholderCloud = dragHit(availability: "placeholder")
        try check(LocalFile.dragURL(for: resident)?.path == residentPath &&
                  LocalFile.dragURL(for: residentCloud)?.path == residentPath &&
                  LocalFile.dragURL(for: placeholderCloud) == nil,
                  "drag eligibility did not allow resident cloud files while blocking placeholders")
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
            ("mute", .mute), ("quxiaojingyin", .unmute), ("eject", .eject),
        ]
        for (term, operation) in operations {
            app.showSearch()
            try type(term, into: app)
            guard chosen()?.destination == .system(operation) else { throw Failure("System action not found: \(term)") }
            try key(kVK_Return, "\r", in: app)
            try check(dispatchedActions.last == .system(operation), "System action did not route: \(term)")
        }
        definitionProvider = { word in word == "macintosh" ? definition : nil }
        defer { definitionProvider = nil }
        app.showSearch()
        try type("define macintosh", into: app)
        guard chosen()?.destination == .system(.define("macintosh")) else {
            throw Failure("System action not found: define macintosh")
        }
        try key(kVK_Return, "\r", in: app)
        try await until("inline dictionary card did not load definition") {
            app.panelState.mode == .definition(word: "macintosh", text: definition, loading: false)
                && app.searchPresented && app.panel.frame.height == PanelGeometry.headerHeight + PanelGeometry.footerHeight + 220
        }
        try key(kVK_Return, "\r", in: app)
        try check(app.commands.definitionCopied && filePasteboard.string(forType: .string) == definition && app.searchPresented,
                  "Return on inline definition card did not copy in place")
        try verifyInternalCopy(app, "Copy Dictionary Definition")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(app.commands.definition == nil && app.panelState.mode == .search && app.searchPresented &&
                  model.query == "define macintosh",
                  "Escape on inline definition card did not close card while keeping query")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(app.searchPresented && model.query.isEmpty, "Second Escape did not clear query in place")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.searchPresented, "Third Escape on empty query did not dismiss search")
        if let defaults = shortcutFixturePreferences {
            try check(LauncherFrecency(defaults: defaults).boost("system:lock") > 0,
                      "a completed system action was not saved to the shared frecency store")
        }
        app.showSearch()
        try await verifyPhase2LiveFileInteractions(app)

        if exists("syntax-scenario") { try await verifyRawFileQuery(app) }
        if let fixtures = frecencyFixtures {
            try await verifyFileFrecency(app, project: fixtures.project, success: fixtures.success, failure: fixtures.failure)
            app.showSearch()
            try await verifyQuicklinks(app)
        }
        print("Unified actions passed: real background app launch, routed Settings URLs, isolated file copies, and native local Quick Look input")
    }

    private func verifyLocalExecutables(_ app: AppDelegate) async throws {
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("Local Scripts", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        func fixture(_ url: URL, _ script: String, mode: Int = 0o700) throws {
            try Data(script.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        let echo = folder.appendingPathComponent("echo argument")
        try fixture(echo, #"""
        #!/bin/sh
        # @lumen.title = Lumen Argv Probe
        # @lumen.alias argvliteral
        # @lumen.description metadata probe description
        # @lumen.mode fullOutput
        # @lumen.argument1 Exact text
        printf '%s\n%s\n%s' "$#" "$1" "$0"
        """#)
        let flood = folder.appendingPathComponent("flood")
        try fixture(flood, """
        #!/bin/sh
        # @lumen.title Lumen Output Flood
        # @lumen.mode inline
        /usr/bin/head -c 65537 /dev/zero
        /usr/bin/head -c 65538 /dev/zero >&2
        exit 7
        """)
        let silent = folder.appendingPathComponent("silent")
        try fixture(silent, #"""
        #!/bin/sh
        # @lumen.title Lumen Silent Probe
        # @lumen.mode silent
        # @lumen.argument1 Silent argument
        printf '%s' "$1" > silent-ran
        """#)
        for (name, title, mode) in [("group", "Lumen Group Probe", "fullOutput"),
                                    ("silent-group", "Lumen Silent Group Probe", "silent")] {
            try fixture(folder.appendingPathComponent(name), #"""
            #!/bin/sh
            # @lumen.title \#(title)
            # @lumen.mode \#(mode)
            trap '' TERM
            /bin/sleep 120 &
            printf '%s %s\n' "$$" "$!" > group-starting
            /bin/mv group-starting group-ready
            wait
            """#)
        }
        try fixture(nested.appendingPathComponent("nested"), "#!/bin/sh\nexit 0")
        try fixture(folder.appendingPathComponent("not executable"), "#!/bin/sh\nexit 0", mode: 0o644)
        let external = directory.appendingPathComponent("outside script")
        try fixture(external, "#!/bin/sh\n# @lumen.title Lumen Outside Symlink Target\nexit 0")
        try fm.createSymbolicLink(at: folder.appendingPathComponent("symlink"), withDestinationURL: external)
        let folderLink = directory.appendingPathComponent("folder link", isDirectory: true)
        try fm.createSymbolicLink(at: folderLink, withDestinationURL: folder)
        try check(mkfifo(folder.appendingPathComponent("fifo").path, 0o700) == 0, "could not create FIFO fixture")
        var flags = stat()
        flags.st_flags = UInt32(SF_DATALESS)
        try check(!LauncherScriptFiles.isResident(flags), "a simulated SF_DATALESS file passed the resident gate")
        try check(LauncherScriptFiles.scan(IndexScope.folderPath(folderLink)) == nil, "symlink folder was scanned")

        let source = LauncherExecutable.Source.shortcut("parser fixture")
        let prefix = Data([0xef, 0xbb, 0xbf]) + Data("// @lumen.title = Snow 猫\r\n# @lumen.alias snowy\r".utf8)
            + Data([0x80, 0, 10]) + Data(("# @lumen.description " + String(repeating: "X", count: 1300)
            + "\n# @lumen.mode = fullOutput\r\n# @lumen.argument1 = Path or text").utf8)
        let parsed = LauncherExecutable.parse(prefix, eof: true, source: source, fallback: "fallback")
        try check(parsed.title == "Snow 猫" && parsed.alias == "snowy" && parsed.mode == .fullOutput &&
                  parsed.argument == "Path or text" && parsed.description.isEmpty,
                  "BOM/CRLF, binary, or oversize metadata parsed incorrectly: \(parsed)")
        let missing = LauncherExecutable.parse(Data("# @lumen.title\r\n# @lumen.mode bogus\n# @lumen.argument1 =\n".utf8),
                                               eof: true, source: source, fallback: "fallback")
        let overLimit = Data((String(repeating: "\n", count: LauncherScriptFiles.headerLimit - 20)
                             + "# @lumen.title truncated-title\n# @lumen.mode silent\n").utf8)
        let clipped = LauncherExecutable.parse(overLimit, eof: true, source: source, fallback: "clipped")
        try check(missing.title == "fallback" && missing.mode == .compact && missing.argument == nil &&
                  clipped.title == "clipped" && clipped.mode == .compact, "missing or truncated headers changed defaults")

        let catalog = app.scriptCatalog
        let shortcutName = "--Lumen Shortcuts Probe ; $(echo altered)"
        let stub = catalog.shortcutsExecutable
        try fixture(stub, #"""
        #!/bin/sh
        case "$1" in
          list)
            printf 'list\n' >> "${0%/*}/shortcuts-calls"
            printf '%s\r\n%s\n\n%s\n' '--Lumen Shortcuts Probe ; $(echo altered)' '  Exact Spacing  ' '--Lumen Shortcuts Probe ; $(echo altered)'
            ;;
          run)
            printf 'run\n' >> "${0%/*}/shortcuts-calls"
            shift
            case "$1" in
              --input-path=*)
                printf '%s\n' "${1#--input-path=}"
                /bin/cat "${1#--input-path=}" || exit 6
                shift
                ;;
            esac
            [ "$#" = 2 ] && [ "$1" = '--' ] || exit 4
            printf '<%s>' "$2"
            ;;
          *) exit 5 ;;
        esac
        """#)
        func command(_ title: String) throws -> LauncherExecutable {
            guard let command = (catalog.scripts + catalog.shortcuts).first(where: { $0.title == title }) else {
                throw Failure("missing command: \(title)")
            }
            return command
        }
        func finished() -> LauncherProcess.Result? {
            if case .finished(let result)? = app.commands.execution?.phase { return result }
            return nil
        }
        try check(!catalog.scriptsEnabled && !catalog.shortcutsEnabled && !exists("shortcuts-calls"), "commands were not opt-in")
        app.showSettings()
        app.settingsSession.page = .scripts
        chosenScriptsFolder = folder
        app.chooseScriptsFolder()
        let folderPath = IndexScope.folderPath(folder)
        try check(catalog.folder == folderPath && !catalog.scriptsEnabled && catalog.scripts.isEmpty,
                  "choosing a folder opted in or scanned before enable: \(catalog.folder ?? "nil") vs \(folderPath)")
        catalog.setScriptsEnabled(true)
        catalog.setShortcutsEnabled(true)
        try await until("opt-in catalogs loaded") { !catalog.scriptLoading && !catalog.shortcutLoading }
        try check(Set(catalog.scripts.map(\.title)) == ["Lumen Argv Probe", "Lumen Output Flood", "Lumen Silent Probe",
                                                       "Lumen Group Probe", "Lumen Silent Group Probe"],
                  "scan missed a safe executable or followed a link, nested path, FIFO, or non-executable")
        try check(catalog.shortcuts.map(\.title) == [shortcutName, "  Exact Spacing  "] && lineCount("shortcuts-calls") == 1,
                  "Shortcuts parsing lost exact spelling or ran before explicit enable")
        let restored = makeScriptCatalog()
        try check(restored.scriptsEnabled && restored.folder == folderPath && restored.shortcutsEnabled &&
                  restored.shortcuts.isEmpty && !restored.shortcutLoading, "settings failed to persist or cold startup listed Shortcuts")
        app.settings?.close()
        app.showSearch()
        try type("metadata probe description", into: app)
        let selected = app.commands.selectedResult(in: app.model)
        try check(selected?.id == (try command("Lumen Argv Probe")).action.id, "description did not select the script result")
        try type("argvliteral", into: app)
        try key(kVK_Return, "\r", in: app)
        if case .argument("Exact text", required: false)? = app.commands.visibleExecution?.phase {} else {
            throw Failure("Return did not open the script argument card")
        }
        let literal = "some spaced 'text'; $(/usr/bin/touch injected) & 🐈"
        app.commands.executionArgument = literal
        try key(kVK_Return, "\r", in: app)
        try await until("argv probe finished") { finished() != nil }
        let expected = "1\n\(literal)\n\(IndexScope.folderPath(echo))"
        try check(finished()?.succeeded == true && finished()?.stdout.text == expected &&
                  !fm.fileExists(atPath: folder.appendingPathComponent("injected").path),
                  "script argument was split or expanded, or $0 was not the real script path")
        try key(kVK_Return, "\r", in: app)
        try check(filePasteboard.string(forType: .string) == expected && app.searchPresented,
                  "command output copy did not use the in-place card")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(app.commands.visibleExecution == nil && app.searchPresented, "Esc did not close the output card")

        try type("Lumen Output Flood", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("flood finished") { finished() != nil }
        guard let output = finished() else { throw Failure("missing command result") }
        try check(output.status == .exited(7) && [output.stdout, output.stderr].allSatisfy {
            $0.bytes.count == 65_536 && $0.truncated && $0.text.hasSuffix(LauncherProcess.truncationMarker)
        }, "stdout/stderr were not independently capped and marked")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)

        try type(shortcutName, into: app)
        try check(lineCount("shortcuts-calls") == 1, "typing started a Shortcuts CLI")
        try key(kVK_Return, "\r", in: app)
        try await until("stubbed Shortcut completed") { finished() != nil }
        try check(finished()?.succeeded == true && finished()?.stdout.text == "<\(shortcutName)>" && lineCount("shortcuts-calls") == 2,
                  "Shortcut run changed the name or interpreted it as an option")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        let input = directory.appendingPathComponent("input ; file.txt")
        try Data("input bytes!".utf8).write(to: input)
        let withInput = await LauncherProcess.execute(try command(shortcutName), argument: input.path, shortcuts: stub)
        try check(withInput.succeeded && withInput.stdout.text == "\(IndexScope.folderPath(input))\ninput bytes!<\(shortcutName)>",
                  "Shortcut argv did not carry the original input path")
        catalog.refreshShortcuts()
        try await until("explicit Shortcut refresh completed") { !catalog.shortcutLoading && self.lineCount("shortcuts-calls") == 4 }

        let ready = folder.appendingPathComponent("group-ready")
        func pids() throws -> [pid_t] {
            let values = try String(contentsOf: ready, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            try check(values.count == 2 && values.allSatisfy { $0 > 0 } && getpgid(values[0]) == values[0] && getpgid(values[1]) == values[0],
                      "child and descendant did not have their own shared process group")
            return values
        }
        func gone(_ pids: [pid_t]) -> Bool { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
        try type("Lumen Group Probe", into: app)
        try key(kVK_Return, "\r", in: app)
        try await until("script spawned a descendant") { fm.fileExists(atPath: ready.path) }
        let cancelled = try pids()
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try await until("Esc killed both members of the process group") { gone(cancelled) && app.commands.canStartExecutable }
        try check(app.searchPresented && app.commands.execution == nil, "cancelled script left an output card behind")
        try fm.removeItem(at: ready)

        let start = ContinuousClock.now
        try key(kVK_Return, "\r", in: app)
        try await until("timeout fixture started") { fm.fileExists(atPath: ready.path) }
        let expired = try pids()
        try await until("15-second execution timeout killed the process group", seconds: 18) { finished()?.status == .timedOut && gone(expired) }
        try check(start.duration(to: .now) >= .seconds(14) && start.duration(to: .now) < .seconds(18),
                  "script did not use the bounded production deadline")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try type("Lumen Silent Probe", into: app)
        try key(kVK_Return, "\r", in: app)
        if case .argument("Silent argument", required: false)? = app.commands.visibleExecution?.phase {} else {
            throw Failure("silent mode hid its argument prompt before running")
        }
        app.commands.executionArgument = literal
        try key(kVK_Return, "\r", in: app)
        try check(!app.searchPresented && app.commands.visibleExecution == nil, "silent mode left the search panel up")
        try await until("silent mode completed using the chosen working folder") {
            finished()?.succeeded == true && (try? String(contentsOf: folder.appendingPathComponent("silent-ran"), encoding: .utf8)) == literal
        }

        try fm.removeItem(at: ready)
        app.showSearch()
        try type("Lumen Silent Group Probe", into: app)
        try key(kVK_Return, "\r", in: app)
        try check(!app.searchPresented && app.commands.execution?.running == true, "silent group did not dismiss the launcher and run")
        try await until("silent script spawned a descendant") { fm.fileExists(atPath: ready.path) }
        let silentPIDs = try pids()
        app.showSearch()
        try check(app.searchPresented && app.commands.visibleExecution == nil && app.commands.execution?.running == true &&
                  app.panelState.mode == .search,
                  "reopening the launcher did not keep the silent script running in the background")
        try type("Lumen Silent Group Probe", into: app)
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(app.searchPresented && app.model.query.isEmpty && app.commands.execution?.running == true && !gone(silentPIDs),
                  "silent background script hijacked Escape instead of clearing the query")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.searchPresented && app.commands.execution?.running == true && !gone(silentPIDs),
                  "silent background script hijacked Escape on empty query")
        app.commands.cancelExecution()
        try await until("explicit cancellation did not kill both silent process-group members") {
            gone(silentPIDs) && app.commands.canStartExecutable && app.commands.execution == nil
        }
        catalog.setScriptsEnabled(false)
        catalog.setShortcutsEnabled(false)
        let disabled = makeScriptCatalog()
        try check(catalog.scripts.isEmpty && catalog.shortcuts.isEmpty && !disabled.scriptsEnabled && !disabled.shortcutsEnabled,
                  "disable did not retire cached actions or persist")
        app.settingsSession.page = .general
        print("Local Scripts & Apple Shortcuts passed (opt-in, no-follow, argv, output, process groups and timeout)")
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

    private static let windowPlanner = WindowLayoutPlanner(displays: [
        // The primary has a Dock at the bottom and a menu bar/notch above the visible area.
        .init(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
              visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 822)),
        .init(frame: CGRect(x: -1280, y: 0, width: 1280, height: 1024),
              visibleFrame: CGRect(x: -1250, y: 0, width: 1250, height: 1000)),
        .init(frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
              visibleFrame: CGRect(x: 0, y: 930, width: 1920, height: 1026)),
        .init(frame: CGRect(x: -300, y: -800, width: 1280, height: 800),
              visibleFrame: CGRect(x: -300, y: -780, width: 1280, height: 750)),
    ])

    private static let spanningWindowFrame = CGRect(x: -450, y: 200, width: 600, height: 400)
    private static let maximizedSpanningFrame = CGRect(x: -1250, y: -100, width: 1250, height: 1000)

    private func verifyWindowGeometry() throws {
        let planner = Self.windowPlanner
        let roundTrips: [(CGRect, CGRect)] = [
            (CGRect(x: 0, y: 40, width: 1440, height: 822), CGRect(x: 0, y: 38, width: 1440, height: 822)),
            (CGRect(x: -1200, y: 720, width: 640, height: 240), CGRect(x: -1200, y: -60, width: 640, height: 240)),
            (CGRect(x: 88, y: 1600, width: 800, height: 300), CGRect(x: 88, y: -1000, width: 800, height: 300)),
            (CGRect(x: -260, y: -760, width: 500, height: 400), CGRect(x: -260, y: 1260, width: 500, height: 400)),
        ]
        for (appKit, ax) in roundTrips {
            try check(planner.axFrame(appKit) == ax && planner.appKitFrame(ax) == appKit,
                      "AX coordinates did not reflect the far edge around the primary display top")
        }
        let original = CGRect(x: 120, y: 400, width: 600, height: 400)
        let layouts: [(WindowCommand, CGRect)] = [
            (.leftHalf, CGRect(x: 0, y: 38, width: 720, height: 822)),
            (.rightHalf, CGRect(x: 720, y: 38, width: 720, height: 822)),
            (.topHalf, CGRect(x: 0, y: 38, width: 1440, height: 411)),
            (.bottomHalf, CGRect(x: 0, y: 449, width: 1440, height: 411)),
            (.maximize, CGRect(x: 0, y: 38, width: 1440, height: 822)),
            (.center, CGRect(x: 420, y: 249, width: 600, height: 400)),
            (.almostMaximize, CGRect(x: 72, y: 79, width: 1296, height: 739)),
            (.reasonableSize, CGRect(x: 240, y: 175, width: 960, height: 548)),
        ]
        for (command, frame) in layouts {
            try check(planner.placement(for: command, currentAX: original)?.frame == frame,
                      "incorrect \(command) frame or visibleFrame inset")
        }
        let corner = CGRect(x: 840, y: 38, width: 600, height: 400)
        let left = CGRect(x: -600, y: -100, width: 600, height: 400)
        let below = CGRect(x: 380, y: 930, width: 600, height: 400)
        let above = CGRect(x: 1320, y: -1056, width: 600, height: 400)
        try check(planner.placement(for: .nextDisplay, currentAX: corner)?.frame == left &&
                  planner.placement(for: .nextDisplay, currentAX: left)?.frame == above &&
                  planner.placement(for: .previousDisplay, currentAX: corner)?.frame == below &&
                  planner.placement(for: .nextDisplay, currentAX: below)?.frame == corner,
                  "display cycling did not preserve point size and relative placement across insets")
        try check(planner.placement(for: .maximize, currentAX: Self.spanningWindowFrame)?.frame == Self.maximizedSpanningFrame,
                  "a spanning window did not use the display with the largest overlap")
        let large = CGRect(x: 0, y: 38, width: 1440, height: 822)
        try check(planner.placement(for: .nextDisplay, currentAX: large)?.frame == CGRect(x: -1250, y: -11, width: 1250, height: 822),
                  "moving to a smaller display did not clamp the window")
        let one = WindowLayoutPlanner(displays: [planner.displays[0]])
        try check(planner.placement(for: .restore, currentAX: left, previousAX: original)?.frame == original &&
                  one.placement(for: .restore, currentAX: original, previousAX: left)?.frame == CGRect(x: 0, y: 38, width: 600, height: 400) &&
                  one.placement(for: .nextDisplay, currentAX: original) == nil,
                  "restore did not honor the prior display or clamp after disconnection")
        let acrossGap = CGRect(x: 100, y: 790, width: 600, height: 200)
        try check(planner.placement(for: .restore, currentAX: original, previousAX: acrossGap)?.frame ==
                    CGRect(x: 100, y: 660, width: 600, height: 200),
                  "restore treated the gap between visible display edges as covered")
    }

    private func verifyWindowAccess() throws {
        let adapter = SmokeWindowAccess()
        adapter.trusted = true
        let access = AXWindowAccess(adapter: adapter)
        let planner = Self.windowPlanner
        let initial = SmokeWindowAccess.State()
        let rejected: [SmokeWindowAccess.State] = [
            .init(role: "AXSheet"), .init(role: "AXPopover"), .init(role: "AXDrawer"),
            .init(subrole: "AXDialog"), .init(minimized: true), .init(fullScreen: true),
            .init(positionSettable: false), .init(sizeSettable: false), .init(frame: .zero),
            .init(frame: CGRect(x: 120, y: 400, width: -600, height: 400)),
        ]
        for state in rejected {
            adapter.states[1] = state
            try check(access.perform(.leftHalf, targetPID: 42_001, planner: planner) == .noWindow && adapter.writes.isEmpty,
                      "ineligible window was moved")
        }
        adapter.main = 2
        adapter.states[2] = initial
        let left = CGRect(x: 0, y: 38, width: 720, height: 822)
        try check(access.perform(.leftHalf, targetPID: 42_001, planner: planner) == nil && adapter.states[2]?.frame == left &&
                  adapter.writes == [.position(2, left.origin), .size(2, left.size), .position(2, left.origin)],
                  "eligible main window fallback or position-size-position correction failed")
        adapter.states[1] = initial
        try check(access.perform(.maximize, targetPID: 42_001, planner: planner) == nil && adapter.states[2]?.frame == left &&
                  access.perform(.rightHalf, targetPID: 42_001, planner: planner) == nil &&
                  access.perform(.restore, targetPID: 42_001, planner: planner) == nil &&
                  adapter.states[1]?.frame == CGRect(x: 0, y: 38, width: 1440, height: 822) &&
                  access.perform(.restore, targetPID: 42_001, planner: planner) == .noPreviousFrame,
                  "focused window did not retain only its last frame, or restore resurrected consumed history")
        adapter.focused = nil
        try check(access.perform(.restore, targetPID: 42_001, planner: planner) == nil && adapter.states[2]?.frame == initial.frame,
                  "restore history did not stay isolated per window")
        adapter.focused = 1
        adapter.states[1] = .init(minimumWidth: 800)
        try check(access.perform(.rightHalf, targetPID: 42_001, planner: planner) == .couldNotMove &&
                  adapter.states[1]?.frame == CGRect(x: 640, y: 38, width: 800, height: 822),
                  "app-enforced minimum size was not clamped or failed verification was reported as success")
        adapter.states[1]?.minimumWidth = 0
        try check(access.perform(.restore, targetPID: 42_001, planner: planner) == nil && adapter.states[1]?.frame == initial.frame,
                  "partial move was not undoable")

        let primaryOnly = WindowLayoutPlanner(displays: [planner.displays[0]])
        for (restoreLayout, expected, scenario) in [
            (planner, Self.spanningWindowFrame, "with both displays connected"),
            (primaryOnly, CGRect(x: 0, y: 200, width: 600, height: 400), "after the left display disconnected"),
        ] {
            adapter.states[1] = .init(frame: Self.spanningWindowFrame)
            try check(access.perform(.maximize, targetPID: 42_001, planner: planner) == nil &&
                      adapter.states[1]?.frame == Self.maximizedSpanningFrame,
                      "could not maximize the spanning window on the left display")
            try check(access.perform(.restore, targetPID: 42_001, planner: restoreLayout) == nil &&
                      adapter.states[1]?.frame == expected,
                      "did not restore the spanning window to \(expected) \(scenario); got \(String(describing: adapter.states[1]?.frame))")
            try check(access.perform(.restore, targetPID: 42_001, planner: restoreLayout) == .noPreviousFrame,
                      "restoring the spanning window did not consume history \(scenario)")
        }
        adapter.main = nil
        for id in 100...132 {
            adapter.focused = id
            adapter.states[id] = initial
            try check(access.perform(.leftHalf, targetPID: 42_001, planner: planner) == nil, "history fill move failed")
        }
        adapter.focused = 100
        try check(access.perform(.restore, targetPID: 42_001, planner: planner) == .noPreviousFrame,
                  "oldest history entry was not evicted")
        adapter.focused = 101
        try check(access.perform(.restore, targetPID: 42_001, planner: planner) == nil && adapter.states[101]?.frame == initial.frame,
                  "history discarded more than the oldest entry")
    }

    private func verifyWindowActions(_ app: AppDelegate) async throws {
        let queries: [(WindowCommand, String, String)] = [
            (.leftHalf, "left half", "左半屏"), (.rightHalf, "right half", "右半屏"),
            (.topHalf, "top half", "上半屏"), (.bottomHalf, "bottom half", "下半屏"),
            (.maximize, "max", "最大化"), (.center, "center", "居中"),
            (.almostMaximize, "almost maximize", "接近最大化"), (.reasonableSize, "reasonable size", "合适大小"),
            (.nextDisplay, "next display", "移至下一屏幕"), (.previousDisplay, "previous display", "移至上一屏幕"),
            (.restore, "restore", "恢复原窗口大小"), (.leftHalf, "zuobanping", "zbp"),
        ]
        let catalog = LaunchCatalog.systemActions()
        for (command, english, chinese) in queries {
            for query in [english, chinese] {
                let best = LaunchCatalog.matches(query, actions: catalog).first
                try check(best?.action.destination == .window(command) && best?.primary == true,
                          "window command did not rank first for \(query)")
            }
        }

        app.dismissSearch()
        app.settingsSession.page = .general
        app.showSettings()
        try check(app.windowManagement.isTrusted == false && app.windowManagement.issue == nil && openedAccessibilitySettings.isEmpty,
                  "opening Settings did not silently check Accessibility trust without unsolicited banner")
        app.showSearch()
        try type("left half", into: app)
        let trustChecks = windowAdapter.trustChecks
        let lookups = windowAdapter.lookups.count
        try key(36, "\r", in: app)
        try await until("untrusted window action did not present the onboarding banner") {
            app.windowManagement.issue == .permissionRequired &&
                app.panel.frame.size == PanelGeometry.size(for: app.panelState, rows: app.model.visibleResults,
                                                           showsResults: app.model.showsResults, needsAccessibility: true)
        }
        try check(app.searchPresented && windowAdapter.trustChecks == trustChecks + 1 && windowAdapter.lookups.count == lookups &&
                  windowAdapter.writes.isEmpty && openedAccessibilitySettings.isEmpty,
                  "untrusted command opened System Settings, retried trust or contacted a window")
        app.showSettings()
        try check(app.windowManagement.issue == .permissionRequired,
                  "opening Settings from an untrusted window action lost the permission issue")
        try await verifyAccessibilitySettingsButton(in: app)

        windowAdapter.trusted = true
        app.showSettings()
        try check(app.windowManagement.isTrusted == true && app.windowManagement.issue == nil,
                  "Accessibility grant was not recognized when reopening Settings")
        app.showSearch()
        frontmostWindowPID = ProcessInfo.processInfo.processIdentifier
        try type("half", into: app)
        try check(app.model.launchMatches.first?.action.destination != .window(.rightHalf),
                  "frecency test must start with another half command first")
        try type("右半屏", into: app)
        try key(36, "\r", in: app)
        try await until("window command did not run through Return and dismiss") { !app.searchPresented }
        try check(windowAdapter.lookups.last == 42_001 && !windowAdapter.lookedUpOnMainThread &&
                  windowAdapter.states[1]?.frame == CGRect(x: 720, y: 38, width: 720, height: 822),
                  "command did not target the app captured before showSearch off the main thread")
        app.showSearch()
        try check(app.windowManagement.targetPID == nil, "showSearch captured Lumen itself or reused a stale target")
        try type("half", into: app)
        try check(app.model.launchMatches.first?.action.destination == .window(.rightHalf),
                  "successful window command did not improve Frecency ranking")
        app.dismissSearch()
        frontmostWindowPID = 42_001
        app.showSearch()
        try type("restore", into: app)
        try key(36, "\r", in: app)
        try await until("restore command did not dismiss after restoring the previous frame") { !app.searchPresented }
        try check(windowAdapter.states[1]?.frame == SmokeWindowAccess.State().frame && !NSApp.isActive && !app.panel.isVisible,
                  "restore did not target the original test window or activated the GUI")
        print("Window management passed: geometry, AX eligibility and history, onboarding, bilingual actions, and Frecency")
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

    private func verifyHighlights() throws {
        func verify(_ query: String, _ value: String, _ expected: [String],
                    mode: LauncherHighlight.Mode = .literal) throws {
            let highlight = LauncherHighlight(query)
            let light = highlight.text(value, size: 13, colorScheme: .light, mode: mode)
            let dark = highlight.text(value, size: 13, colorScheme: .dark, mode: mode)
            for result in [light, dark] {
                let painted = result.runs.filter { $0.foregroundColor != nil }
                let runs = painted.map { String(result[$0.range].characters) }
                try check(String(result.characters).utf8.elementsEqual(value.utf8) && runs == expected,
                          "highlight '\(query.prefix(80))' in '\(value.prefix(80))' painted \(runs), expected \(expected)")
                try check(painted.allSatisfy { $0.font == .system(size: 13, weight: .semibold) },
                          "matched highlight runs were not semibold")
            }
            if !expected.isEmpty {
                try check(light.runs.first { $0.foregroundColor != nil }?.foregroundColor !=
                          dark.runs.first { $0.foregroundColor != nil }?.foregroundColor,
                          "highlight did not adapt its tint to the appearance")
            }
        }

        try verify("arch", "ARCHIVE-archive.txt", ["ARCH", "arch"])
        try verify(#"“design brief” budget"#, "BUDGET · design-brief.md", ["BUDGET", "design", "brief"])
        try verify("sign design", "Design draft", ["Design"])
        try verify("青山 月报", "青山的月报.md", ["青山", "月报"])
        try verify("cafe abc", "👩🏽‍💻 Cafe\u{301} ＡＢＣ", ["Cafe\u{301}", "ＡＢＣ"])
        try verify("👩", "👩🏽‍💻 report", ["👩🏽‍💻"])
        try verify("vsc", "Visual Studio Code", ["V", "S", "C"], mode: .action)
        try verify("vsc", "VSC · Visual Studio Code", ["VSC"], mode: .action)
        try verify("mka", "Make Available", ["M", "k", "A"], mode: .action)
        try verify("vsc", "Visual Studio Code.md", [], mode: .name)
        try verify("vsz", "Visual Studio Code", [], mode: .action)
        try verify("QSY", "👩🏽‍💻 青山·月报", ["青山", "月"], mode: .name)
        try verify("qingshan", "青山·月报", ["青山"], mode: .action)
        try verify("qing shan", "青山·月报", ["青山"], mode: .name)
        for (query, name) in [
            ("chengdu", "成都"), ("chengdou", "成都"), ("chongqing", "重庆"), ("xiamen", "厦门"),
            ("changsha", "长沙"), ("changchun", "长春"), ("changan", "长安"), ("changzhi", "长治"),
            ("luan", "六安"), ("xizang", "西藏"), ("yinhang", "银行"), ("yinyue", "音乐"),
        ] {
            try verify(query, "\(name).txt", [name], mode: .name)
        }
        try verify("rqst", "Report青山.txt", ["R", "青山", "t"], mode: .name)
        try verify("rtqs", "Report青山.txt", [], mode: .name)
        try verify("reportqingshan", "Report青山.txt", ["Report青山"], mode: .name)
        try verify("qingshan2", "Report青山-2.txt", ["青山", "2"], mode: .name)
        try verify("lny", "蓝牙", ["蓝牙"], mode: .action)
        try verify("lny", "蓝牙", [], mode: .name)
        try verify("qyb", "青山·月报", ["青", "月报"], mode: .action)
        try verify("sg", "松风谷", ["松", "谷"], mode: .action)
        try verify("lnz", "蓝牙", [], mode: .action)
        try verify("qingshan", String(repeating: "x", count: 62) + "青山", ["青山"], mode: .name)
        try verify("qingshan", String(repeating: "x", count: 63) + "青山", [], mode: .name)
        try verify("qingshan", "青山", [])
        try verify(#"KIND:doc EXT:.PDF path:“/Archive Folder/” /Design/ ~/Drafts/ report"#,
                   "~/Drafts/Archive Folder/Design/Report.pdf", ["Report"])
        try verify(#"kind:doc ext:pdf path:"/Archive Folder/" /Design/ ~/Drafts/"#,
                   "~/Drafts/Archive Folder/Design/Report.pdf", [])
        let snippet = "A pdf reference in the report"
        try verify("report pdf", snippet, ["report"])
        try verify("report PDF", "Report.pdf", ["Report"], mode: .name)
        try verify("pdf", snippet, ["pdf"])
        try verify(#"report "pdf""#, snippet, ["pdf", "report"])
        try verify("report pdf", snippet, ["pdf", "report"], mode: .action)

        let distinct = (0...16).map { "word\($0)x" }
        try verify(distinct.joined(separator: " "), distinct.joined(separator: " "), Array(distinct.prefix(16)))
        let repeated = String(repeating: "report REPORT ", count: 146) + "note" // 2 KiB
        let head = "Report note "
        let start = head + String(repeating: "x", count: 512 - head.count) + "report note "
        let large = start + String(repeating: "x", count: 32 * 1024 - start.count)
        try verify(repeated, large, ["Report", "note"])

        // Measure construction and rendering after warm-up; use the median batch to avoid scheduler noise.
        let batchSize = 10
        let milliseconds = (0..<7).map { _ -> Double in
            let began = ContinuousClock.now
            for _ in 0..<batchSize {
                let output = LauncherHighlight(repeated).text(large, size: 13, colorScheme: .light)
                precondition(output.runs.count == 4)
            }
            let elapsed = began.duration(to: .now).components
            return (Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15) / Double(batchSize)
        }.sorted()[3]
        try check(milliseconds < 1, "2 KiB query on a 32 KiB value averaged \(milliseconds) ms per highlight")
        print(String(format: "Highlight smoke passed (literal, Unicode, fuzzy, pinyin, qualifiers, light/dark; bounded input %.3f ms)",
                     milliseconds))
    }

    private func categoryInkWidths(in panel: NSPanel, rowHeights: [CGFloat]) -> [CGFloat] {
        guard let image = try? render(.aqua, window: panel) else { return [] }
        let scale = CGFloat(image.pixelsWide) / panel.frame.width
        var top = SearchWindow.headerHeight
        return rowHeights.map { height in
            let yRange = Int((top + 5) * scale)..<Int((top + height - 5) * scale)
            top += height
            // Look for foreground ink in the badge column, excluding the panel and selection borders.
            let columns = (image.pixelsWide - Int(78 * scale))..<(image.pixelsWide - Int(18 * scale))
            let ink = columns.filter { x in
                yRange.contains { y in
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                    return (1 - luminance) * color.alphaComponent > 0.30
                }
            }
            guard let first = ink.first, let last = ink.last else { return 0 }
            return CGFloat(last - first + 1) / scale
        }
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
                    scope_dir = str(root.resolve() / 'scope with spaces') + '/'
                    assert tokens in (['limit-probe'], ['kind:folder', 'limit-probe'],
                                      [scope_dir, 'kind:doc', 'ext:txt', 'limit-probe']), tokens
                    def hit(path, kind='file'):
                        return dict(path=path, name=Path(path).name, kind=kind, availability='local',
                                    matched_by=mode, **(dict(snippet='limit-probe', document_stamp='fixture')
                                                        if mode == 'text' else {}))
                    if mode == 'name':
                        hits = [hit(f'/other/limit-probe-{i}.txt') for i in range(61)]
                        hits += [hit('/other/limit-probe-folder', 'directory')]
                    else:
                        hits = [hit(f'/other/global-{i}.txt') for i in range(25)]
                        hits += [hit(scope_dir + 'keep.md'), hit(scope_dir + 'keep.txt')]
                    # Mirror the M2 wire contract; apply all constraints before slicing the fixture ranking.
                    if 'kind:folder' in tokens:
                        hits = [h for h in hits if h['kind'] == 'directory']
                    if 'kind:doc' in tokens:
                        hits = [h for h in hits if h['path'].endswith(('.txt', '.md'))]
                    if 'ext:txt' in tokens:
                        hits = [h for h in hits if h['path'].endswith('.txt')]
                    if scope_dir in tokens:
                        hits = [h for h in hits if h['path'].startswith(scope_dir)]
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
                if request['query'].startswith('hold-'):
                    hold(request['query'])
                names = ['keep.jpg', 'drop.jpg'] if request['query'] == 'accept' else [request['query'] + '.jpg']
                hits = [dict(path=str(root / name), name=name, kind='file', availability='provider_metadata_only',
                             matched_by='image_embedding', document_stamp='fixture') for name in names]
                print(json.dumps(dict(id=request['id'], hits=hits)), flush=True)
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
        let scopedRoot = URL(fileURLWithPath: IndexScope.folderPath(root), isDirectory: true)
            .appendingPathComponent("scope with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: scopedRoot, withIntermediateDirectories: true)
        let scopedKeep = scopedRoot.appendingPathComponent("keep.txt")
        try Data("limit probe fixture".utf8).write(to: scopedKeep)
        for (mode, limit, wanted) in [("name", 60, "/other/limit-probe-folder"), ("text", 24, scopedKeep.path)] {
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
        model.setQuery("kind:doc EXT:.TXT path:\"\(scopedRoot.path)/\" limit-probe")
        try await until("the in-scope text result behind 24 global hits was not returned") {
            !model.searching && marked("scoped-name") && marked("scoped-text") &&
                model.hits.map(\.path) == [scopedKeep.path] && model.hits.first?.hasPreview == true
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

        let keepImage = root.appendingPathComponent("keep.jpg")
        try Data("resident cloud image fixture".utf8).write(to: keepImage)
        let projector = root.appendingPathComponent("projector")
        model.setImageQuery("hold-query", projector: projector)
        try await until("image query did not start") { marked("hold-query-started") }
        model.setImageQuery("accept", projector: projector)
        try await until("timed-out image search did not recover or filter missing files") {
            marked("hold-query-terminated") && !model.searching && model.hits.map(\.name) == ["keep.jpg"]
        }
        try check(!marked("unexpected-standalone-query"), "search or batch validation spawned a standalone CLI")
        model.setImageQuery("hold-close", projector: projector)
        try await until("image search did not restart") { marked("hold-close-started") }
        model.close()
        try await until("closing the launcher leaked image search worker") { marked("hold-close-terminated") }

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
            let expected = PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
            try check(app.panel.frame.size == expected && abs(app.panel.frame.maxY - idleFrame.maxY) <= 1,
                      "Gemma result did not match PanelGeometry or moved top edge")
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
        let expectedPartial = PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
        try check(app.panel.frame.size == expectedPartial && abs(app.panel.frame.maxY - idleFrame.maxY) <= 1,
                  "the watcher or partial Gemma coverage mis-sized the launcher")
        try check(!NSApp.isActive && opened == nil, "Gemma test activated the GUI or opened a document")
        print("Installed Gemma GUI smoke passed (Chinese-to-English, English-to-Chinese, and partial coverage)")
    }

    private func verifyTiming(_ app: AppDelegate) async throws {
        let model = app.model
        let top = app.panel.frame.maxY
        let chrome = app.panel.contentView
        guard let backdrop = chrome as? SearchBackdrop,
              backdrop.layer?.cornerRadius == SearchBackdrop.cornerRadius,
              backdrop.layer?.cornerCurve == .continuous,
              backdrop.layer?.masksToBounds == true,
              backdrop.effect.maskImage?.resizingMode == .stretch else {
            throw Failure("SearchBackdrop missing continuous rounded mask or layer clipping")
        }

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
        try await until("Finder dispatched the filename without blocking on body search") {
            self.revealed?.lastPathComponent == "鹿鸣.md"
        }
        try signal("finish-han-body")
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
        try await until("watch started silently refreshing the visible Han body result") { self.exists("han-refresh-body-started") }
        try check(model.hits == stableHanRows && !model.searching && model.selectedHit?.name == "鹿鸣.md",
                  "background watch refresh flickered searching, cleared rows, or dropped selection")
        try signal("finish-han-refresh-body")
        try await Task.sleep(for: .milliseconds(120))
        try check(!model.searching && model.hits == stableHanRows && model.selectedHit?.name == "鹿鸣.md",
                  "completed silent watch refresh disturbed rows or selection")

        try type("late lexical delivery", into: app)
        try await until("the lexical name lane was held") { self.exists("late-name-started") }
        try await Task.sleep(for: .milliseconds(60))
        try check(!model.hits.contains { $0.name == "body-before-name.md" },
                  "body results flashed before higher-priority names arrived")
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
        try await until("body hit revealed in Finder") {
            self.revealed?.lastPathComponent == "body-match.md"
        }
        revealed = nil
        let expectedTimingSize = PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
        try check(app.panel.frame.size == expectedTimingSize && abs(app.panel.frame.maxY - top) <= 1 &&
                  app.panel.contentView === chrome,
                  "typing or result lane delivery broke anchored PanelGeometry or replaced the launcher")

        // Verify background watch refresh does not close an open Command–K context menu.
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.isOpen, "Command–K did not open context actions")
        try signal("update-watch")
        try await Task.sleep(for: .milliseconds(1500))
        try check(app.contextActions.isOpen && !model.searching && model.selectedHit?.name == "body-match.md",
                  "background watch refresh closed an open Command–K menu or disturbed selection")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.contextActions.isOpen && app.searchPresented, "Escape did not close Cmd+K menu")
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
        try writeSparsePreviewPDF(to: corpus.appendingPathComponent("large-preview-fixture.pdf"))
        let provider = URL(fileURLWithPath: IndexScope.folderPath(corpus), isDirectory: true)
            .appendingPathComponent("Library/CloudStorage/OneDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: corpus.appendingPathComponent("Dropbox/cloud-preview-known.png"),
                                        to: provider.appendingPathComponent("cloud-preview-resident.png"))
        try Data().write(to: provider.appendingPathComponent("cloud-preview-placeholder.png"))
        try Data("Resident Quick Look text fixture.".utf8).write(to: provider.appendingPathComponent("cloud-quick-look-resident.txt"))
        try Data().write(to: provider.appendingPathComponent("cloud-quick-look-placeholder.txt"))
        let contextIntro = (0..<24).map { "Intro paragraph line \($0) describing background context." }.joined(separator: "\n")
        let contextTail = (0..<24).map { "Trailing paragraph line \($0) continuing later details." }.joined(separator: "\n")
        try Data("\(contextIntro)\nTarget context anchor paragraph with matching text.\n\(contextTail)".utf8)
            .write(to: selected.appendingPathComponent("long-context-fixture.md"))
        model.rebuildSavedIndex()
        try await until("preview fixtures were indexed") { !model.scopePending && model.canSearch && model.watchState == .running }
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
        // Start from a taller frame while inline preview is widened (860pt) and verify close restores 680pt + natural height.
        let openFrame = app.panel.frame
        try check(openFrame.width == PanelGeometry.previewWidth,
                  "inline preview did not widen panel to \(PanelGeometry.previewWidth)pt (got \(openFrame.width))")
        app.panel.setFrame(openFrame.insetBy(dx: 0, dy: -16).offsetBy(dx: 0, dy: -16), display: false)
        app.closeInlinePreview()
        let closedExpected = PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
        try check(!app.inlinePreview.isOpen && app.inlinePreview.image == nil &&
                  app.panel.frame.width == PanelGeometry.defaultWidth &&
                  app.panel.frame.size == closedExpected &&
                  abs(app.panel.frame.maxY - openFrame.maxY) <= 1 &&
                  model.query == "zircon calibration" && app.searchPresented,
                  "closing inline preview did not restore 680pt anchored layout or retain the search")
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
        guard let initialPreview = app.localPreview else { throw Failure("preview panel missing") }
        // Verify both non-activating preview handoff and focus leaving after activation.
        do {
            try check(NSApp.setActivationPolicy(.accessory), "could not enable activation for the preview focus test")
            defer {
                app.panel.orderOut(nil)
                app.localPreview?.close()
                initialPreview.close()
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
                          "settled focus did not move to the preview while preserving the search session (previewKey=\(preview.isKeyWindow), panelKey=\(app.panel.isKeyWindow), presented=\(app.searchPresented), active=\(NSApp.isActive), query=\(model.query), selection=\(model.selection ?? "nil"))")
            }
            func verifyFocusLeft(_ preview: LocalPreviewPanel, _ message: String) async throws {
                try await until(message) {
                    !app.panel.isKeyWindow && !preview.isKeyWindow && !app.searchPresented &&
                    model.query.isEmpty && model.selection == nil
                }
            }
            func reopenWindowPreview() async throws -> LocalPreviewPanel {
                try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
                guard let action = app.contextActions.items.firstIndex(where: { $0.id == "quick-look" }) else {
                    throw Failure("missing explicit window preview action")
                }
                app.contextActions.run(action)
                try await until("reopening created a new preview") {
                    app.localPreview != nil && app.localPreview !== initialPreview
                }
                guard let reopened = app.localPreview else { throw Failure("reopened preview panel missing") }
                return reopened
            }

            try check(!NSApp.isActive, "expected app to start inactive before non-activating preview test")
            try await focusPreview(initialPreview)
            guard let escapeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: initialPreview.windowNumber,
                                                     context: nil, characters: "\u{1b}",
                                                     charactersIgnoringModifiers: "\u{1b}",
                                                     isARepeat: false, keyCode: UInt16(kVK_Escape)) else {
                throw Failure("cannot make preview Escape event")
            }
            initialPreview.sendEvent(escapeEvent)
            try await until("Escape in local preview did not return key focus to search") {
                app.localPreview == nil && app.panel.isKeyWindow && app.searchPresented &&
                model.query == "zircon calibration" && model.selection == pdfPath
            }

            let preview = try await reopenWindowPreview()
            NSApp.activate(ignoringOtherApps: true)
            try await until("app did not activate for the preview focus test") { NSApp.isActive }
            try await focusPreview(preview)
            NSApp.deactivate()
            try await verifyFocusLeft(preview, "focus leaving the preview did not dismiss and reset search")

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
            try await verifyFocusLeft(nextPreview, "closing the preview without returning focus to search did not dismiss it")
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
                    && result.evidence?.context?.contains("Synthetic included note.") == true
            }
            return false
        }
        try type("Target context anchor", into: app)
        try await until("long text hit became selectable") { model.selectedHit?.name == "long-context-fixture.md" }
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("inline text preview loaded surrounding paragraphs with highlight") {
            if case .ready(_, let result) = app.inlinePreview.state,
               let context = result.evidence?.context {
                return result.visual == nil && result.evidence?.match == .literal
                    && result.evidence?.highlight == "Target context anchor"
                    && context.contains("Target context anchor paragraph")
                    && context.contains("Intro paragraph") && context.contains("Trailing paragraph")
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
        try check(!app.inlinePreview.isOpen, "rapid selection did not close the previous image preview")
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("explicit preview did not show the newly selected image") {
            if case .ready(let selection, let preview) = app.inlinePreview.state,
               case .image? = preview.visual { return selection.id == selectedImage }
            return false
        }
        if exists("capture-preview") {
            try capture("lumen-inline-image.png", appearance: .darkAqua, window: app.panel)
            app.panel.appearance = nil
        }

        try await verifyUnlimitedAndCloudPreview(app, provider: provider)
        try await verifyCloudQuickLook(app, provider: provider)
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

    private func verifyUnlimitedAndCloudPreview(_ app: AppDelegate, provider: URL) async throws {
        let model = app.model
        let large = URL(fileURLWithPath: IndexScope.folderPath(corpus), isDirectory: true)
            .appendingPathComponent("large-preview-fixture.pdf")
        try type("large-preview-fixture", into: app)
        try await until("large PDF was not selected") { model.selectedHit?.path == large.path }
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("large PDF did not render a bounded first-page preview") {
            if case .ready(_, let document) = app.inlinePreview.state, case .pdf(let png, 1, false)? = document.visual,
               let bitmap = NSBitmapImageRep(data: png) {
                return max(bitmap.pixelsWide, bitmap.pixelsHigh) == 960
            }
            return false
        }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        app.panel.browsing = true
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try await until("Space Quick Look did not use the original large PDF") { app.localPreview?.previewURL?.path == large.path }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(app.searchPresented && app.localPreview == nil && FileManager.default.fileExists(atPath: large.path),
                  "Escape did not close only the native preview")

        let resident = provider.appendingPathComponent("cloud-preview-resident.png")
        let placeholder = provider.appendingPathComponent("cloud-preview-placeholder.png")
        try type("cloud-preview-", into: app)
        try await until("provider fixtures were not indexed metadata-only") {
            [resident, placeholder].allSatisfy { file in
                model.hits.contains { $0.path == file.path && $0.isCloudReference }
            }
        }
        guard let residentHit = model.hits.first(where: { $0.path == resident.path }),
              let placeholderHit = model.hits.first(where: { $0.path == placeholder.path }) else {
            throw Failure("provider fixtures lost before preview")
        }
        app.commands.choose(.file(residentHit), in: model)
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        func readyImage(at url: URL) -> Bool {
            if case .ready(let selection, let preview) = app.inlinePreview.state, case .image? = preview.visual {
                return selection.url == url && app.inlinePreview.image != nil
            }
            return false
        }
        try await until("resident OneDrive image did not preview") { readyImage(at: resident) }
        try check(previewDownloadsStarted == 0, "resident provider file requested a download")

        guard let residentIndex = model.visibleResults.firstIndex(where: { $0.id == residentHit.id }),
              let placeholderIndex = model.visibleResults.firstIndex(where: { $0.id == placeholderHit.id }) else {
            throw Failure("provider rows were not visible")
        }
        func moveOffPlaceholder() throws {
            if model.visibleResults.last?.id == placeholderHit.id {
                try key(kVK_UpArrow, "\u{f700}", in: app)
            } else {
                try key(kVK_DownArrow, "\u{f701}", in: app)
            }
            try check(model.selectedHit?.path != placeholder.path, "arrow key did not move off the placeholder")
        }
        let step = placeholderIndex > residentIndex ? (kVK_DownArrow, "\u{f701}") : (kVK_UpArrow, "\u{f700}")
        for _ in 0..<abs(placeholderIndex - residentIndex) { try key(step.0, step.1, in: app) }
        try check(model.selectedHit?.path == placeholder.path && app.inlinePreview.state == .closed && previewDownloadsStarted == 0,
                  "selection change opened a preview or requested a download")
        var sawIndeterminate = false
        let observation = app.inlinePreview.$state.sink { state in
            if case .downloading(let item, nil) = state, item.url == placeholder { sawIndeterminate = true }
        }
        defer { observation.cancel() }
        func startDownload() async throws {
            app.commands.choose(.file(placeholderHit), in: model)
            try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
            try await until("Cmd+Y did not deliver 40% sync progress for the selected placeholder") {
                if case .downloading(let item, 0.4) = app.inlinePreview.state { return item.url == placeholder }
                return false
            }
        }
        try await startDownload()
        try check(sawIndeterminate && app.localPreview == nil && app.inlinePreview.image == nil,
                  "preview did not show indeterminate progress before the percentage")
        try moveOffPlaceholder()
        try await until("selection change did not cancel cloud sync") { self.previewDownloadsCancelled == 1 }
        try check(app.inlinePreview.state == .closed && previewDownloadsStarted == 1,
                  "selection change started another preview or download")
        try await startDownload()
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try await until("Escape did not cancel cloud sync") { self.previewDownloadsCancelled == 2 }
        try check(app.inlinePreview.state == .closed && app.searchPresented &&
                  !FileManager.default.fileExists(atPath: Self.previewHydrated(placeholder, in: directory).path),
                  "Escape left a preview open, hydrated the file, or dismissed search")
        try await startDownload()
        previewDownloadRelease?.yield(())
        try await until("resident placeholder did not transition from progress to its real bitmap") { readyImage(at: placeholder) }
        try check(previewDownloadsStarted == 3 && previewDownloadsCancelled == 2,
                  "cloud preview ran more than once per explicit request")
    }

    private func verifyCloudQuickLook(_ app: AppDelegate, provider: URL) async throws {
        let model = app.model
        let resident = provider.appendingPathComponent("cloud-quick-look-resident.txt")
        let placeholder = provider.appendingPathComponent("cloud-quick-look-placeholder.txt")
        let started = previewDownloadsStarted
        let cancelled = previewDownloadsCancelled
        try type("cloud-quick-look-", into: app)
        try await until("name-only provider text files were not indexed") {
            [resident, placeholder].allSatisfy { url in
                model.hits.contains { $0.path == url.path && $0.isCloudReference && $0.snippet == nil }
            }
        }
        func select(_ url: URL) throws {
            guard let hit = model.hits.first(where: { $0.path == url.path }) else {
                throw Failure("missing provider text result: \(url.lastPathComponent)")
            }
            app.commands.choose(.file(hit), in: model)
        }
        func cmdY() throws { try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command]) }
        func escape() throws { try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true) }

        try select(resident)
        try cmdY()
        try await until("Cmd+Y did not open Quick Look for the resident cloud text file") {
            app.localPreview?.previewURL == resident
        }
        try check(app.inlinePreview.state == .closed && previewDownloadsStarted == started,
                  "resident text opened inline preview or requested a download")
        try escape()
        app.panel.browsing = true
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try await until("Space did not open Quick Look for the resident cloud text file") {
            app.localPreview?.previewURL == resident
        }
        try escape()

        // Right-click Quick Look on an UNSELECTED row must select it and hydrate if placeholder.
        guard let placeholderHit = model.hits.first(where: { $0.path == placeholder.path }) else {
            throw Failure("missing provider text placeholder hit")
        }
        try check(model.selectedHit?.path == resident.path, "resident row was not selected before unselected right-click preview")
        app.perform(.preview, on: placeholderHit)
        try await until("right-click Quick Look on an unselected placeholder did not select and start download") {
            if case .downloading(let item, 0.4) = app.inlinePreview.state {
                return item.url == placeholder && model.selectedHit?.path == placeholder.path
            }
            return false
        }
        try escape()
        try await until("Escape did not cancel the right-click Quick Look download") { self.previewDownloadsCancelled == cancelled + 1 }

        try select(placeholder)
        try check(app.inlinePreview.state == .closed && app.localPreview == nil && previewDownloadsStarted == started + 1,
                  "selecting a cloud text file requested a preview without a shortcut")
        func startDownload() async throws {
            try cmdY()
            try await until("Cmd+Y did not show the 40% download ring for the cloud text file") {
                if case .downloading(let item, 0.4) = app.inlinePreview.state {
                    return item.url == placeholder && app.inlinePreview.isOpen && app.localPreview == nil
                }
                return false
            }
        }
        try await startDownload()
        try escape()
        try await until("Escape did not cancel the Quick Look download") { self.previewDownloadsCancelled == cancelled + 2 }
        try check(app.inlinePreview.state == .closed && app.localPreview == nil && app.searchPresented &&
                  !FileManager.default.fileExists(atPath: Self.previewHydrated(placeholder, in: directory).path),
                  "Escape hydrated the text placeholder, left a preview open, or dismissed search")
        try await startDownload()
        previewDownloadRelease?.yield(())
        try await until("hydrated cloud text did not replace the download ring with Quick Look") {
            app.localPreview?.previewURL == placeholder && app.inlinePreview.state == .closed
        }
        try check(previewDownloadsStarted == started + 3 && previewDownloadsCancelled == cancelled + 2,
                  "Quick Look started extra downloads or did not cancel exactly twice")
        try escape()

        // Pressing Return on a cloud placeholder must open via NSWorkspace (no .online block).
        opened = nil
        try select(placeholder)
        try key(kVK_Return, "\r", in: app)
        try await until("Return did not open the cloud placeholder") {
            self.opened?.path == placeholder.path && !app.searchPresented
        }
        try check(model.searchNotice == nil, "opening a cloud placeholder raised an online-only error notice")
        opened = nil
        app.showSearch()
        print("Cloud text Quick Look passed (resident, unselected right-click, progress, Escape, hydrated handoff, Return open)")
    }

    private func writeSparsePreviewPDF(to url: URL) throws {
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        func write(_ text: String) throws { try file.write(contentsOf: Data(text.utf8)) }
        try write("%PDF-1.4\n")
        let drawing = "0 0 1 rg 20 20 50 50 f\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Contents 4 0 R >>",
            "<< /Length \(drawing.utf8.count) >>\nstream\n\(drawing)endstream"
        ]
        var offsets: [UInt64] = []
        for (index, object) in objects.enumerated() {
            offsets.append(try file.offset())
            try write("\(index + 1) 0 obj\n\(object)\nendobj\n")
        }
        // An unused stream makes a valid PDF larger than both old limits without writing 130 MiB.
        let padding: UInt64 = 130 * 1024 * 1024
        offsets.append(try file.offset())
        try write("5 0 obj\n<< /Length \(padding) >>\nstream\n")
        try file.seek(toOffset: try file.offset() + padding)
        try write("\nendstream\nendobj\n")
        let xref = try file.offset()
        try write("xref\n0 6\n0000000000 65535 f \n")
        for offset in offsets { try write(String(format: "%010llu 00000 n \n", offset)) }
        try write("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
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
        try await until("Settings and menu still report when watching fails while launcher stays calm") {
            model.watchState == .failed &&
                model.activityTitle == model.t("文件监听已停止", "File watching stopped") &&
                model.launcherActivityTitle == nil
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
        let image = try render(appearance, window: window)
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw Failure("could not encode offscreen snapshot")
        }
        try png.write(to: directory.appendingPathComponent(filename))
    }

    private func render(_ appearance: NSAppearance.Name, window: NSWindow) throws -> NSBitmapImageRep {
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
        return image
    }

    private func verifyWatch(_ app: AppDelegate) async throws {
        let model = app.model
        try type("watchneedle", into: app)
        try await until("watch query starts with no results") { model.hits.isEmpty && !model.searching }
        let top = app.panel.frame.maxY
        try check(app.panel.frame.size == PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults),
                  "empty watch query did not use compact PanelGeometry height")
        let file = corpus.appendingPathComponent("watchneedle.txt")
        try Data().write(to: file)
        if controlledTiming {
            try signal("hold-watch-progress")
            try signal("update-watch")
            try await until("watch progress streamed independently without leaking into search footer or menu bar") {
                model.watchProgress?.entries == 6 && model.watchState == .running && model.hits.isEmpty &&
                    model.activityTitle == model.t("正在扫描文件…", "Scanning files…") &&
                    model.launcherActivityTitle == nil &&
                    app.statusBarSymbol == "magnifyingglass" && app.statusBarTitle == ""
            }
            try signal("finish-watch-progress")
        }
        try await until("watch notification refreshed active results and PanelGeometry") {
            model.hits.first?.name == "watchneedle.txt" &&
                app.panel.frame.size == PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
        }
        try check(model.watchProgress == nil, "watch completion left progress busy")
        try check(abs(app.panel.frame.maxY - top) <= 1, "watch addition moved top edge")
        if !controlledTiming {
            try FileManager.default.removeItem(at: file)
            try await until("watch notification removed deleted result and restored compact PanelGeometry") {
                model.hits.isEmpty && !model.searching &&
                    app.panel.frame.size == PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
            }
        }
        try check(abs(app.panel.frame.maxY - top) <= 1, "watch events moved the launcher top edge")
    }

    private func verifyCloudAction(_ app: AppDelegate) async throws {
        let model = app.model
        try type("cloudledger", into: app)
        try await until("provider metadata result") {
            model.selectedHit?.availability == "provider_metadata_only" && !model.searching
        }
        guard let hit = model.selectedHit else { throw Failure("missing cloud result") }
        try check(hit.isResident && !hit.isPlaceholder, "resident cloud file was misclassified as placeholder")
        try check(LocalFile.dragURL(for: hit)?.path == hit.path, "a resident cloud row did not export a file drag URL")
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.map(\.id) == ["open", "reveal", "preview", "copy-name", "copy-path"],
                  "resident cloud Cmd+K actions were incomplete: \(app.contextActions.items.map(\.id))")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("Quick Look did not open the resident provider file") { app.localPreview?.previewURL?.path == hit.path }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        revealed = nil
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("Command–Return revealed the resident cloud file") { self.revealed?.path == hit.path }
        try check(opened == nil && model.query == "cloudledger", "Finder action opened the file or closed search")
        revealed = nil
        try key(kVK_Return, "\r", in: app)
        try await until("Return opened the resident cloud file without .online blocking") {
            self.opened?.path == hit.path && !app.searchPresented
        }
        try check(model.searchNotice == nil, "opening a resident cloud file raised an unexpected notice")
        opened = nil
        app.showSearch()
    }

    private func verifySemanticInvalidation(_ app: AppDelegate) async throws {
        let model = app.model
        let top = app.panel.frame.maxY
        try type("health examination", into: app)
        try await until("related excerpts started automatically after direct results") {
            self.exists("semantic-enrichment-started") &&
                app.panel.frame.size == PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
        }
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
        let enrichedSize = PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
        try await until("panel height adjusted to actual semantic preview row heights") {
            app.panel.frame.size == enrichedSize
        }
        let frame = app.panel.frame
        try check(Array(model.hits.prefix(direct.count)).map(\.path) == direct && model.selection == selected &&
                  Set(model.hits.map(\.path)).count == model.hits.count && abs(frame.maxY - top) <= 1 &&
                  app.panel.firstResponder === responder,
                  "related excerpts duplicated results, changed direct rank, focus, selection, or top anchor")
        guard let hit = model.hits.first(where: { $0.name == "notes.md" && $0.isSemanticCandidate })
        else { throw Failure("missing Gemma candidate") }
        try check(model.relatedExcerptsLabel == "相关原文", "candidate label did not say related excerpts")
        let rowHeights: [CGFloat] = model.hits.map { $0.hasPreview ? 60 : 44 }
        try await until("direct files and related excerpts painted distinct categories in the rendered list") {
            let widths = self.categoryInkWidths(in: app.panel, rowHeights: rowHeights)
            guard let widestDirect = widths.prefix(direct.count).max(), widths.count == rowHeights.count else { return false }
            return widths.prefix(direct.count).allSatisfy { $0 > 18 } &&
                widths.dropFirst(direct.count).allSatisfy { $0 > widestDirect + 8 }
        }
        app.panel.appearance = nil
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
        try check(lineCount("semantic-serve-launches") == 1,
                  "refinements did not reuse one semantic worker")

        try signal("gemma-cap")
        app.showSettings()
        try await until("Settings refreshed the Gemma storage limit") {
            model.gemmaCoverage?.limited == true && model.gemmaCoverage?.hasResults == true
        }
        app.settings?.close()
        app.showSearch()
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
            try await until("a local result was visible before symlink and deletion checks") {
                model.selectedHit?.name == "preview-safety.txt"
            }
            let replaced = corpus.appendingPathComponent("preview-safety.txt")
            let replacedPath = IndexScope.folderPath(replaced)
            try FileManager.default.removeItem(at: replaced)
            try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: corpus.appendingPathComponent("notes.md"))
            try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
            try await until("Quick Look allowed a 1-level symlinked resident file") {
                app.localPreview?.previewURL?.path == replacedPath
            }
            try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
            try FileManager.default.removeItem(at: replaced)
            try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
            try await until("Quick Look rejected a genuinely missing file before the watcher ran") {
                model.searchNotice?.problem == .stale
            }
            try check(app.localPreview == nil && !model.hits.contains { $0.name == "preview-safety.txt" },
                      "a missing file remained actionable for preview")
        }
    }

    private func verifyReplacedDocument(_ app: AppDelegate) async throws {
        let model = app.model
        try type("safety original paragraph", into: app)
        try await until("preview visible before editing a file on disk") {
            model.selectedHit?.snippet?.contains("safety original paragraph") == true
        }
        let file = corpus.appendingPathComponent("content-safety-source.md")
        let filePath = IndexScope.folderPath(file)
        try Data("Different file at the same path.".utf8).write(to: file, options: .atomic)
        try key(kVK_ANSI_C, "C", in: app, throughPanel: true, flags: [.command, .shift])
        try await until("copyName succeeded for an edited file without stale rejection") {
            self.filePasteboard.string(forType: .string) == "content-safety-source.md"
        }
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("inline preview succeeded for an edited file without stale rejection") {
            if case .ready(let selection, _) = app.inlinePreview.state { return selection.url.path == filePath }
            return false
        }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        opened = nil
        try key(kVK_Return, "\r", in: app)
        try await until("Return opened the edited file without stale rejection") {
            self.opened?.path == filePath && !app.searchPresented
        }
        try check(model.searchNotice == nil, "opening an edited file raised a stale notice")
        opened = nil
        app.showSearch()
    }

    private func verifyStaleBeforeDisplay(_ app: AppDelegate) async throws {
        let model = app.model
        try type("before render original", into: app)
        try await until("old preview held before first display") { self.exists("before-render-started") }
        let file = corpus.appendingPathComponent("before-render.md")
        let filePath = IndexScope.folderPath(file)
        try Data("A new file at the same path.".utf8).write(to: file, options: .atomic)
        try signal("finish-before-render")
        try await until("modified file was kept rather than dropped on mtime drift") {
            !model.searching && model.selectedHit?.name == "before-render.md"
        }
        opened = nil
        try key(kVK_Return, "\r", in: app)
        try await until("modified file opened cleanly after display") {
            self.opened?.path == filePath && !app.searchPresented
        }
        opened = nil
        app.showSearch()

        // A genuinely deleted file must still be filtered out before display.
        let missing = corpus.appendingPathComponent("missing-stamp.md")
        try FileManager.default.removeItem(at: missing)
        try type("missing stamp original", into: app)
        try await until("deleted file was dropped before display") { !model.searching }
        try check(model.hits.isEmpty && model.selection == nil, "a deleted file appeared as an actionable preview")
    }

    private func verifyBackgroundEmbeddingInterleavesContent() async throws {
        let root = directory.appendingPathComponent("background-embedding", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("engine")
        let database = root.appendingPathComponent("index.sqlite")
        let journal = root.appendingPathComponent("batches")
        let source = #"""
        #!/usr/bin/python3
        import json, signal, sys, time
        from pathlib import Path
        root = Path(__file__).parent
        journal = root / 'batches'
        recovered = root / 'recover-document'
        batches = journal.read_text().splitlines() if journal.exists() else []
        checked, embedded = batches.count('content'), batches.count('embed')
        visible = checked + int(recovered.exists())
        command, *args = sys.argv[3:]
        def record(batch):
            with journal.open('a') as out:
                print(batch, file=out)
        if command == 'status':
            print(json.dumps(dict(items=4, documents=visible,
                content=dict(pending=3-checked, checked=checked, total=3),
                gemma=dict(documents_enabled=True, pending=visible>embedded,
                    limited=False, embedded_chunks=embedded, skipped_chunks=0, chunk_limit=100))))
        elif command == 'watch':
            if '--help' not in args:
                print('{"event":"ready"}', flush=True)
                while not recovered.exists():
                    time.sleep(0.02)
                print('{"event":"updated"}', flush=True)
                signal.pause()
        elif command == 'content':
            assert args == ['--max', '8'] and checked < 3
            record('content')
            print(json.dumps(dict(processed=1, indexed=1, pending=2-checked)))
        elif command == 'model-status':
            print(json.dumps(dict(available=True, verified='--verify' in args)))
        elif command == 'embed':
            assert args == ['--gemma', '--max', '32'] and visible > embedded
            record('embed')
            print(json.dumps(dict(new_embeddings=1, skipped_chunks=0, has_more=False)))
        else:
            sys.exit(1)
        """#
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data().write(to: database)
        let suite = "lumen-background-embedding-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("missing isolated embedding defaults") }
        defaults.set(true, forKey: "gemmaIndexingEnabled")
        defaults.set(false, forKey: "gemmaIndexingPaused")
        let model = Launcher(engine: LauncherEngine(executable: executable, database: database), defaults: defaults)
        defer {
            model.close()
            defaults.removePersistentDomain(forName: suite)
        }
        model.start(automaticallyIndex: false)
        try await until("background embeddings resumed after successive content batches") {
            model.contentCoverage?.pending == 0 && model.gemmaCoverage?.embedded_chunks == 3 &&
                model.gemmaCoverage?.complete == true && model.embeddingState == .finished && model.watchState == .running
        }
        let batches = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
        try check(batches == ["content", "embed", "content", "embed", "content", "embed"],
                  "semantic indexing waited for content to drain: \(batches)")
        var resumedFromIdle = false
        let stateUpdates = model.indexStatus.$embeddingState.sink { if $0 == .idle { resumedFromIdle = true } }
        defer { stateUpdates.cancel() }
        try Data().write(to: root.appendingPathComponent("recover-document"))
        try await until("watch recovery automatically embedded newly visible text") {
            model.gemmaCoverage?.embedded_chunks == 4 && model.gemmaCoverage?.complete == true &&
                model.embeddingState == .finished
        }
        let recoveredBatches = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
        try check(resumedFromIdle && recoveredBatches == batches + ["embed"],
                  "finished embeddings did not return to idle and resume without a content batch: \(recoveredBatches)")
        try check(defaults.bool(forKey: "gemmaIndexingEnabled") && !defaults.bool(forKey: "gemmaIndexingPaused") &&
                  defaults.object(forKey: "contentIndexingPaused") == nil && model.embeddingNotice == nil,
                  "silent background embedding changed pause preferences or raised a notice")
    }

    private func verifyPhase1Regressions() async throws {
        // 1. 5-field stamp compatibility & resident vs placeholder semantics.
        try check(SearchHit.stampsMatch("10:20:30:40:50:60:70", "10:20:30:40:50"),
                  "stampsMatch did not accept a legacy 7-field stamp against a 5-field stamp")
        try check(!SearchHit.stampsMatch("10:20:30:40:50", "10:20:31:40:50"),
                  "stampsMatch accepted a mismatched file size")
        for action in [FileAction.open, .reveal, .preview, .copyName, .copyPath] {
            try check(action.allowsCloudReference, "FileAction.\(action) blocked cloud references")
        }

        let root = URL(fileURLWithPath: IndexScope.folderPath(directory), isDirectory: true)
            .appendingPathComponent("phase1-regressions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let realDir = root.appendingPathComponent("real-project", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlinkDir = root.appendingPathComponent("symlink-project")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)
        let realFile = realDir.appendingPathComponent("doc.txt")
        try Data("resident content".utf8).write(to: realFile)
        let symlinkFile = root.appendingPathComponent("doc-link.txt")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

        // Resident cloud hit parity & snippet preview.
        let cloudResident = SearchHit(path: realFile.path, name: "doc.txt", kind: "file",
                                      availability: "provider_metadata_only", matched_by: "text",
                                      snippet: "resident content", document_stamp: "1:2:3:4:5", pdf_page: nil)
        let cloudPlaceholder = SearchHit(path: realFile.path, name: "doc.txt", kind: "file",
                                         availability: "placeholder", matched_by: "name",
                                         snippet: "ignored", document_stamp: nil, pdf_page: nil)
        try check(cloudResident.isResident && !cloudResident.isPlaceholder && cloudResident.hasPreview,
                  "resident cloud hit did not advertise resident + preview capability")
        try check(!cloudPlaceholder.isResident && cloudPlaceholder.isPlaceholder && !cloudPlaceholder.hasPreview,
                  "placeholder hit was misclassified as resident or previewable")
        try check(SearchHit.existsOnDisk(at: symlinkDir.path, kind: "directory") &&
                  SearchHit.existsOnDisk(at: symlinkFile.path, kind: "file") &&
                  !SearchHit.existsOnDisk(at: root.appendingPathComponent("missing.txt").path, kind: "file"),
                  "existsOnDisk failed 1-level symlink or missing-file check")

        // LocalFile.withResidentFile ignores stale stamp drift and supports 1-level symlinks, while still throwing Placeholder.
        let readModified = try LocalFile.withResidentFile(symlinkFile, expectedStamp: "0:0:0:0:0", isPending: { _ in false }) {
            try String(contentsOf: symlinkFile, encoding: .utf8)
        }
        try check(readModified == "resident content", "withResidentFile rejected a symlink or mismatched stamp")
        var threwPlaceholder = false
        do {
            _ = try LocalFile.withResidentFile(realFile, expectedStamp: nil, isPending: { _ in true }) {
                throw Failure("withResidentFile executed work on a cloud placeholder")
            }
        } catch is LocalFile.Placeholder {
            threwPlaceholder = true
        }
        try check(threwPlaceholder, "withResidentFile did not throw Placeholder for a pending cloud item")

        // Pinned symlinked folder shortcuts are accepted.
        let shortcuts = ShortcutLibrary(defaults: nil)
        let folderShortcut = SavedShortcut(id: UUID(), title: "Linked Project", alias: "lp",
                                           target: .folder(symlinkDir.path), pinned: true)
        try check(shortcuts.saveResult(folderShortcut) == .saved, "ShortcutLibrary rejected a 1-level symlinked folder")

        // 2. Idle watch suppression, contentRunning activityTitle, and zero-flicker silent watch refresh.
        let executable = root.appendingPathComponent("engine")
        let database = root.appendingPathComponent("index.sqlite")
        let source = #"""
        #!/usr/bin/python3
        import json, sys, time
        from pathlib import Path
        root = Path(__file__).parent
        command, *args = sys.argv[3:]
        def log(name):
            with (root / name).open('a') as f:
                print('1', file=f)
        if command == 'status':
            log('status-calls')
            pending = 0 if (root / 'content-done').exists() else 1
            print(json.dumps(dict(
                items=2, documents=1,
                scope=dict(roots=[str(root)], allow=[], deny=[], documents=False, content_roots=[]),
                content=dict(pending=pending, checked=1 - pending, total=1),
                gemma=dict(documents_enabled=False, embedded_chunks=0, skipped_chunks=0, pending=False, limited=False, chunk_limit=100)
            )))
        elif command == 'content':
            (root / 'content-started').touch()
            while not (root / 'release-content').exists():
                time.sleep(0.02)
            (root / 'content-done').touch()
            print(json.dumps(dict(processed=1, indexed=1, pending=0)))
        elif command == 'watch':
            if '--help' in args:
                print('--progress')
            else:
                print('{"event":"ready"}', flush=True)
                while True:
                    for marker in ('emit-idle-watch', 'emit-open-watch'):
                        p = root / marker
                        if p.exists():
                            p.unlink()
                            print('{"event":"updated"}', flush=True)
                    time.sleep(0.02)
        elif command == 'serve':
            for line in sys.stdin:
                req = json.loads(line)
                log('serve-calls')
                hits = []
                if req['mode'] == 'name' and req['query'] == 'doc':
                    hits = [dict(path=str(root / 'real-project' / 'doc.txt'), name='doc.txt', kind='file',
                                 availability='provider_metadata_only', matched_by='name')]
                print(json.dumps(dict(id=req['id'], hits=hits)), flush=True)
        """#
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data().write(to: database)
        let model = Launcher(engine: LauncherEngine(executable: executable, database: database), defaults: nil, locale: "en")
        defer { model.close() }
        model.start(automaticallyIndex: false)
        try await until("content batch started while canSearch was true") {
            model.canSearch && model.contentRunning &&
                FileManager.default.fileExists(atPath: root.appendingPathComponent("content-started").path)
        }
        try check(model.activityTitle == "Indexing document content…" && model.launcherActivityTitle == nil,
                  "contentRunning leaked into launcherActivityTitle or misreported Settings activityTitle: \(model.activityTitle)")
        try Data().write(to: root.appendingPathComponent("release-content"))
        try await until("content finished and watch settled") {
            !model.contentRunning && model.contentCoverage?.pending == 0 && model.watchState == .running
        }
        try await Task.sleep(for: .milliseconds(500))
        let statusBeforeIdle = (try? String(contentsOf: root.appendingPathComponent("status-calls"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        let serveBeforeIdle = (try? String(contentsOf: root.appendingPathComponent("serve-calls"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        // Idle watch event with search and Settings closed must spawn zero status or serve work.
        try Data().write(to: root.appendingPathComponent("emit-idle-watch"))
        try await Task.sleep(for: .milliseconds(600))
        let statusAfterIdle = (try? String(contentsOf: root.appendingPathComponent("status-calls"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        let serveAfterIdle = (try? String(contentsOf: root.appendingPathComponent("serve-calls"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        try check(statusAfterIdle == statusBeforeIdle && serveAfterIdle == serveBeforeIdle,
                  "idle watch event spawned status (\(statusAfterIdle - statusBeforeIdle)) or serve (\(serveAfterIdle - serveBeforeIdle))")

        // Visible search with active query: watch refresh stays silent (no searching=true, no selectedHit drop).
        model.setSearchPresented(true)
        model.setQuery("doc")
        try await until("initial search hit arrived") { !model.searching && model.selectedHit?.name == "doc.txt" }
        var sawSearching = false
        var sawSelectionDrop = false
        let searchSub = model.$searching.dropFirst().sink { if $0 { sawSearching = true } }
        let hitSub = model.$hits.dropFirst().sink { _ in if model.selectedHit == nil { sawSelectionDrop = true } }
        defer { searchSub.cancel(); hitSub.cancel() }
        let serveBeforeOpen = (try? String(contentsOf: root.appendingPathComponent("serve-calls"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        try Data().write(to: root.appendingPathComponent("emit-open-watch"))
        try await until("coalesced silent watch refresh completed", seconds: 4) {
            let count = (try? String(contentsOf: root.appendingPathComponent("serve-calls"), encoding: .utf8))?
                .split(separator: "\n").count ?? 0
            return count > serveBeforeOpen
        }
        try check(!sawSearching && !sawSelectionDrop && model.selectedHit?.name == "doc.txt",
                  "silent watch refresh flipped searching or dropped selectedHit")

        // Mixed commands + files: typing a refinement must not blank prior file rows in visibleResults while searching.
        try check(model.shortcuts.save(.init(id: UUID(), title: "Lock Quicklink", alias: "lock",
                                             target: .folder(realDir.path), pinned: false)),
                  "failed to save mixed-command shortcut fixture")
        model.setQuery("lock")
        let mixedDuringSearch = model.visibleResults
        try check(mixedDuringSearch.contains(where: { if case .file(let h) = $0 { return h.name == "doc.txt" }; return false }),
                  "visibleResults blanked prior file rows while commands matched and search was pending")
        print("Phase 1 regressions passed (cloud parity, 5-field stamps, symlinks, zero idle status, silent refresh)")
    }

    private func verifyPhase2Regressions(_ app: AppDelegate) async throws {
        // 1. Default hotkey for fresh installs is Option-Space.
        try check(HotKey.standard == HotKey(code: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "␣") &&
                  HotKey.standard.label == "⌥␣",
                  "HotKey.standard was not Option-Space (got \(HotKey.standard.label))")

        // 2. PanelGeometry exact (width, height) derived from (PanelMode, PanelOverlay).
        let plainHit = SearchHit(path: "/tmp/a.txt", name: "a.txt", kind: "file", availability: "local",
                                 matched_by: "name", snippet: nil, document_stamp: nil, pdf_page: nil)
        let snippetHit = SearchHit(path: "/tmp/b.md", name: "b.md", kind: "file", availability: "local",
                                   matched_by: "text", snippet: "match excerpt", document_stamp: "1:2:3:4:5", pdf_page: nil)
        let shell = PanelGeometry.headerHeight + PanelGeometry.footerHeight
        try check(PanelGeometry.size(for: PanelState(mode: .search, overlay: .none), rows: [], showsResults: false)
                  == CGSize(width: 680, height: shell), "idle search geometry mismatch")
        try check(PanelGeometry.size(for: PanelState(mode: .search, overlay: .none), rows: [], showsResults: true)
                  == CGSize(width: 680, height: shell + 56), "empty search results should be compact (56pt body)")
        try check(PanelGeometry.size(for: PanelState(mode: .search, overlay: .none), rows: [.file(plainHit), .file(snippetHit)], showsResults: true)
                  == CGSize(width: 680, height: shell + 44 + 60), "mixed row heights did not sum accurately")
        try check(PanelGeometry.size(for: PanelState(mode: .search, overlay: .inlinePreview(plainHit)), rows: [.file(plainHit)], showsResults: true)
                  == CGSize(width: 860, height: shell + 176), "inline preview did not widen to 860pt with 176pt floor")
        try check(PanelGeometry.size(for: PanelState(mode: .search, overlay: .contextMenu(count: 3)), rows: [.file(plainHit)], showsResults: true)
                  == CGSize(width: 680, height: shell + 132), "search context menu geometry mismatch")
        try check(PanelGeometry.size(for: PanelState(mode: .clipboard, overlay: .none), rows: [], showsResults: false)
                  == CGSize(width: 680, height: shell + ClipboardHistoryView.height), "clipboard geometry mismatch")
        try check(PanelGeometry.size(for: PanelState(mode: .clipboard, overlay: .contextMenu(count: 2)), rows: [], showsResults: false)
                  == CGSize(width: 680, height: shell + 88), "clipboard context menu geometry mismatch")
        try check(PanelGeometry.size(for: PanelState(mode: .definition(word: "apple", text: "fruit", loading: false), overlay: .none), rows: [], showsResults: false)
                  == CGSize(width: 680, height: shell + 220), "definition card geometry mismatch")
        try check(PanelGeometry.size(for: PanelState(mode: .imageSetup, overlay: .none), rows: [], showsResults: false)
                  == CGSize(width: 680, height: shell + 162), "image setup geometry mismatch")
        try check(PanelGeometry.size(for: PanelState(mode: .commandCard, overlay: .none), rows: [], showsResults: false)
                  == CGSize(width: 680, height: shell + 162), "command card geometry mismatch")
        let fullExec = LauncherExecutable(source: .shortcut("demo"), title: "demo", mode: .fullOutput)
        var capturedOut = LauncherProcess.Capture()
        Data("hello".utf8).withUnsafeBytes { capturedOut.append($0) }
        let execWithOut = CommandExecution(command: fullExec, phase: .finished(.init(status: .exited(0), stdout: capturedOut)))
        let execRunning = CommandExecution(command: fullExec, phase: .running)
        try check(PanelGeometry.size(for: PanelState(mode: .scriptOutput(execWithOut), overlay: .none), rows: [], showsResults: false)
                  == CGSize(width: 680, height: shell + 316), "fullOutput with output geometry mismatch")
        try check(PanelGeometry.size(for: PanelState(mode: .scriptOutput(execRunning), overlay: .none), rows: [], showsResults: false)
                  == CGSize(width: 680, height: shell + 100), "running script output geometry mismatch")
        if let tr = TranslationCommand.parse("tr hello") {
            try check(PanelGeometry.size(for: PanelState(mode: .translation(tr), overlay: .none), rows: [], showsResults: false)
                      == CGSize(width: 680, height: shell + 138), "translation geometry mismatch")
        }

        // 3. Ranking cap raised to 8 and app-vs-file scoring tiers.
        let dummyAppURL = URL(fileURLWithPath: "/Applications/Dummy.app", isDirectory: true)
        let tenApps = (0..<10).map { index in
            LaunchAction(id: "app:alpha.\(index)", english: "AlphaTool\(index)", chinese: "AlphaTool\(index)",
                         symbol: "app", destination: .application(dummyAppURL, stamp: "0"), aliases: [])
        }
        try check(LaunchCatalog.matches("alpha", actions: tenApps).count == 8,
                  "LaunchCatalog.matches did not return up to 8 matches")
        let safariApp = LaunchAction(id: "app:safari.rank", english: "Safari", chinese: "Safari", symbol: "app",
                                     destination: .application(dummyAppURL, stamp: "0"), aliases: [])
        let imageCapture = LaunchAction(id: "app:imagecapture.rank", english: "Image Capture", chinese: "Image Capture",
                                        symbol: "app", destination: .application(dummyAppURL, stamp: "0"), aliases: [])
        try check(LaunchCatalog.matches("safari", actions: [safariApp]).first?.score == 110 &&
                  LaunchCatalog.matches("saf", actions: [safariApp]).first?.score == 92 &&
                  LaunchCatalog.matches("s", actions: [safariApp]).first?.score == 86 &&
                  (82...88).contains(LaunchCatalog.matches("sfr", actions: [safariApp]).first?.score ?? 0) &&
                  LaunchCatalog.matches("far", actions: [safariApp]).first?.score == 74,
                  "app scoring tiers did not match exact 110 / prefix 92 / 1-char 86 / fuzzy 82..88 / substring 74")
        try check((LaunchCatalog.matches("mac", actions: [imageCapture]).first?.score ?? 0) < 79,
                  "unanchored fuzzy app match outranked direct files")

        // 4. Lowered Chinese (2+ Han) & English (2+ words, 6+ chars) semantic trigger.
        try check(Launcher.qualifiesForRelatedExcerpts("报销", directCount: 0) &&
                  !Launcher.qualifiesForRelatedExcerpts("月", directCount: 0) &&
                  Launcher.qualifiesForRelatedExcerpts("tax doc", directCount: 0) &&
                  !Launcher.qualifiesForRelatedExcerpts("ab c", directCount: 0) &&
                  !Launcher.qualifiesForRelatedExcerpts("报销", directCount: 8) &&
                  !Launcher.qualifiesForRelatedExcerpts("ext:pdf 报销", directCount: 0) &&
                  !Launcher.qualifiesForRelatedExcerpts("dir/报销", directCount: 0) &&
                  !Launcher.qualifiesForRelatedExcerpts("report.pdf 报销", directCount: 0),
                  "related-excerpts threshold did not match 2-Han / 2-word-6-char rules")

        // 5. LauncherImageSearch retries ensureStatus() after DB becomes ready.
        let imageDir = directory.appendingPathComponent("phase2-image-status", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        let stubEngine = imageDir.appendingPathComponent("image-status-stub")
        try Data("""
        #!/usr/bin/env python3
        import json, sys
        if 'image-status' in sys.argv:
            print(json.dumps({'root': '/tmp/images', 'vectors': 3}))
        """.utf8).write(to: stubEngine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubEngine.path)
        let lazyDB = imageDir.appendingPathComponent("lazy.sqlite")
        let lazyImages = LauncherImageSearch(engine: LauncherEngine(executable: stubEngine, database: lazyDB), defaults: nil)
        lazyImages.ensureStatus()
        try check(lazyImages.scope == nil && !lazyImages.loading, "ensureStatus ran without a database")
        try Data().write(to: lazyDB)
        lazyImages.ensureStatus()
        try await until("ensureStatus stayed permanently locked after early no-DB call") {
            lazyImages.scope?.root == "/tmp/images" && lazyImages.scope?.vectors == 3 && !lazyImages.loading
        }

        // 6. Tab autocomplete: discovery, command prefix, and never inserting \t.
        let field = try editor(app)
        try type("?", into: app)
        try key(kVK_Tab, "\t", in: app)
        try check(field.string == "qa " && !field.string.contains("\t"),
                  "Tab in discovery did not fill selected command: \(field.string.debugDescription)")
        try type("im", into: app)
        try key(kVK_Tab, "\t", in: app)
        try check(field.string == "img " && !field.string.contains("\t"),
                  "Tab did not complete command prefix 'im' -> 'img ': \(field.string.debugDescription)")
        try type("cb", into: app)
        try key(kVK_Tab, "\t", in: app)
        try check(field.string == "cb " && !field.string.contains("\t"),
                  "Tab did not complete 'cb' -> 'cb ': \(field.string.debugDescription)")
        try type("tr", into: app)
        try key(kVK_Tab, "\t", in: app)
        try check(field.string == "tr " && !field.string.contains("\t"),
                  "Tab did not complete 'tr' -> 'tr ': \(field.string.debugDescription)")
        try type("unmatched_tab_text", into: app)
        try key(kVK_Tab, "\t", in: app)
        try check(field.string == "unmatched_tab_text" && !field.string.contains("\t"),
                  "Tab inserted a literal tab character")
        // 7. Lane 2B checks: calculator exponentiation/comma grouping and locale-aware wiki URLs.
        let power = CalculationResult.evaluate("2^10")
        let nestedPower = CalculationResult.evaluate("2^3^2")
        let grouped = CalculationResult.evaluate("1,000 + 2,500")
        try check(power?.display == "1,024" && power?.copyValue == "1024" &&
                  nestedPower?.display == "512" &&
                  grouped?.display == "3,500" && grouped?.copyValue == "3500",
                  "calculator exponentiation or comma formatting mismatch")
        let zhCatalog = LumenCommandCatalog(includeOptionalLinks: true, chinese: true)
        let enCatalog = LumenCommandCatalog(includeOptionalLinks: true, chinese: false)
        if case .web(_, _, let zhURL) = zhCatalog.resolve("wiki lumen"),
           case .web(_, _, let enURL) = enCatalog.resolve("wiki lumen") {
            try check(zhURL.host == "zh.wikipedia.org" && enURL.host == "en.wikipedia.org",
                      "wiki URL did not follow UI language: \(zhURL) / \(enURL)")
        } else {
            throw Failure("wiki command failed to resolve under locale catalogs")
        }

        try type("", into: app)
        print("Phase 2 core regressions passed (HotKey, PanelGeometry, ranking, 2-Han semantic trigger, image-status retry, Tab, calc ^/commas, wiki locale)")
    }

    private func verifyPhase3Regressions(_ app: AppDelegate) async throws {
        let model = app.model
        // 1. L3 Physical Split: background indexStatus mutations trigger 0 Launcher.objectWillChange pulses and 0 panel relayouts.
        var launcherPulses = 0
        var statusPulses = 0
        let launcherSub = model.objectWillChange.sink { launcherPulses += 1 }
        let statusSub = model.indexStatus.objectWillChange.sink { statusPulses += 1 }
        defer { launcherSub.cancel(); statusSub.cancel() }

        let savedScan = model.indexStatus.scanProgress
        let savedWatch = model.indexStatus.watchProgress
        let savedContent = model.indexStatus.contentRunning
        let savedBatch = model.indexStatus.embeddingBatch
        let frameBefore = app.panel.frame

        let probeScan = IndexProgress(event: "progress", phase: "scanning", entries: 42, elapsed_ms: 500, estimated_total: 100, eta_seconds: 1)
        let probeWatch = IndexProgress(event: "progress", phase: "scanning", entries: 7, elapsed_ms: 100, estimated_total: nil, eta_seconds: nil)
        let probeBatch = EmbeddingBatch(new_embeddings: 3, skipped_chunks: 1, has_more: true)
        model.indexStatus.set(\.scanProgress, to: probeScan)
        model.indexStatus.set(\.watchProgress, to: probeWatch)
        model.indexStatus.set(\.contentRunning, to: !savedContent)
        model.indexStatus.set(\.embeddingBatch, to: probeBatch)
        try check(launcherPulses == 0 && statusPulses == 4,
                  "background indexStatus mutations leaked to Launcher.objectWillChange (\(launcherPulses)) or missed status pulses (\(statusPulses))")

        // Equal-value guarded writes emit 0 pulses on both Launcher and IndexStatusState.
        model.indexStatus.set(\.scanProgress, to: probeScan)
        model.indexStatus.set(\.watchProgress, to: probeWatch)
        model.indexStatus.set(\.contentRunning, to: !savedContent)
        model.indexStatus.set(\.embeddingBatch, to: probeBatch)
        model.setQuery(model.query)
        model.set(\.selectedID, to: model.selectedID)
        model.set(\.hotKey, to: model.hotKey)
        model.set(\.hotKeyIssue, to: model.hotKeyIssue)
        model.set(\.language, to: model.language)
        try check(launcherPulses == 0 && statusPulses == 4,
                  "no-op guarded setters emitted pulses (launcher=\(launcherPulses), status=\(statusPulses))")

        try await Task.sleep(for: .milliseconds(50))
        try check(app.panel.frame == frameBefore && launcherPulses == 0,
                  "indexStatus updates triggered SearchPanel relayout")

        model.indexStatus.set(\.scanProgress, to: savedScan)
        model.indexStatus.set(\.watchProgress, to: savedWatch)
        model.indexStatus.set(\.contentRunning, to: savedContent)
        model.indexStatus.set(\.embeddingBatch, to: savedBatch)
        try check(launcherPulses == 0, "restoring indexStatus emitted Launcher.objectWillChange")

        // 2. Bounded caches & precomputed normalization & visibleResults caching.
        let samplePath = "/tmp/phase3/cached-file.txt"
        let firstID = LauncherFrecency.fileID(samplePath)
        try check(firstID.hasPrefix("file:") && LauncherFrecency.fileID(samplePath) == firstID,
                  "LauncherFrecency.fileID was not stable across cached lookups")
        for index in 0..<2100 {
            let id = LauncherFrecency.fileID("/tmp/phase3/bulk-\(index).txt")
            try check(id.hasPrefix("file:"), "LauncherFrecency.fileID failed under >2048 cache churn")
        }
        try check(LauncherFrecency.fileID(samplePath) == firstID,
                  "LauncherFrecency.fileID changed after bounded cache eviction")

        let precomputed = LaunchAction(id: "app:phase3.demo", english: "Visual Studio Code", chinese: "VS Code 中文",
                                       symbol: "app", destination: .application(URL(fileURLWithPath: "/Applications/Demo.app"), stamp: "0"),
                                       aliases: ["vscode", "代码"])
        try check(precomputed.normalizedNames == ["visualstudiocode", "vscode中文"] &&
                  precomputed.normalizedSearchable == ["visualstudiocode", "vscode中文", "vscode", "代码"] &&
                  LaunchCatalog.matches("vscode", actions: [precomputed]).first?.action.id == precomputed.id,
                  "LaunchAction did not precompute normalized names/searchable cleanly")

        let highlight = LauncherHighlight("cdyh")
        for index in 0..<520 {
            _ = highlight.text("测试文件第\(index)号", size: 13, colorScheme: .light, mode: .action)
        }
        let painted = highlight.text("成都银行", size: 13, colorScheme: .light, mode: .action).runs
            .filter { $0.foregroundColor != nil }.count
        let repainted = highlight.text("成都银行", size: 13, colorScheme: .light, mode: .action).runs
            .filter { $0.foregroundColor != nil }.count
        try check(painted > 0 && painted == repainted, "LauncherHighlight pinyin LRU cache broke highlighting")

        // Icon cache survives dismissSearch() without wiping loaded CGImages.
        try type("lap", into: app)
        try await until("icon loaded before dismissSearch caching check") {
            guard case .action(let action)? = model.visibleResults.first,
                  let key = ApplicationIcons.Key(action) else { return false }
            return app.applicationIcons.images[key] != nil
        }
        guard case .action(let lapAction)? = model.visibleResults.first,
              let lapKey = ApplicationIcons.Key(lapAction) else {
            throw Failure("missing LaunchAction for icon cache persistence test")
        }
        app.dismissSearch()
        try check(app.applicationIcons.images[lapKey] != nil, "dismissSearch wiped cached app icons")
        app.showSearch()

        // 3. Dual-lane CoreSearchConnection: blocked text/validate lane never delays name lane.
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let bundled = resources.appendingPathComponent("lumen")
        let laneDir = directory.appendingPathComponent("phase3-dual-lane", isDirectory: true)
        let laneCorpus = laneDir.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: laneCorpus, withIntermediateDirectories: true)
        let laneFile = laneCorpus.appendingPathComponent("lane-probe.txt")
        try Data("dual lane body needle".utf8).write(to: laneFile)
        let laneDB = laneDir.appendingPathComponent("index.sqlite")
        let indexer = Process()
        indexer.executableURL = bundled
        indexer.arguments = ["--db", laneDB.path, "index", "--root", laneCorpus.path, "--documents"]
        try indexer.run()
        indexer.waitUntilExit()
        try check(indexer.terminationStatus == 0, "bundled indexer failed during phase3 dual-lane setup")

        let laneEngine = LauncherEngine(executable: bundled, database: laneDB)
        defer { laneEngine.close() }
        try check(laneEngine.usesCoreLibrary, "bundled engine did not enable CoreSearchConnection")
        guard let core = laneEngine.core else { throw Failure("missing CoreSearchConnection") }

        var statusReport: IndexReport?
        laneEngine.status(includeScope: true) { response in
            if response.succeeded { statusReport = try? JSONDecoder().decode(IndexReport.self, from: response.output) }
        }
        try await until("LauncherEngine.status(includeScope:) did not return report") { statusReport != nil }
        try check((statusReport?.items ?? 0) >= 1, "LauncherEngine.status report had zero items")

        let releaseText = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            core.textLane.worker.queue.async {
                continuation.resume()
                releaseText.wait()
            }
        }

        var textDone = false
        var validateDone = false
        var nameHits: [SearchHit]?
        laneEngine.search("needle", mode: "text") { _ in textDone = true }
        let probeHit = SearchHit(path: IndexScope.folderPath(laneFile), name: "lane-probe.txt", kind: "file",
                                 availability: "local", matched_by: "name", snippet: nil, document_stamp: nil, pdf_page: nil)
        laneEngine.validate([probeHit]) { _ in validateDone = true }
        laneEngine.search("lane-probe", mode: "name") { result in
            nameHits = try? result.get()
        }
        try await until("name lane was blocked by text/validate lane") { nameHits != nil }
        try check(!textDone && !validateDone && nameHits?.contains(where: { $0.name == "lane-probe.txt" }) == true,
                  "name search waited on text/validate lane or missed lane-probe.txt")
        releaseText.signal()
        try await until("blocked text and validate requests did not finish after release") { textDone && validateDone }

        // Coalesced status callbacks survive cached-hit access switches and settle when closed.
        let holdStatusAccess = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            core.textLane.worker.queue.async {
                continuation.resume()
                holdStatusAccess.wait()
            }
        }
        var firstAccessStatus: IndexReport?
        var secondAccessStatus: IndexReport?
        laneEngine.status(includeScope: true) { response in
            if response.succeeded { firstAccessStatus = try? JSONDecoder().decode(IndexReport.self, from: response.output) }
        }
        laneEngine.status(includeScope: true) { response in
            if response.succeeded { secondAccessStatus = try? JSONDecoder().decode(IndexReport.self, from: response.output) }
        }
        laneEngine.setCachedHitAccess(true)
        laneEngine.setCachedHitAccess(false)
        holdStatusAccess.signal()
        try await until("coalesced status callbacks dropped across cached-hit access toggle") {
            (firstAccessStatus?.items ?? 0) >= 1 && (secondAccessStatus?.items ?? 0) >= 1
        }

        let holdStatusClose = DispatchSemaphore(value: 0)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            core.textLane.worker.queue.async {
                continuation.resume()
                holdStatusClose.wait()
            }
        }
        var closedStatusResponse: EngineResponse?
        laneEngine.status(includeScope: true) { response in
            closedStatusResponse = response
        }
        laneEngine.close()
        holdStatusClose.signal()
        try await until("in-flight status callback did not settle on engine close") {
            closedStatusResponse?.succeeded == false
        }

        // 4. ContentBatch poison-pill skip & streaming embed / image-index client paths.
        let streamDir = directory.appendingPathComponent("phase3-stream", isDirectory: true)
        try FileManager.default.createDirectory(at: streamDir, withIntermediateDirectories: true)
        let streamEngineFile = streamDir.appendingPathComponent("engine")
        let streamDB = streamDir.appendingPathComponent("index.sqlite")
        let streamScript = #"""
        #!/usr/bin/python3
        import json, signal, sys, time
        from pathlib import Path
        root = Path(__file__).parent
        command, *args = sys.argv[3:]
        if command == 'status':
            pending = not (root / 'embed-done').exists()
            print(json.dumps(dict(
                items=2, documents=2,
                scope=dict(roots=[str(root)], allow=[], deny=[], documents=True, content_roots=[str(root)]),
                content=dict(pending=0, checked=2, total=2),
                gemma=dict(documents_enabled=True, embedded_chunks=0, skipped_chunks=0, pending=pending, limited=False, chunk_limit=100)
            )))
        elif command == 'watch':
            if '--help' in args:
                print('--progress')
            else:
                print('{"event":"ready"}', flush=True)
                signal.pause()
        elif command == 'model-status':
            print(json.dumps(dict(available=True, verified='--verify' in args)))
        elif command == 'embed':
            assert '--stream' in args and '--max' in args
            with (root / 'embed-launches').open('a') as f:
                f.write('1\n')
            if (root / 'pause-mode').exists():
                def stopped(*_):
                    (root / 'embed-sigterm').touch()
                    sys.exit(0)
                signal.signal(signal.SIGTERM, stopped)
                print(json.dumps(dict(new_embeddings=1, skipped_chunks=0, has_more=True)), flush=True)
                (root / 'embed-first-sent').touch()
                signal.pause()
            else:
                print(json.dumps(dict(new_embeddings=4, skipped_chunks=0, has_more=True)), flush=True)
                time.sleep(0.02)
                (root / 'embed-done').touch()
                print(json.dumps(dict(new_embeddings=2, skipped_chunks=1, has_more=False)), flush=True)
        elif command == 'image-status':
            vectors = 4 if (root / 'img-done').exists() else 0
            print(json.dumps(dict(root=str(root), vectors=vectors)))
        elif command == 'image-index':
            assert '--stream' in args and '--max' in args
            with (root / 'img-launches').open('a') as f:
                f.write('1\n')
            print(json.dumps(dict(indexed=2, reused=1, limited=False, next_after='k1')), flush=True)
            time.sleep(0.02)
            (root / 'img-done').touch()
            print(json.dumps(dict(indexed=1, reused=0, limited=False, next_after=None)), flush=True)
        """#
        try Data(streamScript.utf8).write(to: streamEngineFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: streamEngineFile.path)
        try Data().write(to: streamDB)
        let streamDefaultsSuite = "lumen-phase3-stream-\(UUID().uuidString)"
        guard let streamDefaults = UserDefaults(suiteName: streamDefaultsSuite) else {
            throw Failure("missing isolated phase3 defaults")
        }
        defer { streamDefaults.removePersistentDomain(forName: streamDefaultsSuite) }

        let streamEngine = LauncherEngine(executable: streamEngineFile, database: streamDB, supportsStreamingBatches: true)
        let streamModel = Launcher(engine: streamEngine, defaults: streamDefaults, locale: "en")
        defer { streamModel.close() }
        streamModel.start(automaticallyIndex: false)
        try await until("phase3 stream fixture did not become searchable") { streamModel.canSearch && streamModel.watchState == .running }

        streamModel.applyContentBatch(ContentBatch(processed: 0, indexed: 0, pending: 2, skipped: 1))
        try check(!streamModel.contentFailed, "skipped poison-pill ContentBatch wrongly set contentFailed")
        streamModel.applyContentBatch(ContentBatch(processed: 0, indexed: 0, pending: 2, skipped: 0))
        try check(streamModel.contentFailed, "zero-progress ContentBatch did not set contentFailed")

        streamModel.buildEmbeddings()
        try await until("streaming embed did not reach finished") {
            streamModel.embeddingState == .finished && streamModel.indexWork == nil &&
                streamModel.gemmaCoverage?.pending == false
        }
        let embedLaunches = try String(contentsOf: streamDir.appendingPathComponent("embed-launches"), encoding: .utf8)
            .split(separator: "\n").count
        try check(embedLaunches == 1 && streamModel.embeddingBatch?.new_embeddings == 2 &&
                  streamModel.embeddingBatch?.skipped_chunks == 1,
                  "streaming embed launched multiple processes (\(embedLaunches)) or missed final batch")
        streamModel.close()

        try? FileManager.default.removeItem(at: streamDir.appendingPathComponent("embed-done"))
        try Data().write(to: streamDir.appendingPathComponent("pause-mode"))
        let pauseDefaultsSuite = "lumen-phase3-pause-\(UUID().uuidString)"
        guard let pauseDefaults = UserDefaults(suiteName: pauseDefaultsSuite) else {
            throw Failure("missing isolated phase3 pause defaults")
        }
        defer { pauseDefaults.removePersistentDomain(forName: pauseDefaultsSuite) }
        let pauseModel = Launcher(engine: streamEngine, defaults: pauseDefaults, locale: "en")
        defer { pauseModel.close() }
        pauseModel.start(automaticallyIndex: false)
        try await until("phase3 pause fixture did not become ready") {
            pauseModel.canSearch && pauseModel.watchState == .running && pauseModel.canBuildEmbeddings
        }
        pauseModel.buildEmbeddings()
        try await until("streaming embed did not emit first batch") {
            FileManager.default.fileExists(atPath: streamDir.appendingPathComponent("embed-first-sent").path)
        }
        pauseModel.pauseEmbeddings()
        try await until("streaming pause did not send SIGTERM and settle in paused") {
            FileManager.default.fileExists(atPath: streamDir.appendingPathComponent("embed-sigterm").path) &&
                pauseModel.embeddingState == .paused && pauseModel.embeddingNotice == nil
        }
        pauseModel.close()

        let streamImages = LauncherImageSearch(engine: streamEngine, defaults: streamDefaults)
        streamImages.setProjector(streamDir.appendingPathComponent("projector"))
        streamImages.ensureStatus()
        try await until("streaming image status failed") { !streamImages.loading && streamImages.scope != nil }
        streamImages.build()
        try await until("streaming image-index did not finish") {
            !streamImages.building && !streamImages.loading && streamImages.scope?.vectors == 4
        }
        let imgLaunches = try String(contentsOf: streamDir.appendingPathComponent("img-launches"), encoding: .utf8)
            .split(separator: "\n").count
        try check(!streamImages.failed && streamImages.checked == 4 && imgLaunches == 1,
                  "streaming image-index failed or launched multiple processes (\(imgLaunches))")

        try type("", into: app)
        print("Phase 3 regressions passed (IndexStatusState isolation, caches, dual-lane CoreSearchConnection, ContentBatch skip, streaming clients)")
    }

    private func verifyPhase2LiveFileInteractions(_ app: AppDelegate) async throws {
        let model = app.model
        let fm = FileManager.default

        // 1. Tab folder path completion when a folder hit is selected.
        let tabFolder = corpus.appendingPathComponent("Phase2TabFolder", isDirectory: true)
        try fm.createDirectory(at: tabFolder, withIntermediateDirectories: true)
        let folderPath = IndexScope.folderPath(tabFolder)
        try type("Phase2TabFolder", into: app)
        try await until("Tab folder fixture was indexed") {
            model.hits.contains { $0.path == folderPath && $0.kind == "directory" }
        }
        model.selectedID = folderPath
        try key(kVK_Tab, "\t", in: app)
        let field = try editor(app)
        try check(field.string == folderPath + "/" && !field.string.contains("\t"),
                  "Tab did not complete selected folder path + '/': \(field.string.debugDescription)")

        // 2. Unified selection: clicking/selecting a script row immediately closes an open file inline preview and restores 680pt width.
        let imageFixture = corpus.appendingPathComponent("phase2-shared-preview.png")
        try Data(Self.minimalPNG()).write(to: imageFixture)
        let imagePath = IndexScope.folderPath(imageFixture)
        let scriptsFolder = directory.appendingPathComponent("Phase2SelectionScripts", isDirectory: true)
        try fm.createDirectory(at: scriptsFolder, withIntermediateDirectories: true)
        let scriptFile = scriptsFolder.appendingPathComponent("phase2-shared-script")
        try Data("#!/bin/sh\n# @lumen.title phase2-shared-script\necho ok\n".utf8).write(to: scriptFile)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)
        app.scriptCatalog.selectFolder(scriptsFolder)
        app.scriptCatalog.setScriptsEnabled(true)
        defer { app.scriptCatalog.setScriptsEnabled(false) }
        try await until("Phase 2 script fixture loaded") {
            !app.scriptCatalog.scriptLoading && app.scriptCatalog.scripts.contains { $0.title == "phase2-shared-script" }
        }
        try type("phase2-shared", into: app)
        try await until("both file image and script matched the shared query") {
            model.hits.contains { $0.path == imagePath } &&
                app.commands.executableMatches.contains { $0.action.english == "phase2-shared-script" }
        }
        guard let scriptAction = app.commands.executableMatches.first(where: { $0.action.english == "phase2-shared-script" })?.action else {
            throw Failure("missing phase2 script action")
        }
        model.selectedID = imagePath
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("inline image preview opened and widened panel to 860pt") {
            app.inlinePreview.isOpen && app.panelState.overlay == .inlinePreview(model.selectedHit!) &&
                app.panel.frame.width == PanelGeometry.previewWidth
        }
        // Simulate clicking the script row through the unified selection source.
        model.selectedID = scriptAction.id
        try await until("selecting a script row closed stale file inline preview and restored 680pt width") {
            !app.inlinePreview.isOpen && model.selectedHit == nil &&
                app.panelState.overlay == .none && app.panel.frame.width == PanelGeometry.defaultWidth
        }
        try type("", into: app)
        print("Phase 2 live interactions passed (Tab folder completion, unified selection closing stale inline preview)")
    }

    private static func minimalPNG() -> [UInt8] {
        // 1x1 opaque RGB PNG.
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
         0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
         0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
         0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
         0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
         0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
         0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0,
         0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
         0xAE, 0x42, 0x60, 0x82]
    }

    private func verifyEmbeddingRun(_ app: AppDelegate) async throws {
        let model = app.model
        try await until("document coverage permits an intentional build") { model.canBuildEmbeddings }
        try check(!exists("embeddings-started"), "first use enabled semantic indexing without consent")
        model.buildEmbeddings()
        try await waitForEmbeddingBatch(1)
        try check(model.launcherActivityTitle == nil &&
                  model.activityTitle == model.t("正在生成语义索引…", "Building semantic index…") &&
                  app.statusBarSymbol == "magnifyingglass" && app.statusBarTitle == "",
                  "background embeddings leaked into search footer or menu bar")
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
        app.showSettings()
        try await until("new text became eligible for embedding in Settings") { model.canBuildEmbeddings }
        app.settings?.close()
        app.showSearch()
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

    private func verifyAccessibilitySettingsButton(in app: AppDelegate) async throws {
        guard let window = app.settings, let view = window.contentView else { throw Failure("Settings did not load") }
        // SwiftUI requires an ordered window for mouse events. Keep it transparent and send the click locally.
        let frame = window.frame
        let opacity = window.alphaValue
        window.alphaValue = 0
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.setFrame(frame, display: false)
            window.alphaValue = opacity
        }
        view.layoutSubtreeIfNeeded()
        let bounds = view.convert(view.bounds, to: nil)
        // The button is on the right side of the banner, just below the General heading.
        let point = CGPoint(x: bounds.maxX - 90, y: bounds.maxY - 105)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try mouseEvent(type, count: 1, at: point, in: window))
        }
        try await until("the Settings button did not dispatch the Accessibility deep-link") {
            openedAccessibilitySettings.map(\.absoluteString) ==
                ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
        }
    }

    private func click(count: Int, at point: NSPoint, in window: NSWindow) throws {
        // Hit-test the live row, then deliver AppKit events to that responder. The
        // app-local event does not depend on desktop focus or the global mouse queue.
        guard let target = window.contentView?.hitTest(point) as? ActionRowClickTarget else {
            throw Failure("the fixture row was not hit-testable")
        }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try mouseEvent(type, count: count, at: point, in: window)
            if type == .leftMouseDown { target.mouseDown(with: event) }
            else { target.mouseUp(with: event) }
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, count: Int, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: count,
                                             pressure: type == .leftMouseDown ? 1 : 0) else {
            throw Failure("cannot make in-process mouse event")
        }
        return event
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

// Smoke tests only inspect or change remote-window fixtures between completed commands.
private final class SmokeWindowAccess: WindowAccessAdapter, @unchecked Sendable {
    struct State {
        var role = "AXWindow"
        var subrole = "AXStandardWindow"
        var minimized = false
        var fullScreen = false
        var positionSettable = true
        var sizeSettable = true
        var frame = CGRect(x: 120, y: 400, width: 600, height: 400)
        var minimumWidth: CGFloat = 0
    }

    enum Write: Equatable {
        case position(Int, CGPoint), size(Int, CGSize)
    }

    private let trustLock = NSLock()
    private var trustState = (trusted: false, checks: 0)
    var trusted: Bool {
        get { trustLock.withLock { trustState.trusted } }
        set { trustLock.withLock { trustState.trusted = newValue } }
    }
    var trustChecks: Int { trustLock.withLock { trustState.checks } }
    private(set) var lookups: [pid_t] = []
    private(set) var lookedUpOnMainThread = false
    private(set) var writes: [Write] = []
    var focused: Int? = 1
    var main: Int?
    var states: [Int: State] = [1: State()]

    func isTrusted() -> Bool {
        trustLock.withLock {
            trustState.checks += 1
            return trustState.trusted
        }
    }

    func windows(in pid: pid_t) -> (focused: Int?, main: Int?) {
        lookups.append(pid)
        lookedUpOnMainThread = lookedUpOnMainThread || Thread.isMainThread
        return pid == 42_001 ? (focused, main) : (nil, nil)
    }

    func inspect(_ window: Int) -> WindowAttributes? {
        states[window].map { state in
            WindowAttributes(role: state.role, subrole: state.subrole, minimized: state.minimized, fullScreen: state.fullScreen,
                             positionSettable: state.positionSettable, sizeSettable: state.sizeSettable, frame: state.frame)
        }
    }

    func frame(of window: Int) -> CGRect? { states[window]?.frame }

    func setPosition(_ position: CGPoint, of window: Int) -> Bool {
        writes.append(.position(window, position))
        states[window]?.frame.origin = position
        return true
    }

    func setSize(_ size: CGSize, of window: Int) -> Bool {
        writes.append(.size(window, size))
        if var state = states[window] {
            state.frame.size = CGSize(width: max(size.width, state.minimumWidth), height: size.height)
            state.frame.origin.y += 20 // Simulate WindowServer shifting the origin on resize.
            states[window] = state
        }
        return true
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
#endif
