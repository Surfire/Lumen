#if LUMEN_SMOKE
import AppKit
import Carbon
import Combine
import Darwin
import Foundation
import ImageIO
import PDFKit
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import Vision
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
    var pasteIntoPreviousAppCount = 0
    var openedInTerminal: [(directory: URL, terminal: URL)] = []
    var preferredTerminalOverride: URL?
    var openedWith: [(file: URL, application: URL)] = []
    var openWithAppsOverride: ((URL) -> [LauncherFileTools.OpenWithApp])?
    private var simulatedDatalessPaths = Set<String>()
    func isSimulatedDataless(_ url: URL) -> Bool {
        simulatedDatalessPaths.contains(IndexScope.folderPath(url))
    }
    var simulatedFrontmostApp: NSRunningApplication?
    let fileDialogAXAdapter = SmokeFileDialogAXAdapter()
    let selectionAXAdapter = SmokeSelectionAXAdapter()
    let contextPasteboard = NSPasteboard.withUniqueName()
    var contextCaptureEnabled = false
    var chosenQuicklinkFolder: URL?
    var chosenScriptsFolder: URL?
    var chosenSettingsDirectories: [URL]?
    var automaticIndexScenario: Bool { exists("automatic-index-scenario") }
    var chosenDiagnosticFile: URL?
    var chosenImageFolder: URL?
    var chosenImageProjector: URL?
    private let definitionStorage = SmokeDefinitionStorage()
    var definitionProvider: (@Sendable (String) -> String?)? {
        get { definitionStorage.get() }
        set { definitionStorage.set(newValue) }
    }
    nonisolated func lookupDefinition(_ word: String) -> String? {
        definitionStorage.get()?(word)
    }

    func makeDefinitionLookup() -> @Sendable (String) -> String? {
        let storage = definitionStorage
        return { word in storage.get()?(word) }
    }
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
            ["cloud-preview-placeholder.png", "cloud-quick-look-placeholder.txt",
             "cloud-quick-look-placeholder.docx", "cloud-quick-look-inline.docx",
             "cloud-md-placeholder.png"].contains(url.lastPathComponent) &&
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
            } else if url.lastPathComponent == "cloud-quick-look-inline.docx" {
                bytes = Self.makeDOCXFixture(paragraphs: [
                    "Cloud inline hydrated DOCX document.",
                    "LumenCloudInlineDocxHydrated",
                ])
            } else if url.pathExtension == "docx" {
                bytes = Data("Hydrated Quick Look Office fixture.".utf8)
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
    private var portraitDisplayChecks = 0
    private var simulatedPortraitDisplay: Bool?

    func makeWindowManagement() -> WindowManagement {
        WindowManagement(adapter: windowAdapter, frontmostPID: { [weak self] in self?.frontmostWindowPID },
                         layout: { Self.windowPlanner }, openSettings: { [weak self] in self?.openedAccessibilitySettings.append($0) },
                         detectPortrait: { [weak self] _ in
                             self?.portraitDisplayChecks += 1
                             return self?.simulatedPortraitDisplay ?? false
                         })
    }

    private lazy var translationSuite = "io.github.surfire.lumen.gui-smoke.\(UUID())"
    private lazy var translationPreferences = UserDefaults(suiteName: translationSuite)
    private let translationSecrets = SmokeTranslationSecrets()
    private let personalDataHarness = SmokePersonalDataHarness()
    private var smokeChromiumBookmarksURL: URL { directory.appendingPathComponent("smoke-chrome-bookmarks.json") }
    private var smokeSafariBookmarksURL: URL { directory.appendingPathComponent("smoke-safari-bookmarks.plist") }
    var shortcutFixturePreferences: UserDefaults? { exists("quicklinks-scenario") ? translationPreferences : nil }

    func makeScriptCatalog() -> LauncherScriptCatalog {
        LauncherScriptCatalog(defaults: translationPreferences, shortcutsExecutable: directory.appendingPathComponent("shortcuts-fixture"))
    }

    func makeClipboardManager() -> ClipboardManager {
        ClipboardManager(defaults: translationPreferences!, pasteboard: filePasteboard,
                         directory: clipboardFixtureRoot.appendingPathComponent("Clipboard", isDirectory: true),
                         automaticPolling: false, sessionCenter: clipboardSession, isConsoleSessionActive: { true })
    }

    func makeSnippetsDirectory() -> URL {
        clipboardFixtureRoot.appendingPathComponent("Snippets", isDirectory: true)
    }

    func makeTranslationModel() -> TranslationPanelModel {
        TranslationPanelModel(defaults: translationPreferences, client: .init(secrets: translationSecrets, timeout: 3))
    }

    func makeCurrencyStore() -> CurrencyRateStore {
        CurrencyRateStore(
            defaults: translationPreferences!,
            cacheURL: directory.appendingPathComponent("smoke-currency-rates.json"),
            fetcher: { _ in throw CancellationError() }
        )
    }

    func makeBookmarkLibrary() -> BookmarkLibrary {
        BookmarkLibrary(
            defaults: translationPreferences!,
            sources: [
                BookmarkSource(browser: "Chrome", kind: .chromiumJSON, url: smokeChromiumBookmarksURL),
                BookmarkSource(browser: "Safari", kind: .safariPlist, url: smokeSafariBookmarksURL),
            ]
        )
    }

    func makePersonalDataStore() -> PersonalDataStore {
        PersonalDataStore(defaults: translationPreferences!, provider: personalDataHarness.makeProvider())
    }

    func makeFileDialogBridge() -> FileDialogBridge {
        FileDialogBridge(
            axAdapter: fileDialogAXAdapter,
            pollIntervalNanoseconds: 5_000_000,
            pollTimeoutNanoseconds: 60_000_000
        )
    }

    func makeSelectionContextBridge() -> SelectionContextBridge {
        SelectionContextBridge(axAdapter: selectionAXAdapter)
    }

    func captureSelectionContext(using bridge: SelectionContextBridge, frontmostApp: NSRunningApplication?) -> CapturedContext? {
        guard contextCaptureEnabled else { return nil }
        return bridge.capture(frontmostApp: frontmostApp, pasteboard: contextPasteboard)
    }

    func makeIsolatedLauncher(
        engine: LauncherEngine,
        defaults: UserDefaults,
        locale: String = "en"
    ) -> Launcher {
        let currencyURL = directory.appendingPathComponent("smoke-currency-\(UUID().uuidString).json")
        let currencyStore = CurrencyRateStore(
            defaults: defaults,
            cacheURL: currencyURL,
            fetcher: { _ in throw CancellationError() }
        )
        let bookmarkLibrary = BookmarkLibrary(defaults: defaults, sources: [])
        let personalStore = PersonalDataStore(defaults: defaults, provider: PersonalDataProvider())
        return Launcher(
            engine: engine,
            defaults: defaults,
            locale: locale,
            currencyStore: currencyStore,
            bookmarkLibrary: bookmarkLibrary,
            personalDataStore: personalStore,
            definitionLookup: makeDefinitionLookup(),
            snippetsDirectory: directory.appendingPathComponent("iso-snippets-\(UUID().uuidString)", isDirectory: true)
        )
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
        guard (2...3).contains(args.count),
              args.count == 2 || args[2] == "fail-after-swap" || args[2] == "relaunch-hook" || args[2] == "ad-hoc-fallback",
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
                if args.count == 3, args[2] == "relaunch-hook" {
                    let suite = "io.github.surfire.lumen.updater-smoke.\(UUID().uuidString)"
                    guard let defaults = UserDefaults(suiteName: suite) else {
                        throw Failure("Failed to create isolated UserDefaults suite")
                    }
                    defer { defaults.removePersistentDomain(forName: suite) }
                    try await verifyUpdateSettingsFlow(updater: updater, defaults: defaults)
                    exit(0)
                }
                if args.count == 3, args[2] == "ad-hoc-fallback" {
                    let result = try await updater.checkForUpdates()
                    guard !result.installableInPlace else {
                        throw Failure("Ad-hoc fallback release unexpectedly allowed in-place install")
                    }
                    if let release = result.release {
                        print("Ad-hoc release \(release.version) (build \(release.build)); installableInPlace=false")
                    } else {
                        print("No newer release")
                    }
                    exit(0)
                }
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

    @MainActor
    private static func verifyUpdateSettingsFlow(updater: LauncherUpdater, defaults: UserDefaults) async throws {
        var relaunched: URL?
        let settings = UpdateSettings(defaults: defaults, updater: updater) { relaunched = $0 }
        guard settings.canInstallInPlace, settings.autoCheckUpdates, settings.shouldAutoCheck() else {
            throw Failure("Unexpected initial UpdateSettings state")
        }
        settings.autoCheckUpdates = false
        let disabled = UpdateSettings(defaults: defaults, updater: updater) { _ in }
        guard !disabled.autoCheckUpdates, !disabled.shouldAutoCheck() else {
            throw Failure("autoCheckUpdates=false was not persisted")
        }
        settings.autoCheckUpdates = true
        settings.check()
        await settings.waitForIdle()
        guard settings.error == nil, let release = settings.release, let checkedAt = settings.lastUpdateCheckAt else {
            throw Failure("UpdateSettings.check() failed: \(settings.error ?? "missing release")")
        }
        guard !settings.shouldAutoCheck(now: checkedAt.addingTimeInterval(23 * 3600)),
              settings.shouldAutoCheck(now: checkedAt.addingTimeInterval(24 * 3600 + 1)) else {
            throw Failure("24-hour auto-check schedule cadence check failed")
        }
        let reloaded = UpdateSettings(defaults: defaults, updater: updater) { _ in }
        guard let reloadedDate = reloaded.lastUpdateCheckAt,
              abs(reloadedDate.timeIntervalSince(checkedAt)) < 0.001,
              !reloaded.shouldAutoCheck(now: checkedAt.addingTimeInterval(23 * 3600)),
              reloaded.shouldAutoCheck(now: checkedAt.addingTimeInterval(24 * 3600 + 1)) else {
            throw Failure("lastUpdateCheckAt was not persisted cleanly")
        }
        guard LauncherUpdater.releasePageURL(for: nil).absoluteString == "https://github.com/Surfire/Lumen/releases/latest",
              LauncherUpdater.releasePageURL(for: release).absoluteString == "https://github.com/Surfire/Lumen/releases/tag/v\(release.version)" else {
            throw Failure("Unexpected releasePageURL output")
        }
        settings.installAndRelaunch()
        await settings.waitForIdle()
        guard settings.error == nil, let backup = settings.backup, let relaunched, relaunched == updater.bundleURL else {
            throw Failure("UpdateSettings.installAndRelaunch() failed: \(settings.error ?? "missing relaunch hook")")
        }
        print("Installed \(release.version) (build \(release.build)); relaunched: \(relaunched.path); backup: \(backup.path)")
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

        if exists("spotlight-scenario") {
            try await verifySpotlightParityFeatures(app)
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
            try await verifySpotlightParityFeatures(app)
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
        try await until("Command–Return selected a local file in Finder and dismissed search") {
            self.revealed?.path == expected && !app.searchPresented && model.query.isEmpty && model.hits.isEmpty
        }
        try check(opened == nil, "Finder shortcut unexpectedly opened the file")
        revealed = nil
        app.showSearch()
        try type("archive", into: app)
        try await until("reopened archive query promoted the revealed file via frecency") {
            !model.searching && model.hits.first?.path == expected && model.hits.count >= 2
        }
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try check(model.selection == model.hits[1].path, "down arrow did not select the second row")
        try key(kVK_UpArrow, "\u{f700}", in: app)
        try check(model.selection == expected, "up arrow did not restore the first row")
        try key(kVK_Return, "\r", in: app)
        try await until("Return opened the selected synthetic file and cleared the session") {
            self.opened?.path == expected && !app.searchPresented && model.query.isEmpty && model.hits.isEmpty
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
        try check(app.contextActions.items.map(\.id) == ["copy-clip", "pin-clip", "delete-clip", "save-as-snippet"],
                  "Shift–Return did not show clipboard actions with Save as Snippet: \(app.contextActions.items.map(\.id))")
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

        // Verify rich file-URL & JPEG capture plus Space preview on clipboard clips.
        let clipFile = corpus.appendingPathComponent("clipboard-rich-fixture.swift")
        try Data("let lumenRichClip = true\n".utf8).write(to: clipFile)
        let richItem = NSPasteboardItem()
        try check(richItem.setString(clipFile.absoluteString, forType: .fileURL), "could not put fileURL on pasteboard")
        board.clearContents()
        try check(board.writeObjects([richItem]), "could not write fileURL pasteboard item")
        history.poll()
        guard let fileClip = history.items.first, fileClip.isFile,
              fileClip.filePath == clipFile.path else {
            throw Failure("ClipboardManager did not capture Finder fileURL cleanly")
        }
        try check(history.copy(id: fileClip.id), "copying back a file clip failed")
        let pastedURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try check(pastedURLs?.first?.standardizedFileURL.path == clipFile.standardizedFileURL.path,
                  "copying back a file clip did not restore .fileURL on pasteboard")

        guard let jpegRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8,
                                             samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let jpegData = jpegRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw Failure("could not create JPEG clipboard fixture")
        }
        board.clearContents()
        try check(board.setData(jpegData, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)),
                  "could not write JPEG fixture to pasteboard")
        await history.poll()?.value
        guard let jpegClip = history.items.first, jpegClip.isImage, jpegClip.filePath == nil else {
            throw Failure("ClipboardManager did not capture public.jpeg image clip")
        }
        try type("", into: app)
        try type("cb ", into: app)
        try await until("clipboard rich clips loaded into cb rows") {
            app.commands.clipboardRows.contains { $0.id == jpegClip.id } &&
                app.commands.clipboardRows.contains { $0.id == fileClip.id } &&
                app.commands.clipboardSelection == jpegClip.id
        }
        // Navigating rows enters browse mode so Space toggles floating preview for files and images.
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try check(app.commands.clipboardSelection == fileClip.id && app.panel.browsing,
                  "Down did not select clipboard file clip or enter browse mode")
        if exists("capture-icons") {
            // Warm one offscreen draw pass so SwiftUI's .task(id:) file preview finishes loading before capture.
            _ = try? render(.aqua, window: app.panel)
            try await Task.sleep(for: .milliseconds(250))
            try capture("lumen-clipboard-file-preview.png", appearance: .aqua, window: app.panel)
            app.panel.appearance = nil
        }
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try await until("Space did not open LocalPreviewPanel for resident clipboard file clip") {
            app.localPreview?.previewURL?.standardizedFileURL.path == clipFile.standardizedFileURL.path
        }
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try check(app.localPreview == nil && app.searchPresented,
                  "second Space did not close clipboard file preview")
        try key(kVK_UpArrow, "\u{f700}", in: app)
        try check(app.commands.clipboardSelection == jpegClip.id && app.panel.browsing,
                  "Up did not restore clipboard JPEG clip selection")
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try await until("Space did not open LocalPreviewPanel for clipboard image clip") {
            app.localPreview != nil
        }
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try check(app.localPreview == nil && app.searchPresented,
                  "second Space did not close clipboard image preview while preserving search")
        history.clearAll()
        try await until("clearing rich clipboard fixtures finished") {
            history.items.isEmpty && app.commands.clipboardRows.isEmpty
        }

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
        async let engineChecks: Void = verifyEngineRegressions()
        async let bgEmbedChecks: Void = verifyBackgroundEmbeddingInterleavesContent()
        async let phase1Checks: Void = verifyPhase1Regressions()
        _ = try await (engineChecks, bgEmbedChecks, phase1Checks)
        try await verifyPhase2Regressions(app)
        try await verifyPhase3Regressions(app)
        try await verifyBuild33Phase1Regressions(app)
        try await verifyBuild33Phase2Regressions(app)
        try await verifyV060SwiftUXRegressions(app)
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
        let fileDefaultFixtures = try makeFileDefaultActionFixtures()
        let wave2Fixtures = try makeWave2CorpusFixtures()
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
        guard let expected = model.selectedHit else { throw Failure("lost the selected file") }
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("the file retained its normal Finder route and dismissed search") {
            self.revealed?.lastPathComponent == "Lumen Action Probe notes.txt" && !app.searchPresented && model.query.isEmpty
        }
        try check(dispatchedActions.count == count, "a file Finder action unexpectedly dispatched a quick action")
        revealed = nil
        app.showSearch()
        try type("lumen action probe", into: app)
        try await until("file result reloaded after Finder dismissal") {
            !model.searching && model.hits.contains { $0.path == expected.path }
        }
        if model.selectedHit?.path != expected.path {
            try key(kVK_DownArrow, "\u{f701}", in: app)
        }
        try check(model.selectedHit?.path == expected.path, "could not re-select the file result after Finder dismissal")
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
        try await until("Command–Y did not open the inline plain-text preview") {
            if case .ready(let selection, let document) = app.inlinePreview.state {
                return selection.url.path == expected.path && selection.kind == .plainText &&
                    document.text == "Synthetic unified search fixture." && !document.isCode &&
                    app.localPreview == nil
            }
            return false
        }
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try check(!app.inlinePreview.isOpen && app.inlinePreview.state == .closed &&
                  app.localPreview == nil && app.searchPresented &&
                  FileManager.default.fileExists(atPath: expected.path),
                  "Command–Y did not toggle off the inline plain-text preview while keeping search and file intact")
        app.panel.browsing = true
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try await until("Space in browse mode toggles real Quick Look") { app.localPreview?.previewURL?.path == expected.path }
        guard let preview = app.localPreview, let url = preview.previewURL else { throw Failure("Quick Look had no item") }
        let previewContents = try String(contentsOf: url, encoding: .utf8)
        try check(url.path == expected.path && previewContents == "Synthetic unified search fixture." &&
                  !preview.isVisible && !NSApp.isActive, "Quick Look did not use the original file offscreen")
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try check(app.localPreview == nil && preview.previewURL == nil && app.searchPresented,
                  "Space closed the search rather than just the preview")
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
        try await verifyFileDefaultActionRegressions(app, fixtures: fileDefaultFixtures)

        if exists("syntax-scenario") { try await verifyRawFileQuery(app) }
        if let fixtures = frecencyFixtures {
            try await verifyFileFrecency(app, project: fixtures.project, success: fixtures.success, failure: fixtures.failure)
            app.showSearch()
            try await verifyQuicklinks(app)
        }
        try await verifyWave2Features(app, fixtures: wave2Fixtures)
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
        let checksBeforeShow = portraitDisplayChecks
        app.dismissSearch()
        app.showSearch()
        try type("archive", into: app)
        try type("?", into: app)
        try check(portraitDisplayChecks == checksBeforeShow && !NSApp.isActive,
                  "showSearch or regular typing invoked CGWindowListCopyWindowInfo display orientation probe")
        try check(commands.resolution == .discovery && commands.selectedEntry?.keyword == "qa" &&
                  commands.entries.count == 6 && commands.entries.contains { $0.commandID == "window" },
                  "missing command chooser or win entry")
        if exists("capture-icons") {
            try capture("lumen-command-chooser.png", appearance: .aqua, window: panel)
            panel.appearance = nil
        }
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try check(commands.selectedEntry?.keyword == "tr", "arrows did not move in the chooser")
        try key(kVK_UpArrow, "\u{f700}", in: app)
        try key(kVK_Return, "\r", in: app)
        try check(commands.resolution == .missingArgument(commandID: "qa"), "chooser submitted rather than filling")
        simulatedPortraitDisplay = true
        defer { simulatedPortraitDisplay = nil }
        try type("win", into: app)
        try check(portraitDisplayChecks == checksBeforeShow + 1 && commands.isWindowCommand &&
                  commands.windowRows.prefix(4).map(\.destination) == [
                    .window(.autoTile), .window(.topHalf), .window(.bottomHalf), .window(.topThird)
                  ],
                  "win did not lazily detect portrait orientation or prioritize portrait splits")
        if exists("capture-icons") {
            try capture("lumen-window-commands.png", appearance: .aqua, window: panel)
            panel.appearance = nil
        }
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
        var semanticQuery = ""
        for (query, filename, original) in [
            ("怎样摆放太阳能板才能让它朝着正午阳光？", "entry-a.md", "midday sun"),
            ("How do I get the clock to run after its battery died?", "entry-b.md", "换上新的电池"),
        ] {
            semanticQuery = query
            try type(query, into: app)
            try await until("real Gemma returned the cross-language source for \(filename)", seconds: 30) {
                model.selectedHit?.name == filename &&
                    model.selectedHit?.isSemanticCandidate == true &&
                    model.selectedHit?.snippet?.contains(original) == true
            }
            let expected = PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
            try check(app.panel.frame.size == expected && abs(app.panel.frame.maxY - idleFrame.maxY) <= 1,
                      "Gemma result did not match PanelGeometry or moved top edge")
            try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
            try await until("Finder action revalidated the real Gemma preview and dismissed search", seconds: 30) {
                self.revealed?.lastPathComponent == filename && !app.searchPresented && model.query.isEmpty
            }
            revealed = nil
            app.showSearch()
        }
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
            self.revealed?.lastPathComponent == "鹿鸣.md" && !app.searchPresented && model.query.isEmpty
        }
        try signal("finish-han-body")
        guard let firstName, let revealDispatch else { throw Failure("missing search or Finder timestamps") }
        print(String(format: "Han control-path timing: input to first name %.1f ms, Command–Return to dispatch %.1f ms",
                     milliseconds(began.duration(to: firstName)), milliseconds(enter.duration(to: revealDispatch))))
        revealed = nil
        app.showSearch()
        try type("鹿鸣", into: app)
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
        let expectedTimingSize = PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults)
        try check(app.panel.frame.size == expectedTimingSize && abs(app.panel.frame.maxY - top) <= 1 &&
                  app.panel.contentView === chrome,
                  "typing or result lane delivery broke anchored PanelGeometry or replaced the launcher")
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("body hit revealed in Finder and dismissed search") {
            self.revealed?.lastPathComponent == "body-match.md" && !app.searchPresented && model.query.isEmpty
        }
        revealed = nil

        // Verify background watch refresh does not close an open Command–K context menu.
        app.showSearch()
        try type("crowded needle", into: app)
        try await until("crowded needle reloaded for Cmd+K watch check") {
            model.hits.count == 60 && !model.searching
        }
        guard let reloadedBody = model.hits.firstIndex(where: { $0.name == "body-match.md" && $0.matched_by == "text" }) else {
            throw Failure("missing reloaded body hit")
        }
        model.selection = model.hits[reloadedBody].path
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
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
        try await until("bundled engine validated the Han Finder action") {
            self.revealed?.lastPathComponent == "鹿鸣.md" && !app.searchPresented && model.query.isEmpty
        }
        guard let firstName, let revealDispatch else { throw Failure("missing bundled search or Finder timestamps") }
        print(String(format: "Bundled Han timing: input to first name %.1f ms, Command–Return to dispatch %.1f ms",
                     milliseconds(began.duration(to: firstName)), milliseconds(enter.duration(to: revealDispatch))))
        revealed = nil
        app.showSearch()
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
        try await until("image match did not pass targeted Finder revalidation") {
            self.revealed?.lastPathComponent == "93a2.png" && !app.searchPresented && model.query.isEmpty
        }
        revealed = nil
        app.showSearch()
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
        try Data().write(to: provider.appendingPathComponent("cloud-quick-look-placeholder.docx"))
        try Data().write(to: provider.appendingPathComponent("cloud-quick-look-inline.docx"))
        let contextIntro = (0..<24).map { "Intro paragraph line \($0) describing background context." }.joined(separator: "\n")
        let contextTail = (0..<24).map { "Trailing paragraph line \($0) continuing later details." }.joined(separator: "\n")
        try Data("\(contextIntro)\nTarget context anchor paragraph with matching text.\n\(contextTail)".utf8)
            .write(to: selected.appendingPathComponent("long-context-fixture.md"))
        let codePreviewSource = """
        struct LumenPreviewFixture {
            let title: String
            func render() -> Bool { !title.isEmpty }
        }
        """
        try Data(codePreviewSource.utf8).write(to: selected.appendingPathComponent("code-preview-fixture.swift"))
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
            try capture("lumen-inline-pdf-dark.png", appearance: .darkAqua, window: app.panel)
            app.panel.appearance = nil
        }
        // Verify matched PDF page selection + content-proportional preview panel sizing.
        let pdfURL = URL(fileURLWithPath: pdfPath)
        if let pdfDoc = PDFDocument(url: pdfURL), let page2 = pdfDoc.page(at: 1) {
            let pageSelections = MacPreviewRenderer.pdfPageSelections(in: pdfDoc, on: page2, highlight: "zircon calibration", snippet: model.selectedHit?.snippet)
            try check(!pageSelections.isEmpty, "matched PDF page highlight produced no PDF selections")
            let pdfSized = LocalPreviewPanel.preferredContentSize(for: pdfURL, page: 2, maxSize: NSSize(width: 1000, height: 760), backingScale: 2)
            try check(pdfSized.height >= 450 && pdfSized.height <= 760 && pdfSized.width >= 400,
                      "PDF adaptive preview sizing out of expected range: \(pdfSized)")
        }
        let sizeDir = directory.appendingPathComponent("adaptive-sizes", isDirectory: true)
        try FileManager.default.createDirectory(at: sizeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sizeDir) }
        func writePNG(name: String, width: Int, height: Int) throws -> URL {
            let fileURL = sizeDir.appendingPathComponent(name)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let data = rep.representation(using: .png, properties: [:]) else {
                throw Failure("could not allocate synthetic PNG fixture \(name)")
            }
            try data.write(to: fileURL)
            return fileURL
        }
        let wideImg = try writePNG(name: "wide.png", width: 1600, height: 800)
        let tallImg = try writePNG(name: "tall.png", width: 800, height: 1600)
        let hugeImg = try writePNG(name: "huge.png", width: 4800, height: 3200)
        let cap = NSSize(width: 900, height: 720)
        let wideSize = LocalPreviewPanel.preferredContentSize(for: wideImg, page: nil, maxSize: cap, backingScale: 2)
        let tallSize = LocalPreviewPanel.preferredContentSize(for: tallImg, page: nil, maxSize: cap, backingScale: 2)
        let hugeSize = LocalPreviewPanel.preferredContentSize(for: hugeImg, page: nil, maxSize: cap, backingScale: 2)
        let docSize = LocalPreviewPanel.preferredContentSize(for: sizeDir.appendingPathComponent("note.md"), page: nil, maxSize: cap, backingScale: 2)
        try check(wideSize.width > wideSize.height && abs((wideSize.width / wideSize.height) - 2.0) < 0.05,
                  "landscape image preview did not preserve 2:1 aspect ratio: \(wideSize)")
        try check(tallSize.height > tallSize.width && abs((tallSize.width / tallSize.height) - 0.5) < 0.1,
                  "portrait image preview did not preserve portrait orientation: \(tallSize)")
        try check(hugeSize.width <= cap.width && hugeSize.height <= cap.height && abs((hugeSize.width / hugeSize.height) - 1.5) < 0.05,
                  "oversized image did not fit within max bounds while preserving 3:2 ratio: \(hugeSize)")
        try check(docSize.height > 600 && docSize.width == 760, "markdown preview did not adopt document reading proportions: \(docSize)")
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

        try type("code-preview-fixture", into: app)
        try await until("name-only code fixture became selectable") {
            model.selectedHit?.name == "code-preview-fixture.swift" && model.selectedHit?.snippet == nil
        }
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("Command–Y did not open inline code preview for name-only .swift file") {
            if case .ready(let selection, let doc) = app.inlinePreview.state {
                return selection.kind == .plainText && doc.isCode &&
                    doc.text?.contains("struct LumenPreviewFixture") == true &&
                    app.inlinePreview.activeWebContainer != nil
            }
            return false
        }
        if let codeContainer = app.inlinePreview.activeWebContainer {
            let deadline = ContinuousClock.now + .seconds(10)
            var loaded = false
            while ContinuousClock.now < deadline {
                if let ok = await codeContainer.evaluateVerificationJS(
                    "Boolean(document.body && document.body.innerText && document.body.innerText.includes('struct LumenPreviewFixture'))"
                ) as? Bool, ok {
                    loaded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(loaded, "inline code WebKit view did not render Swift fixture source")
            if exists("capture-preview"), let snapshot = await codeContainer.captureSnapshot(),
               let tiff = snapshot.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("lumen-inline-code-preview.png"))
            }
        }
        app.panel.appearance = nil
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.inlinePreview.isOpen && app.searchPresented, "Escape did not close inline code preview cleanly")

        try await verifyUnlimitedAndCloudPreview(app, provider: provider)
        try await verifyCloudQuickLook(app, provider: provider)
        try await verifyRichPreviewExperience(app, selected: selected)
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
        let docxPlaceholder = provider.appendingPathComponent("cloud-quick-look-placeholder.docx")
        let started = previewDownloadsStarted
        let cancelled = previewDownloadsCancelled
        try type("cloud-quick-look-", into: app)
        try await until("name-only provider text and docx files were not indexed") {
            [resident, placeholder, docxPlaceholder].allSatisfy { url in
                model.hits.contains { $0.path == url.path && $0.isCloudReference && $0.snippet == nil }
            }
        }
        func select(_ url: URL) throws {
            guard let hit = model.hits.first(where: { $0.path == url.path }) else {
                throw Failure("missing provider result: \(url.lastPathComponent)")
            }
            app.commands.choose(.file(hit), in: model)
        }
        func cmdY() throws { try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command]) }
        func space() throws {
            app.panel.browsing = true
            try key(kVK_Space, " ", in: app, throughPanel: true)
        }
        func escape() throws { try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true) }

        // Resident .txt: Cmd+Y shows inline plainText (0 downloads), Space shows Quick Look window (0 downloads).
        try select(resident)
        try cmdY()
        try await until("Cmd+Y did not open inline plain-text preview for resident cloud text file") {
            if case .ready(let sel, let doc) = app.inlinePreview.state {
                return sel.url == resident && sel.kind == .plainText && doc.text == "Resident Quick Look text fixture." && app.localPreview == nil
            }
            return false
        }
        try check(previewDownloadsStarted == started, "resident cloud text requested a download on Cmd+Y")
        try escape()
        try space()
        try await until("Space did not open Quick Look for the resident cloud text file") {
            app.localPreview?.previewURL == resident
        }
        try check(previewDownloadsStarted == started, "resident cloud text requested a download on Space")
        try escape()

        // Binary cloud placeholder (.docx): right-click preview & Cmd+Y show inline rich-doc download ring;
        // Space shows .windowHandoff download ring -> Quick Look handoff.
        guard let docxHit = model.hits.first(where: { $0.path == docxPlaceholder.path }) else {
            throw Failure("missing provider docx placeholder hit")
        }
        try check(model.selectedHit?.path == resident.path, "resident row was not selected before unselected right-click preview")
        app.perform(.preview, on: docxHit)
        try await until("right-click preview on an unselected docx placeholder did not select and start download") {
            if case .downloading(let item, 0.4) = app.inlinePreview.state {
                return item.url == docxPlaceholder && item.kind == .richDocument(.word) && model.selectedHit?.path == docxPlaceholder.path
            }
            return false
        }
        try escape()
        try await until("Escape did not cancel the right-click docx download") { self.previewDownloadsCancelled == cancelled + 1 }

        try select(docxPlaceholder)
        try check(app.inlinePreview.state == .closed && app.localPreview == nil && previewDownloadsStarted == started + 1,
                  "selecting a cloud docx file requested a preview without a shortcut")
        try cmdY()
        try await until("Cmd+Y did not show the 40% download ring for the cloud docx file") {
            if case .downloading(let item, 0.4) = app.inlinePreview.state {
                return item.url == docxPlaceholder && item.kind == .richDocument(.word) &&
                    app.inlinePreview.isOpen && app.localPreview == nil
            }
            return false
        }
        try escape()
        try await until("Escape did not cancel the Cmd+Y docx download") { self.previewDownloadsCancelled == cancelled + 2 }
        try space()
        try await until("Space did not show the 40% .windowHandoff download ring for the cloud docx file") {
            if case .downloading(let item, 0.4) = app.inlinePreview.state {
                return item.url == docxPlaceholder && item.kind == .windowHandoff &&
                    app.inlinePreview.isOpen && app.localPreview == nil
            }
            return false
        }
        previewDownloadRelease?.yield(())
        try await until("hydrated cloud docx did not replace the download ring with LocalPreviewPanel") {
            app.localPreview?.previewURL == docxPlaceholder && app.inlinePreview.state == .closed
        }
        try escape()

        // Cloud text placeholder (.txt): Cmd+Y hydrates into inline plainText; Space hydrates into Quick Look window.
        try select(placeholder)
        try check(app.inlinePreview.state == .closed && app.localPreview == nil && previewDownloadsStarted == started + 3,
                  "selecting a cloud text placeholder started a download without a shortcut")
        try cmdY()
        try await until("Cmd+Y did not show the 40% download ring for the cloud text file") {
            if case .downloading(let item, 0.4) = app.inlinePreview.state {
                return item.url == placeholder && item.kind == .plainText && app.inlinePreview.isOpen && app.localPreview == nil
            }
            return false
        }
        try escape()
        try await until("Escape did not cancel the Cmd+Y text placeholder download") { self.previewDownloadsCancelled == cancelled + 3 }
        try space()
        try await until("Space did not show the 40% .windowHandoff download ring for the cloud text file") {
            if case .downloading(let item, 0.4) = app.inlinePreview.state {
                return item.url == placeholder && item.kind == .windowHandoff && app.inlinePreview.isOpen && app.localPreview == nil
            }
            return false
        }
        try escape()
        try await until("Escape did not cancel the Space Quick Look download") { self.previewDownloadsCancelled == cancelled + 4 }
        try check(app.inlinePreview.state == .closed && app.localPreview == nil && app.searchPresented &&
                  !FileManager.default.fileExists(atPath: Self.previewHydrated(placeholder, in: directory).path),
                  "Escape hydrated the text placeholder, left a preview open, or dismissed search")
        try space()
        try await until("second Space did not restart download for the cloud text file") {
            if case .downloading(let item, 0.4) = app.inlinePreview.state {
                return item.url == placeholder && item.kind == .windowHandoff
            }
            return false
        }
        previewDownloadRelease?.yield(())
        try await until("hydrated cloud text did not replace the download ring with LocalPreviewPanel") {
            app.localPreview?.previewURL == placeholder && app.inlinePreview.state == .closed
        }
        try escape()
        // Now resident on disk: Cmd+Y opens inline plainText immediately without another download.
        try cmdY()
        try await until("hydrated cloud text did not open inline plainText cleanly") {
            if case .ready(let item, let doc) = app.inlinePreview.state {
                return item.url == placeholder && item.kind == .plainText && doc.text == "Hydrated Quick Look text fixture."
            }
            return false
        }
        try check(previewDownloadsStarted == started + 6 && previewDownloadsCancelled == cancelled + 4,
                  "Quick Look / inline hydration started extra downloads or did not cancel exactly four times")
        try escape()

        // Releasing Cmd+Y on a cloud .docx hydrates cleanly into inline rich preview without opening LocalPreviewPanel.
        let docxInline = provider.appendingPathComponent("cloud-quick-look-inline.docx")
        try select(docxInline)
        try cmdY()
        try await until("Cmd+Y did not show the 40% download ring for cloud inline docx") {
            if case .downloading(let item, 0.4) = app.inlinePreview.state {
                return item.url == docxInline && item.kind == .richDocument(.word) &&
                    app.inlinePreview.isOpen && app.localPreview == nil
            }
            return false
        }
        previewDownloadRelease?.yield(())
        try await until("hydrated Cmd+Y cloud docx did not stay in inline preview") {
            if case .ready(let item, let doc) = app.inlinePreview.state {
                return item.url == docxInline && item.kind == .richDocument(.word) &&
                    doc.richHTML != nil && app.inlinePreview.isOpen && app.localPreview == nil
            }
            return false
        }
        try check(previewDownloadsStarted == started + 7 && previewDownloadsCancelled == cancelled + 4,
                  "inline cloud docx hydration started extra downloads")
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
        print("Cloud preview & Quick Look passed (unified .txt/.docx Space + Cmd+Y, progress, Escape cancel, hydrated inline & window handoff)")
    }

    private func verifyRichPreviewExperience(_ app: AppDelegate, selected: URL) async throws {
        let model = app.model
        let fm = FileManager.default
        let richDir = selected.appendingPathComponent("rich-preview", isDirectory: true)
        try fm.createDirectory(at: richDir, withIntermediateDirectories: true)

        func writeSolidPNG(to url: URL, width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) throws {
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure("could not create CGContext for \(url.lastPathComponent)")
            }
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let cgImage = ctx.makeImage() else { throw Failure("could not create CGImage") }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw Failure("could not encode PNG for \(url.lastPathComponent)")
            }
            try png.write(to: url)
        }

        try writeSolidPNG(to: richDir.appendingPathComponent("hero-light.png"), width: 220, height: 72, r: 0.16, g: 0.42, b: 0.88)
        try writeSolidPNG(to: richDir.appendingPathComponent("hero-dark.png"), width: 220, height: 72, r: 0.94, g: 0.56, b: 0.14)
        try writeSolidPNG(to: richDir.appendingPathComponent("diagram.png"), width: 180, height: 80, r: 0.12, g: 0.65, b: 0.45)
        try Data().write(to: richDir.appendingPathComponent("cloud-md-placeholder.png"))

        let mdFiller = (1...32).map { "Section paragraph \($0): deterministic local index and WebKit preview pipeline details." }
            .joined(separator: "\n\n")
        let markdownSource = """
        # Lumen Rich Preview Architecture

        <p>
          <picture>
            <source media="(prefers-color-scheme: dark)" srcset="hero-dark.png">
            <img src="hero-light.png" alt="Hero Banner" width="220" height="72">
          </picture>
        </p>

        <p>
          <img src="https://img.shields.io/badge/Build-Passing-brightgreen" alt="CI Badge">
        </p>

        ![Architecture Diagram](diagram.png)

        ![Cloud Image](cloud-md-placeholder.png)

        ## Quarterly Metrics

        | Component | Latency | Mode |
        | :--- | ---: | :--- |
        | Name Index | 1.1 ms | Local |
        | WebKit Preview | 18 ms | Offline |

        ```swift
        let previewReady = true
        ```

        \(mdFiller)

        ## Bottom Anchor

        Final finding: LumenMarkdownNeedle verified across inline and floating WebKit previews.
        """
        let mdURL = richDir.appendingPathComponent("rich-fixture.md")
        try Data(markdownSource.utf8).write(to: mdURL)

        let docxURL = richDir.appendingPathComponent("rich-fixture.docx")
        var docxParagraphs = ["季度研发复盘与多模态架构设计"]
        for i in 1...28 {
            docxParagraphs.append("第 \(i) 节：本段用于验证原生 Word 文档长文滚动排版与离线安全性。")
        }
        docxParagraphs.append("核心结论：LumenDocxNeedleKeyword 已在 WebKit 中正确高亮显示。")
        try Self.makeDOCXFixture(paragraphs: docxParagraphs).write(to: docxURL)

        let xlsxURL = richDir.appendingPathComponent("rich-budget.xlsx")
        try Self.makeXLSXFixture(sheets: [
            (name: "概览", rows: [
                [("A", "模块"), ("B", "负责人"), ("C", "状态")],
                [("A", "全盘检索"), ("B", "陈敏"), ("C", "已上线")],
                [("A", "原生预览"), ("B", "Lumen"), ("C", "验收中")],
            ]),
            (name: "季度预算", rows: [
                [("A", "科目"), ("C", "预算明细")],
                [("A", "研发算力"), ("C", "LumenXlsxSheet2Needle 专项预算 ¥128,000")],
                [("A", "测试设备"), ("C", "Mac Studio M5 Max")],
            ]),
        ]).write(to: xlsxURL)

        let pptxURL = richDir.appendingPathComponent("rich-deck.pptx")
        try Self.makePPTXFixture(slides: ["LumenPptxDeckNeedle Roadmap Slide 1"]).write(to: pptxURL)

        model.rebuildSavedIndex()
        try await until("rich preview fixtures were indexed") {
            !model.scopePending && model.canSearch && model.watchState == .running &&
                model.contentCoverage?.pending == 0
        }

        func cmdY() throws { try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command]) }
        func space() throws {
            app.panel.browsing = true
            try key(kVK_Space, " ", in: app, throughPanel: true)
        }
        func escape() throws { try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true) }

        func waitJS<T>(_ container: DocumentWebPreviewContainer, label: String,
                       evaluate: @escaping () async -> T?) async throws -> T {
            let deadline = ContinuousClock.now + .seconds(12)
            while ContinuousClock.now < deadline {
                if let value = await evaluate() { return value }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw Failure("Timed out waiting for WebKit preview JS: \(label)")
        }

        func captureWeb(_ filename: String, appearance: NSAppearance.Name,
                        container: DocumentWebPreviewContainer, window: NSWindow) async throws {
            let priorWindowAppearance = window.appearance
            let priorAppAppearance = NSApp.appearance
            defer {
                window.appearance = priorWindowAppearance
                NSApp.appearance = priorAppAppearance
            }
            let targetAppearance = NSAppearance(named: appearance)
            window.appearance = targetAppearance
            NSApp.appearance = targetAppearance
            window.contentView?.layoutSubtreeIfNeeded()
            let wantDark = appearance == .darkAqua
            _ = try await waitJS(container, label: "appearance \(filename)") {
                let dark = await container.evaluateVerificationJS("window.matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
                return dark == wantDark ? true : nil
            }
            try await Task.sleep(for: .milliseconds(50))
            guard let snapshot = await container.captureSnapshot(),
                  let tiff = snapshot.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]),
                  png.count > 1000 else {
                throw Failure("failed to capture non-empty WebKit snapshot for \(filename)")
            }
            try png.write(to: directory.appendingPathComponent(filename))
        }

        let downloadsBefore = previewDownloadsStarted

        func checkMarkdownWebPreview(_ container: DocumentWebPreviewContainer, label: String) async throws {
            let info: [String: Any] = try await waitJS(container, label: label) {
                await container.evaluateVerificationJS("""
                (() => {
                  const p = window.__lumenPreview;
                  if (!p || !(p.matchCount >= 1)) return null;
                  const imgs = Array.from(document.querySelectorAll('img'));
                  const httpImgs = imgs.filter(i => /^https?:/i.test(i.getAttribute('src') || ''));
                  const loadedLocal = imgs.filter(i => (i.getAttribute('src') || '').startsWith('lumen-local://') && i.complete && i.naturalWidth > 0);
                  const mark = document.querySelector('mark.lumen-hit');
                  const rect = mark ? mark.getBoundingClientRect() : null;
                  if (!rect || loadedLocal.length < 2) return null;
                  return {
                    matchCount: p.matchCount,
                    httpCount: httpImgs.length,
                    loadedLocal: loadedLocal.length,
                    badges: document.querySelectorAll('.lumen-remote-badge').length,
                    scrollY: window.scrollY,
                    top: rect.top,
                    bottom: rect.bottom,
                    vh: window.innerHeight
                  };
                })()
                """) as? [String: Any]
            }
            try check((info["httpCount"] as? Int) == 0 &&
                      (info["badges"] as? Int ?? 0) >= 1 &&
                      (info["matchCount"] as? Int ?? 0) >= 1 &&
                      (info["loadedLocal"] as? Int ?? 0) >= 2 &&
                      ((info["scrollY"] as? Double ?? 0) > 0) &&
                      ((info["top"] as? Double ?? -999) >= -24) &&
                      ((info["bottom"] as? Double ?? 99999) <= (info["vh"] as? Double ?? 0) + 24),
                      "\(label) failed: \(info)")
            try check(previewDownloadsStarted == downloadsBefore, "\(label) triggered a cloud image download")
        }

        func checkXLSXSheet2WebPreview(_ container: DocumentWebPreviewContainer, label: String) async throws {
            let info: [String: Any] = try await waitJS(container, label: label) {
                await container.evaluateVerificationJS("""
                (() => {
                  const p = window.__lumenPreview;
                  const sheetIndex = p ? (typeof p.activeSheetIndex === 'number' ? p.activeSheetIndex : p.activeSheet) : -1;
                  if (!p || !(p.matchCount >= 1) || sheetIndex !== 1) return null;
                  const panel1 = document.querySelector('.lumen-sheet-panel[data-sheet-idx="1"]');
                  if (!panel1 || getComputedStyle(panel1).display === 'none') return null;
                  const hitInSheet2 = panel1.querySelector('mark.lumen-hit');
                  if (!hitInSheet2) return null;
                  const activeTab = document.querySelector('.lumen-sheet-tabs [aria-selected="true"], .lumen-sheet-tabs .active, .lumen-sheet-tabs .is-active, .lumen-sheet-tabs .selected');
                  const tabsText = (document.querySelector('.lumen-sheet-tabs') || {}).textContent || '';
                  return {
                    matchCount: p.matchCount,
                    activeSheet: sheetIndex,
                    activeSheetName: typeof p.activeSheet === 'string' ? p.activeSheet : '',
                    tabText: activeTab ? activeTab.textContent : '',
                    tabsText: tabsText,
                    hitText: hitInSheet2.textContent || ''
                  };
                })()
                """) as? [String: Any]
            }
            let tabText = info["tabText"] as? String ?? ""
            let tabsText = info["tabsText"] as? String ?? ""
            let activeSheetName = info["activeSheetName"] as? String ?? ""
            try check((info["activeSheet"] as? Int) == 1 &&
                      (info["matchCount"] as? Int ?? 0) >= 1 &&
                      tabsText.contains("季度预算") &&
                      (activeSheetName.isEmpty || activeSheetName == "季度预算") &&
                      (tabText.isEmpty || tabText.contains("季度预算")),
                      "\(label) did not auto-activate Sheet 2 (季度预算): \(info)")
        }

        // 1. Markdown fixture (headings, table, <picture>, remote badge pill, cloud skip, body highlight + scroll).
        try type("LumenMarkdownNeedle", into: app)
        try await until("Markdown body hit was not selectable") {
            model.selectedHit?.path == IndexScope.folderPath(mdURL) && model.selectedHit?.snippet != nil
        }
        try cmdY()
        try await until("Markdown Cmd+Y did not open inline rich HTML preview") {
            if case .ready(let sel, let doc) = app.inlinePreview.state {
                return sel.kind == .richDocument(.markdown) && doc.richHTML != nil &&
                    app.inlinePreview.activeWebContainer != nil && app.localPreview == nil
            }
            return false
        }
        guard let mdInlineContainer = app.inlinePreview.activeWebContainer else {
            throw Failure("missing inline WebKit container for Markdown")
        }
        try await checkMarkdownWebPreview(mdInlineContainer, label: "inline markdown diagnostics")
        if exists("capture-preview") {
            try await captureWeb("preview-inline-md.png", appearance: .aqua, container: mdInlineContainer, window: app.panel)
        }
        try escape()
        try check(!app.inlinePreview.isOpen, "Escape did not close inline markdown preview")

        try space()
        try await until("Markdown Space did not open LocalPreviewPanel with WebKit") {
            app.localPreview?.previewURL?.path == IndexScope.folderPath(mdURL) &&
                app.localPreview?.webPreviewContainer != nil
        }
        guard let mdWindow = app.localPreview, let mdWindowContainer = mdWindow.webPreviewContainer else {
            throw Failure("missing LocalPreviewPanel WebKit container for Markdown")
        }
        try await checkMarkdownWebPreview(mdWindowContainer, label: "window markdown diagnostics")
        if exists("capture-preview") {
            try await captureWeb("preview-md-light.png", appearance: .aqua, container: mdWindowContainer, window: mdWindow)
            try await captureWeb("preview-md-dark.png", appearance: .darkAqua, container: mdWindowContainer, window: mdWindow)
        }
        try escape()
        try check(app.localPreview == nil, "Escape did not close markdown LocalPreviewPanel")

        // 2. Real repo README.md parsed by DocumentPreviewRenderer.
        let repoCandidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent(),
            URL(fileURLWithPath: fm.currentDirectoryPath),
        ]
        guard let repoRoot = repoCandidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("README.md").path) }) else {
            throw Failure("could not locate repo README.md from candidates: \(repoCandidates.map(\.path))")
        }
        let readmeURL = repoRoot.appendingPathComponent("README.md")
        guard let readmeContent = DocumentPreviewRenderer.render(
            url: readmeURL,
            format: .markdown,
            evidence: nil,
            isPending: { _ in false }
        ) else {
            throw Failure("DocumentPreviewRenderer returned nil for repo README.md")
        }
        try check(readmeContent.localResources.values.contains { $0.path.contains("/assets/readme/") && $0.pathExtension.lowercased() == "png" },
                  "README.md did not register local assets/readme/*.png resources: \(readmeContent.localResources.values.map(\.path))")
        try check(readmeContent.html.range(of: #"<(?:img|source)\b[^>]*\b(?:src|srcset)\s*=\s*["']https?://"#,
                                           options: [.regularExpression, .caseInsensitive]) == nil,
                  "README.md rendered HTML still contained external http(s) image sources")

        // 3. .docx zip fixture: filename hit stays inline; body hit highlights mark.lumen-hit >= 1 in Cmd+Y and Space.
        try type("rich-fixture.docx", into: app)
        try await until("DOCX filename hit was not selectable") { model.selectedHit?.path == IndexScope.folderPath(docxURL) }
        try cmdY()
        try await until("DOCX filename Cmd+Y did not open inline rich preview") {
            if case .ready(let sel, let doc) = app.inlinePreview.state {
                return sel.kind == .richDocument(.word) && doc.richHTML != nil &&
                    app.inlinePreview.activeWebContainer != nil && app.localPreview == nil
            }
            return false
        }
        if let docxFilenameContainer = app.inlinePreview.activeWebContainer {
            let hasChineseTitle: Bool = try await waitJS(docxFilenameContainer, label: "docx filename content") {
                let ok = await docxFilenameContainer.evaluateVerificationJS(
                    "(document.body && document.body.innerText.includes('季度研发复盘与多模态架构设计')) ? true : null"
                ) as? Bool
                return ok
            }
            try check(hasChineseTitle && app.localPreview == nil, "DOCX filename inline preview missing Chinese content")
        }
        try escape()

        try type("LumenDocxNeedleKeyword", into: app)
        try await until("DOCX body hit was not selectable") {
            model.selectedHit?.path == IndexScope.folderPath(docxURL) && model.selectedHit?.snippet != nil
        }
        try cmdY()
        try await until("DOCX body Cmd+Y did not open inline rich preview") {
            if case .ready(let sel, let doc) = app.inlinePreview.state {
                return sel.kind == .richDocument(.word) && doc.richHTML != nil &&
                    app.inlinePreview.activeWebContainer != nil && app.localPreview == nil
            }
            return false
        }
        guard let docxInlineContainer = app.inlinePreview.activeWebContainer else {
            throw Failure("missing inline WebKit container for DOCX")
        }
        let docxInlineHits: Int = try await waitJS(docxInlineContainer, label: "inline docx match") {
            guard let count = await docxInlineContainer.evaluateVerificationJS("window.__lumenPreview?.matchCount") as? Int,
                  count >= 1 else { return nil }
            return count
        }
        try check(docxInlineHits >= 1 && app.localPreview == nil, "DOCX inline preview missed highlight")
        try escape()

        try space()
        try await until("DOCX Space did not open LocalPreviewPanel") {
            app.localPreview?.previewURL?.path == IndexScope.folderPath(docxURL) &&
                app.localPreview?.webPreviewContainer != nil
        }
        guard let docxWindow = app.localPreview, let docxWindowContainer = docxWindow.webPreviewContainer else {
            throw Failure("missing LocalPreviewPanel WebKit container for DOCX")
        }
        let docxWindowHits: Int = try await waitJS(docxWindowContainer, label: "window docx match") {
            guard let count = await docxWindowContainer.evaluateVerificationJS("window.__lumenPreview?.matchCount") as? Int,
                  count >= 1 else { return nil }
            return count
        }
        try check(docxWindowHits >= 1, "DOCX window preview missed highlight")
        if exists("capture-preview") {
            try await captureWeb("preview-docx-light.png", appearance: .aqua, container: docxWindowContainer, window: docxWindow)
        }
        try escape()

        // 4. .xlsx 2-sheet zip fixture: filename hit stays inline; body hit on Sheet 2 activates 季度预算 + highlights cell.
        try type("rich-budget.xlsx", into: app)
        try await until("XLSX filename hit was not selectable") { model.selectedHit?.path == IndexScope.folderPath(xlsxURL) }
        try cmdY()
        try await until("XLSX filename Cmd+Y did not open inline rich preview") {
            if case .ready(let sel, let doc) = app.inlinePreview.state {
                return sel.kind == .richDocument(.spreadsheet) && doc.richHTML != nil && app.localPreview == nil
            }
            return false
        }
        try escape()

        try type("LumenXlsxSheet2Needle", into: app)
        try await until("XLSX body hit was not selectable") {
            model.selectedHit?.path == IndexScope.folderPath(xlsxURL) && model.selectedHit?.snippet != nil
        }
        try cmdY()
        try await until("XLSX body Cmd+Y did not open inline rich preview") {
            if case .ready(let sel, let doc) = app.inlinePreview.state {
                return sel.kind == .richDocument(.spreadsheet) && doc.richHTML != nil &&
                    app.inlinePreview.activeWebContainer != nil && app.localPreview == nil
            }
            return false
        }
        guard let xlsxInlineContainer = app.inlinePreview.activeWebContainer else {
            throw Failure("missing inline WebKit container for XLSX")
        }
        try await checkXLSXSheet2WebPreview(xlsxInlineContainer, label: "inline xlsx sheet 2 match")
        if exists("capture-preview") {
            try await captureWeb("preview-inline-xlsx.png", appearance: .aqua, container: xlsxInlineContainer, window: app.panel)
        }
        try escape()

        try space()
        try await until("XLSX Space did not open LocalPreviewPanel") {
            app.localPreview?.previewURL?.path == IndexScope.folderPath(xlsxURL) &&
                app.localPreview?.webPreviewContainer != nil
        }
        guard let xlsxWindow = app.localPreview, let xlsxWindowContainer = xlsxWindow.webPreviewContainer else {
            throw Failure("missing LocalPreviewPanel WebKit container for XLSX")
        }
        try await checkXLSXSheet2WebPreview(xlsxWindowContainer, label: "window xlsx sheet 2 match")
        if exists("capture-preview") {
            try await captureWeb("preview-xlsx-dark.png", appearance: .darkAqua, container: xlsxWindowContainer, window: xlsxWindow)
        }
        try escape()

        // 5. .pptx zip fixture: filename hit stays inline (.inlineQuickLook); Space opens LocalPreviewPanel.
        try type("rich-deck.pptx", into: app)
        try await until("PPTX filename hit was not selectable") { model.selectedHit?.path == IndexScope.folderPath(pptxURL) }
        try cmdY()
        try await until("PPTX Cmd+Y did not open inlineQuickLook without opening LocalPreviewPanel") {
            if case .ready(let sel, let doc) = app.inlinePreview.state {
                return sel.kind == .inlineQuickLook &&
                    doc.quickLookURL?.path == IndexScope.folderPath(pptxURL) &&
                    app.localPreview == nil
            }
            return false
        }
        try escape()
        try space()
        try await until("PPTX Space did not open LocalPreviewPanel") {
            app.localPreview?.previewURL?.path == IndexScope.folderPath(pptxURL)
        }
        try escape()
        try check(app.localPreview == nil && !app.inlinePreview.isOpen, "Escape left PPTX preview open")
        print("Rich preview experience passed (Markdown + README.md, DOCX, 2-sheet XLSX tab jump, PPTX inline Quick Look & Space)")
    }

    private nonisolated static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private nonisolated static func makeStoredZip(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        func append16(_ data: inout Data, _ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func append32(_ data: inout Data, _ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        for (name, content) in entries {
            let nameData = Data(name.utf8)
            let crc = UInt32(content.withUnsafeBytes {
                crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))
            })
            let offset = UInt32(out.count)
            let size = UInt32(content.count)
            append32(&out, 0x04034b50)
            append16(&out, 20)
            append16(&out, 0x0800)
            append16(&out, 0)
            append16(&out, 0); append16(&out, 0)
            append32(&out, crc); append32(&out, size); append32(&out, size)
            append16(&out, UInt16(nameData.count)); append16(&out, 0)
            out.append(nameData)
            out.append(content)
            append32(&central, 0x02014b50)
            append16(&central, 20); append16(&central, 20)
            append16(&central, 0x0800); append16(&central, 0)
            append16(&central, 0); append16(&central, 0)
            append32(&central, crc); append32(&central, size); append32(&central, size)
            append16(&central, UInt16(nameData.count)); append16(&central, 0); append16(&central, 0)
            append16(&central, 0); append16(&central, 0); append32(&central, 0)
            append32(&central, offset)
            central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(central.count)
        out.append(central)
        append32(&out, 0x06054b50)
        append16(&out, 0); append16(&out, 0)
        append16(&out, UInt16(entries.count)); append16(&out, UInt16(entries.count))
        append32(&out, cdSize); append32(&out, cdOffset)
        append16(&out, 0)
        return out
    }

    private nonisolated static func makeDOCXFixture(paragraphs: [String]) -> Data {
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let body = paragraphs.map { "<w:p><w:r><w:t>\(xmlEscaped($0))</w:t></w:r></w:p>" }.joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>\(body)</w:body>
        </w:document>
        """
        return makeStoredZip([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("word/document.xml", Data(document.utf8)),
        ])
    }

    private nonisolated static func makeXLSXFixture(sheets: [(name: String, rows: [[(col: String, value: String)]])]) -> Data {
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        var shared: [String] = []
        var sharedIndex: [String: Int] = [:]
        func intern(_ text: String) -> Int {
            if let existing = sharedIndex[text] { return existing }
            let idx = shared.count
            shared.append(text)
            sharedIndex[text] = idx
            return idx
        }
        var entries: [(String, Data)] = [("_rels/.rels", Data(rootRels.utf8))]
        var sheetOverrides = ""
        var workbookSheets = ""
        var workbookRels = ""
        for (idx, sheet) in sheets.enumerated() {
            let num = idx + 1
            sheetOverrides += "<Override PartName=\"/xl/worksheets/sheet\(num).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            workbookSheets += "<sheet name=\"\(xmlEscaped(sheet.name))\" sheetId=\"\(num)\" r:id=\"rId\(num)\"/>"
            workbookRels += "<Relationship Id=\"rId\(num)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(num).xml\"/>"
            var rowsXML = ""
            for (rowOffset, row) in sheet.rows.enumerated() {
                let rowNum = rowOffset + 1
                let cellsXML = row.map { cell -> String in
                    let strIdx = intern(cell.value)
                    return "<c r=\"\(cell.col)\(rowNum)\" t=\"s\"><v>\(strIdx)</v></c>"
                }.joined()
                rowsXML += "<row r=\"\(rowNum)\">\(cellsXML)</row>"
            }
            let sheetXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>\(rowsXML)</sheetData>
            </worksheet>
            """
            entries.append(("xl/worksheets/sheet\(num).xml", Data(sheetXML.utf8)))
        }
        let sstItems = shared.map { "<si><t>\(xmlEscaped($0))</t></si>" }.joined()
        let sharedStringsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(shared.count)" uniqueCount="\(shared.count)">\(sstItems)</sst>
        """
        let workbookXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>\(workbookSheets)</sheets>
        </workbook>
        """
        let workbookRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(workbookRels)</Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
          \(sheetOverrides)
        </Types>
        """
        entries.append(("[Content_Types].xml", Data(contentTypes.utf8)))
        entries.append(("xl/workbook.xml", Data(workbookXML.utf8)))
        entries.append(("xl/_rels/workbook.xml.rels", Data(workbookRelsXML.utf8)))
        entries.append(("xl/sharedStrings.xml", Data(sharedStringsXML.utf8)))
        return makeStoredZip(entries)
    }

    private nonisolated static func makePPTXFixture(slides: [String]) -> Data {
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        </Relationships>
        """
        var slideOverrides = ""
        var entries: [(String, Data)] = [("_rels/.rels", Data(rels.utf8))]
        for (idx, text) in slides.enumerated() {
            let num = idx + 1
            slideOverrides += "<Override PartName=\"/ppt/slides/slide\(num).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            let slideXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
              <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>\(xmlEscaped(text))</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
            </p:sld>
            """
            entries.append(("ppt/slides/slide\(num).xml", Data(slideXML.utf8)))
        }
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          \(slideOverrides)
        </Types>
        """
        entries.append(("[Content_Types].xml", Data(contentTypes.utf8)))
        return makeStoredZip(entries)
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
        try await verifyV061SettingsAndLocalEmbedding(app, settings: settings, session: session)
        settings.close()
        if case .idle = model.fileDiagnosis {} else { throw Failure("closing settings retained a selected file report") }
        try signal("fail-watch")
        try await until("Settings and menu still report when watching fails while launcher stays calm") {
            model.watchState == .failed &&
                model.activityTitle == model.t("文件监听已停止", "File watching stopped") &&
                model.launcherActivityTitle == nil
        }
        let leaseTitle = model.title(
            for: LauncherNotice(.watch, "cannot acquire index writer lease; another index or watch may be running")
        )
        try check(leaseTitle.contains("写锁") || leaseTitle.contains("index lock"),
                  "writer lease notice title fell back to permissions wording: \(leaseTitle)")
        try check(!leaseTitle.contains("访问权限") && !leaseTitle.contains("verify access"),
                  "writer lease notice falsely reported permissions issue: \(leaseTitle)")
        let permissionTitle = model.title(
            for: LauncherNotice(.watch, "open index writer lease: Permission denied")
        )
        try check(!permissionTitle.contains("写锁") && !permissionTitle.contains("index lock"),
                  "permission error on writer lease falsely reported lock contention: \(permissionTitle)")

        try? FileManager.default.removeItem(at: directory.appendingPathComponent("fail-watch"))
        try signal("lease-once")
        model.restartWatcher()
        try await until("watcher auto-retried transient writer lease contention and recovered") {
            model.watchState == .running && model.watchNotice == nil
        }
        print("Settings smoke passed (shared window, shortcut, draft, exact-scope rebuild, Apply, file diagnostics, and watcher lease recovery)")
    }

    private func captureSettings(_ window: NSPanel, session: SettingsSession) async throws {
        let app = NSApp.delegate as? AppDelegate
        let restoredHotKey = app?.model.hotKey == nil
        if let app, restoredHotKey,
           let sampleKey = try? event(kVK_ANSI_Z, "Z", in: app, flags: [.command, .control, .shift]) {
            app.recordShortcut(sampleKey)
        }
        defer { if restoredHotKey { app?.disableShortcut() } }
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
        try check(app.contextActions.items.map(\.id) == [
            "open", "reveal", "preview", "quick-look",
            "copy-name", "copy-path", "copy-file", "search-in-folder", "open-in-terminal", "open-with",
        ],
                  "resident cloud Cmd+K actions were incomplete: \(app.contextActions.items.map(\.id))")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
        try await until("Cmd+Y did not open inline plain-text preview for resident provider file") {
            if case .ready(let sel, let doc) = app.inlinePreview.state {
                return sel.url.path == hit.path && sel.kind == .plainText && doc.text == "Synthetic provider path."
            }
            return false
        }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        app.panel.browsing = true
        try key(kVK_Space, " ", in: app, throughPanel: true)
        try await until("Space did not open Quick Look for the resident provider file") { app.localPreview?.previewURL?.path == hit.path }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        revealed = nil
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("Command–Return revealed the resident cloud file and dismissed search") {
            self.revealed?.path == hit.path && !app.searchPresented && model.query.isEmpty
        }
        try check(opened == nil, "Finder action unexpectedly opened the file")
        revealed = nil
        app.showSearch()
        try type("cloudledger", into: app)
        try await until("provider metadata result reloaded for Return open") {
            model.selectedHit?.path == hit.path && !model.searching
        }
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
                self.exists("capped-gemma-query-started") && !model.semanticBusy &&
                app.panel.frame.size == enrichedSize
        }
        try check(lineCount("semantic-serve-launches") == 1 && app.panel.frame == frame,
                  "capped search restarted the worker or resized the panel (launches=\(lineCount("semantic-serve-launches")), got=\(app.panel.frame), expected=\(frame))")

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
            try await until("Cmd+Y allowed a 1-level symlinked resident plain-text file") {
                if case .ready(let sel, let doc) = app.inlinePreview.state {
                    return sel.url.path == replacedPath && sel.kind == .plainText &&
                        doc.text == "The archive appears only in the body of this document."
                }
                return false
            }
            try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
            app.panel.browsing = true
            try key(kVK_Space, " ", in: app, throughPanel: true)
            try await until("Quick Look allowed a 1-level symlinked resident file") {
                app.localPreview?.previewURL?.path == replacedPath
            }
            try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
            try FileManager.default.removeItem(at: replaced)
            try key(kVK_ANSI_Y, "y", in: app, throughPanel: true, flags: [.command])
            try await until("inline preview rejected a genuinely missing file before the watcher ran") {
                if case .unavailable(let sel, .missing) = app.inlinePreview.state { return sel.url.path == replacedPath }
                return false
            }
            try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
            app.panel.browsing = true
            try key(kVK_Space, " ", in: app, throughPanel: true)
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
        let model = makeIsolatedLauncher(engine: LauncherEngine(executable: executable, database: database), defaults: defaults)
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
                  == CGSize(width: 860, height: shell + PanelGeometry.inlinePreviewMinimumHeight),
                  "inline preview did not widen to 860pt with \(Int(PanelGeometry.inlinePreviewMinimumHeight))pt floor")
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
        // Verify DirectoryScope header chip & Tab alias entry work without changing headerHeight = 56.
        try check(PanelGeometry.headerHeight == 56, "PanelGeometry.headerHeight changed from 56")
        let scopeDummyDir = directory.appendingPathComponent("Phase2AliasScopeProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: scopeDummyDir, withIntermediateDirectories: true)
        let scopeDummyPath = IndexScope.folderPath(scopeDummyDir)
        let aliasShortcut = SavedShortcut(id: UUID(), title: "Alias Scope Probe", alias: "p2sc",
                                          target: .folder(scopeDummyPath), pinned: false)
        try check(app.model.shortcuts.save(aliasShortcut), "could not save folder alias shortcut for Tab test")
        defer {
            app.model.clearDirectoryScope()
            app.model.shortcuts.remove(aliasShortcut)
        }
        try type("p2sc", into: app)
        try key(kVK_Tab, "\t", in: app)
        try check(app.model.activeScopedDirectory == LauncherFileQuery.normalizedDirectoryScope(scopeDummyPath) &&
                  field.string.isEmpty && !field.string.contains("\t"),
                  "Tab on folder shortcut alias did not push DirectoryScope and clear search field: \(field.string.debugDescription)")
        try key(kVK_Delete, "\u{7f}", in: app)
        try check(app.model.activeScopedDirectory == nil && app.model.scopedDirectories.isEmpty,
                  "Backspace on empty field did not pop DirectoryScope")
        app.model.shortcuts.remove(aliasShortcut)
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
                  precomputed.normalizedSearchable == ["visualstudiocode", "vscode中文", "vscode", "代码", "vsc", "vc", "code"] &&
                  LaunchCatalog.matches("vscode", actions: [precomputed]).first?.action.id == precomputed.id &&
                  LaunchCatalog.matches("vsc", actions: [precomputed]).first?.action.id == precomputed.id,
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
        let streamModel = makeIsolatedLauncher(engine: streamEngine, defaults: streamDefaults, locale: "en")
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
        let pauseModel = makeIsolatedLauncher(engine: streamEngine, defaults: pauseDefaults, locale: "en")
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

        try? FileManager.default.removeItem(at: streamDir.appendingPathComponent("embed-first-sent"))
        try? FileManager.default.removeItem(at: streamDir.appendingPathComponent("embed-sigterm"))
        let turnDefaultsSuite = "lumen-phase3-turn-\(UUID().uuidString)"
        guard let turnDefaults = UserDefaults(suiteName: turnDefaultsSuite) else {
            throw Failure("missing isolated phase3 turn defaults")
        }
        defer { turnDefaults.removePersistentDomain(forName: turnDefaultsSuite) }
        let turnModel = makeIsolatedLauncher(engine: streamEngine, defaults: turnDefaults, locale: "en")
        defer { turnModel.close() }
        var turnCompletedCount = 0
        turnModel.maxEmbeddingBatchesPerTurn = { 1 }
        turnModel.onEmbeddingsTurnCompleted = { turnCompletedCount += 1 }
        turnModel.start(automaticallyIndex: false)
        try await until("phase3 turn fixture did not become ready") {
            turnModel.canSearch && turnModel.watchState == .running && turnModel.canBuildEmbeddings
        }
        turnModel.buildEmbeddings()
        try await until("bounded streaming embed turn did not yield to idle after 1 batch") {
            turnCompletedCount == 1 && turnModel.embeddingState == .idle && turnModel.indexWork == nil &&
                FileManager.default.fileExists(atPath: streamDir.appendingPathComponent("embed-sigterm").path)
        }
        try check(turnModel.embeddingNotice == nil && turnModel.embeddingBatch?.new_embeddings == 1,
                  "bounded streaming embed turn set unexpected notice or missed first batch")
        turnModel.close()

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
        try check(!streamImages.failed && !streamImages.lastBuildWasBounded && streamImages.checked == 4 && imgLaunches == 1,
                  "streaming image-index failed, reported bounded, or launched multiple processes (\(imgLaunches))")

        var observedBoundedInCallback = false
        streamImages.onBuildFinished = { [weak streamImages] in
            observedBoundedInCallback = streamImages?.lastBuildWasBounded == true
        }
        streamImages.build(maxBatches: 1)
        try await until("bounded streaming image-index bootstrap did not settle after batch 1") {
            !streamImages.building && !streamImages.loading
        }
        let boundedLaunches = try String(contentsOf: streamDir.appendingPathComponent("img-launches"), encoding: .utf8)
            .split(separator: "\n").count
        try check(!streamImages.failed && !streamImages.noProgressExhausted &&
                  streamImages.lastBuildWasBounded && observedBoundedInCallback &&
                  streamImages.checked == 3 && boundedLaunches == 2,
                  "bounded image bootstrap failed: failed=\(streamImages.failed) exhausted=\(streamImages.noProgressExhausted) bounded=\(streamImages.lastBuildWasBounded) callback=\(observedBoundedInCallback) checked=\(streamImages.checked) launches=\(boundedLaunches)")

        // 5. Option A: single-Han visual recall (`mode: "image"`) & slot 6-7 placement.
        try check(Launcher.qualifiesForImageRecall("鹿") &&
                  Launcher.qualifiesForImageRecall("deer") &&
                  !Launcher.qualifiesForImageRecall("a") &&
                  !Launcher.qualifiesForImageRecall("lumen.png") &&
                  !Launcher.qualifiesForImageRecall("ext:png 鹿"),
                  "qualifiesForImageRecall trigger rules did not match single-Han Option A")

        let optDir = directory.appendingPathComponent("phase3-option-a-image", isDirectory: true)
        try FileManager.default.createDirectory(at: optDir, withIntermediateDirectories: true)
        var deerPaths: [String] = []
        for idx in 0..<8 {
            let p = optDir.appendingPathComponent("deer-\(idx).txt")
            try Data("deer".utf8).write(to: p)
            deerPaths.append(p.path)
        }
        let optLogo = optDir.appendingPathComponent("Lumen-1024.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: optLogo)
        let optEngineFile = optDir.appendingPathComponent("engine")
        let optDB = optDir.appendingPathComponent("index.sqlite")
        try Data().write(to: optDB)
        let optScript = #"""
        #!/usr/bin/python3
        import json, signal, sys
        from pathlib import Path
        root = Path(__file__).parent
        command, *args = sys.argv[3:]
        files = json.loads((root / 'files.json').read_text())
        if command == 'status':
            print(json.dumps(dict(
                items=9, documents=0,
                scope=dict(roots=[str(root)], allow=[], deny=[], documents=True, content_roots=[str(root)]),
                content=dict(pending=0, checked=0, total=0),
                gemma=dict(documents_enabled=True, embedded_chunks=0, skipped_chunks=0, pending=False, limited=False, chunk_limit=1000),
                images=dict(enabled=True, vectors=1, pending=False, limited=False, vector_limit=1000)
            )))
        elif command == 'watch':
            if '--help' in args:
                print('--progress')
            else:
                print('{"event":"ready"}', flush=True)
                signal.pause()
        elif command == 'model-status':
            print(json.dumps(dict(available=True, verified='--verify' in args)))
        elif command == 'serve':
            for line in sys.stdin:
                req = json.loads(line)
                hits = [dict(path=p, name=Path(p).name, kind='file', availability='local',
                             matched_by='name', snippet=None, document_stamp=None, pdf_page=None)
                        for p in files['direct']]
                print(json.dumps(dict(id=req['id'], hits=hits)), flush=True)
        elif command == 'semantic-serve':
            for line in sys.stdin:
                req = json.loads(line)
                with (root / 'semantic-modes').open('a') as f:
                    f.write((req.get('mode') or 'none') + '\n')
                hits = [dict(path=files['logo'], name=Path(files['logo']).name, kind='file', availability='local',
                             matched_by='image_embedding', snippet=None, document_stamp=None, pdf_page=None)]
                print(json.dumps(dict(id=req['id'], hits=hits)), flush=True)
        """#
        try JSONSerialization.data(withJSONObject: ["direct": deerPaths, "logo": optLogo.path])
            .write(to: optDir.appendingPathComponent("files.json"))
        try Data(optScript.utf8).write(to: optEngineFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: optEngineFile.path)
        let optDefaultsSuite = "lumen-phase3-option-a-\(UUID().uuidString)"
        guard let optDefaults = UserDefaults(suiteName: optDefaultsSuite) else {
            throw Failure("missing isolated Option A defaults")
        }
        defer { optDefaults.removePersistentDomain(forName: optDefaultsSuite) }
        let optEngine = LauncherEngine(executable: optEngineFile, database: optDB, supportsStreamingBatches: true)
        let optModel = makeIsolatedLauncher(engine: optEngine, defaults: optDefaults, locale: "zh")
        defer { optModel.close() }
        optModel.start(automaticallyIndex: false)
        try await until("Option A fixture did not become ready") {
            optModel.canSearch && optModel.watchState == .running && optModel.localModelState == .available &&
                optModel.imageCoverage?.hasResults == true
        }
        optModel.setSearchPresented(true)
        optModel.setQuery("鹿")
        try await until("single-Han query '鹿' did not attach image_embedding hit at slot 6") {
            !optModel.semanticBusy && optModel.hits.count == 9 && optModel.hits[6].name == "Lumen-1024.png"
        }
        let modes = try String(contentsOf: optDir.appendingPathComponent("semantic-modes"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try check(modes == ["image"] &&
                  optModel.hits.prefix(6).map(\.name) == (0..<6).map { "deer-\($0).txt" } &&
                  optModel.hits[6].isImageMatch &&
                  optModel.selectedHit?.name == "deer-0.txt",
                  "Option A image recall displaced direct rows, stole selection, or skipped mode=image: modes=\(modes), names=\(optModel.hits.map(\.name))")
        optModel.close()

        // 6. Issue #3: main-bar .imageOnly recall in .localOpenAI mode works while text model is offline/unverified.
        let decoupleDir = directory.appendingPathComponent("phase3-v063-image-decouple", isDirectory: true)
        try FileManager.default.createDirectory(at: decoupleDir, withIntermediateDirectories: true)
        let sunsetImage = decoupleDir.appendingPathComponent("sunset-recall.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: sunsetImage)
        let fakeProjector = decoupleDir.appendingPathComponent("mmproj-custom.gguf")
        try Data("projector".utf8).write(to: fakeProjector)
        let decoupleEngineFile = decoupleDir.appendingPathComponent("engine")
        let decoupleDB = decoupleDir.appendingPathComponent("index.sqlite")
        try Data().write(to: decoupleDB)
        let decoupleScript = #"""
        #!/usr/bin/python3
        import json, signal, sys
        from pathlib import Path
        root = Path(__file__).parent
        command, *args = sys.argv[3:]
        if command == 'status':
            print(json.dumps(dict(
                items=2, documents=1,
                scope=dict(roots=[str(root)], allow=[], deny=[], documents=True, content_roots=[str(root)]),
                content=dict(pending=0, checked=1, total=1),
                gemma=dict(documents_enabled=True, embedded_chunks=4, skipped_chunks=0, pending=False, limited=False, chunk_limit=1000),
                images=dict(enabled=True, vectors=1, pending=False, limited=False, vector_limit=1000)
            )))
        elif command == 'watch':
            if '--help' in args:
                print('--progress')
            else:
                print('{"event":"ready"}', flush=True)
                signal.pause()
        elif command == 'model-status':
            print(json.dumps(dict(available=False, verified=False, diagnostic='connection refused')))
            sys.exit(1)
        elif command == 'serve':
            for line in sys.stdin:
                req = json.loads(line)
                print(json.dumps(dict(id=req['id'], hits=[])), flush=True)
        elif command == 'semantic-serve':
            (root / 'unexpected-semantic-serve').touch()
            sys.exit('semantic-serve must not be launched for .imageOnly in .localOpenAI mode')
        elif command == 'image-serve':
            assert '--projector' in args and args[args.index('--projector') + 1] == str(root / 'mmproj-custom.gguf'), args
            assert '--openai-url' not in args and '--openai-model' not in args, args
            for line in sys.stdin:
                req = json.loads(line)
                with (root / 'image-requests.jsonl').open('a') as f:
                    f.write(json.dumps(dict(query=req.get('query'), limit=req.get('limit'))) + '\n')
                hits = [dict(path=str(root / 'sunset-recall.png'), name='sunset-recall.png', kind='file',
                             availability='local', matched_by='image_embedding', snippet=None,
                             document_stamp=None, pdf_page=None)]
                print(json.dumps(dict(id=req['id'], hits=hits)), flush=True)
        """#
        try Data(decoupleScript.utf8).write(to: decoupleEngineFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: decoupleEngineFile.path)
        let decoupleSuite = "lumen-phase3-v063-decouple-\(UUID().uuidString)"
        guard let decoupleDefaults = UserDefaults(suiteName: decoupleSuite) else {
            throw Failure("missing isolated v063 image decouple defaults")
        }
        defer { decoupleDefaults.removePersistentDomain(forName: decoupleSuite) }
        TextEmbeddingBackendConfig(
            mode: .localOpenAI,
            baseURL: "http://127.0.0.1:18080/v1",
            model: "qwen3-emb",
            dimensions: 16,
            signature: "openai-local:qwen3-emb@16"
        ).save(to: decoupleDefaults)
        decoupleDefaults.set(fakeProjector.path, forKey: "launcher.imageProjector.v1")
        let decoupleEngine = LauncherEngine(
            executable: decoupleEngineFile,
            database: decoupleDB,
            gemmaHome: decoupleDir,
            supportsStreamingBatches: true
        )
        let decoupleModel = makeIsolatedLauncher(engine: decoupleEngine, defaults: decoupleDefaults, locale: "en")
        defer { decoupleModel.close() }
        decoupleModel.start(automaticallyIndex: false)
        try await until("v063 image decouple fixture did not become ready") {
            decoupleModel.canSearch && decoupleModel.watchState == .running &&
                decoupleModel.localModelState == .unavailable(.verification) &&
                decoupleModel.imageCoverage?.hasResults == true &&
                decoupleModel.gemmaCoverage?.hasResults == true
        }
        decoupleModel.setSearchPresented(true)
        decoupleModel.setQuery("sunset beach")
        try await until("main-bar .imageOnly did not recall image while localOpenAI was unavailable") {
            !decoupleModel.semanticBusy &&
                decoupleModel.hits.contains(where: { $0.name == "sunset-recall.png" && $0.isImageMatch })
        }
        try check(!FileManager.default.fileExists(atPath: decoupleDir.appendingPathComponent("unexpected-semantic-serve").path),
                  "main-bar .imageOnly in .localOpenAI mode launched semantic-serve")
        try check(decoupleModel.localModelState == .unavailable(.verification),
                  "image-serve recall overwrote offline localOpenAI localModelState: \(decoupleModel.localModelState)")
        if let recalled = decoupleModel.hits.first(where: { $0.name == "sunset-recall.png" }) {
            var resolvedURL: URL?
            decoupleModel.resolve(recalled, action: .open) { resolvedURL = $0 }
            try await until("main-bar image recall hit could not be opened while localOpenAI was unavailable") {
                resolvedURL?.path == sunsetImage.path
            }
        }
        decoupleModel.setImageQuery("sunset", projector: fakeProjector)
        try await until("explicit img query did not return image hit") {
            !decoupleModel.searching &&
                decoupleModel.hits.contains(where: { $0.name == "sunset-recall.png" && $0.isImageMatch })
        }
        let imageRequests = try String(contentsOf: decoupleDir.appendingPathComponent("image-requests.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:] }
        try check(imageRequests.count == 2 &&
                  (imageRequests[0]["limit"] as? Int) == 3 &&
                  (imageRequests[1]["limit"] as? Int) == 5,
                  "expected image-serve limits [3, 5], got \(imageRequests)")
        decoupleModel.close()

        try type("", into: app)
        print("Phase 3 regressions passed (IndexStatusState isolation, caches, dual-lane CoreSearchConnection, ContentBatch skip, streaming clients)")
    }

    private func verifyPhase2LiveFileInteractions(_ app: AppDelegate) async throws {
        let model = app.model
        let fm = FileManager.default

        // 1. Tab folder enters DirectoryScope (clears search field instead of inserting raw path).
        let tabFolder = corpus.appendingPathComponent("Phase2TabFolder", isDirectory: true)
        let tabChild = tabFolder.appendingPathComponent("phase2-tab-child.txt")
        try fm.createDirectory(at: tabFolder, withIntermediateDirectories: true)
        try Data("Phase 2 scoped child".utf8).write(to: tabChild)
        let folderPath = IndexScope.folderPath(tabFolder)
        let childPath = IndexScope.folderPath(tabChild)
        try type("Phase2TabFolder", into: app)
        try await until("Tab folder fixture was indexed") {
            model.hits.contains { $0.path == folderPath && $0.kind == "directory" }
        }
        model.selectedID = folderPath
        try key(kVK_Tab, "\t", in: app)
        let field = try editor(app)
        try check(model.activeScopedDirectory == LauncherFileQuery.normalizedDirectoryScope(folderPath) &&
                  field.string.isEmpty && !field.string.contains("\t"),
                  "Tab did not enter DirectoryScope and clear field (scope: \(String(describing: model.activeScopedDirectory)), field: \(field.string.debugDescription))")
        try await until("DirectoryScope did not list indexed child inside Phase2TabFolder") {
            model.hits.contains { $0.path == childPath }
        }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(model.activeScopedDirectory == nil && app.searchPresented,
                  "Escape did not exit DirectoryScope while keeping search open")

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
            let matching = bindings.filter(chord.matchesSymbolicEntry)
            let enabled = matching.contains { ($0["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true }
            let disabled = !enabled && matching.contains { ($0["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == false }
            var reserved = false
            do { try chord.checkSystemShortcut() }
            catch HotKeyIssue.system { reserved = true }
            try check(reserved == enabled, "\(chord.label) conflict did not match the system shortcut catalog")
            try check(chord.hasDisabledSystemSymbolicEntry() == disabled,
                      "\(chord.label) disabled symbolic hotkey detection did not match the system catalog")
        }
        let cmdSpace = HotKey(code: UInt32(kVK_Space), modifiers: UInt32(cmdKey), key: "␣")
        if cmdSpace.hasDisabledSystemSymbolicEntry() {
            // Disabled Spotlight ⌘Space must not fail checkSystemShortcut() and must retry non-exclusively.
            try cmdSpace.checkSystemShortcut()
            let probeSpace = GlobalHotKey {}
            defer { probeSpace.close() }
            do {
                try probeSpace.set(cmdSpace)
                try check(probeSpace.shortcut == cmdSpace, "disabled ⌘Space registration did not retain shortcut")
            } catch HotKeyIssue.occupied {
                // Another user launcher on the host exclusively holds ⌘Space; confirm it was never .system.
            }
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
        let nonSystemChord = HotKey(code: UInt32(kVK_ANSI_X), modifiers: modifiers, key: "X")
        try check(!nonSystemChord.hasDisabledSystemSymbolicEntry(),
                  "non-system chord falsely matched disabled symbolic hotkey catalog")
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
        let point = accessibilityButtonPoint(identifier: "window-accessibility-settings", in: view, window: window)
            ?? CGPoint(x: bounds.maxX - 95, y: bounds.maxY - 134)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try mouseEvent(type, count: 1, at: point, in: window))
        }
        try await until("the Settings button did not dispatch the Accessibility deep-link") {
            openedAccessibilitySettings.map(\.absoluteString) ==
                ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
        }
    }

    private func findTextView(in view: NSView, containing needle: String) -> NSTextView? {
        if let tv = view as? NSTextView, tv.string.contains(needle) { return tv }
        for sub in view.subviews {
            if let hit = findTextView(in: sub, containing: needle) { return hit }
        }
        return nil
    }

    private func recognizedStrings(in bitmap: NSBitmapImageRep) -> [String] {
        guard let cgImage = bitmap.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func hasBannerInk(in bitmap: NSBitmapImageRep, panelSize: CGSize, xPoints: Range<CGFloat>, yPoints: Range<CGFloat>) -> Bool {
        let scaleX = CGFloat(bitmap.pixelsWide) / max(panelSize.width, 1)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(panelSize.height, 1)
        let minX = max(0, Int(xPoints.lowerBound * scaleX))
        let maxX = min(bitmap.pixelsWide, Int(xPoints.upperBound * scaleX))
        let minY = max(0, Int(yPoints.lowerBound * scaleY))
        let maxY = min(bitmap.pixelsHigh, Int(yPoints.upperBound * scaleY))
        guard minX < maxX, minY < maxY else { return false }
        var darkPixels = 0
        for x in stride(from: minX, to: maxX, by: 1) {
            for y in stride(from: minY, to: maxY, by: 1) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luma = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                if luma < 0.72 && c.alphaComponent > 0.2 {
                    darkPixels += 1
                    if darkPixels >= 18 { return true }
                }
            }
        }
        return false
    }

    private func accessibilityButtonPoint(identifier: String, in root: NSView, window: NSWindow) -> CGPoint? {
        var visited = Set<ObjectIdentifier>()
        func visit(_ element: AnyObject) -> CGPoint? {
            let oid = ObjectIdentifier(element)
            guard visited.insert(oid).inserted else { return nil }
            if let acc = element as? NSAccessibilityProtocol {
                if acc.accessibilityIdentifier() == identifier {
                    let screenRect = acc.accessibilityFrame()
                    if !screenRect.isEmpty {
                        let winRect = window.convertFromScreen(screenRect)
                        return CGPoint(x: winRect.midX, y: winRect.midY)
                    }
                }
                if let children = acc.accessibilityChildren() {
                    for child in children {
                        if let hit = visit(child as AnyObject) { return hit }
                    }
                }
            }
            if let view = element as? NSView {
                for sub in view.subviews {
                    if let hit = visit(sub) { return hit }
                }
            }
            return nil
        }
        return visit(root)
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

    private func verifyBuild33Phase1Regressions(_ app: AppDelegate) async throws {
        let root = URL(fileURLWithPath: IndexScope.folderPath(directory), isDirectory: true)
            .appendingPathComponent("phase1-b33-regressions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 1. Plain-text bounded preview: clean multibyte UTF-8 truncation at 16 KB & NUL byte rejection.
        let renderer = MacPreviewRenderer()
        let prefixASCII = String(repeating: "a", count: 16_382)
        let boundaryUTF8 = root.appendingPathComponent("utf8-boundary.txt")
        try Data((prefixASCII + "界tail").utf8).write(to: boundaryUTF8)
        let doc = try renderer.load(.init(id: boundaryUTF8.path, revision: "", url: boundaryUTF8, kind: .plainText),
                                    isPending: { _ in false })
        try check(doc.text == prefixASCII && !doc.isCode, "plainText split multibyte UTF-8 scalar or misdetected code")

        let nulFile = root.appendingPathComponent("binary.json")
        try Data([0x7b, 0x00, 0x7d]).write(to: nulFile)
        var rejectedNul = false
        do {
            _ = try renderer.load(.init(id: nulFile.path, revision: "", url: nulFile, kind: .plainText),
                                  isPending: { _ in false })
        } catch PreviewFailure.invalidContent {
            rejectedNul = true
        }
        try check(rejectedNul, "plainText preview accepted binary file containing NUL bytes")

        // 2. ClipboardStore legacy DB migration (adding file_path idempotently while keeping existing rows).
        let legacyDir = root.appendingPathComponent("legacy-clip/Clipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacyDir.path)
        let dbFile = legacyDir.appendingPathComponent(".history.sqlite")
        do {
            var db: OpaquePointer?
            try check(sqlite3_open_v2(dbFile.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                      "could not create legacy clipboard DB")
            defer { sqlite3_close(db) }
            try check(sqlite3_exec(db, """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT, image BLOB, thumbnail BLOB,
                    captured REAL NOT NULL, bundle_id TEXT, app_name TEXT,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    digest BLOB NOT NULL, recency INTEGER NOT NULL UNIQUE
                );
                INSERT INTO clips (text, captured, digest, recency)
                VALUES ('Legacy clip row', 1700000000, X'000102', 1);
                """, nil, nil, nil) == SQLITE_OK, "could not seed legacy clipboard table")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbFile.path)
        let migratedStore = ClipboardStore(directory: legacyDir)
        let loadedLegacy = try migratedStore.items()
        try check(loadedLegacy.count == 1 && loadedLegacy[0].text == "Legacy clip row" && loadedLegacy[0].filePath == nil,
                  "legacy clipboard DB migration altered or lost existing clip rows")
        let addedFile = try migratedStore.upsertFile(boundaryUTF8.path, capturedAt: .now, bundleID: nil, appName: nil)
        try check(addedFile?.item.filePath == boundaryUTF8.path, "upsertFile failed after legacy migration")

        // 3. MacPreviewRenderer.clipboardFilePreview across resident PNG, PDF, code/text, directory, and missing file.
        let pngURL = root.appendingPathComponent("clip-img.png")
        guard let pngRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 18, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let pngBytes = pngRep.representation(using: .png, properties: [:]) else {
            throw Failure("could not allocate clipboard preview PNG fixture")
        }
        try pngBytes.write(to: pngURL)
        if case .image(_, let label, let bytes) = await MacPreviewRenderer.clipboardFilePreview(at: pngURL) {
            try check(label.contains("36 × 18") && bytes == Int64(pngBytes.count),
                      "clipboardFilePreview misreported image dimensions: \(label)")
        } else { throw Failure("clipboardFilePreview did not return .image for resident PNG") }

        let pdfURL = root.appendingPathComponent("clip-doc.pdf")
        let generatedPDF = PDFDocument()
        let blankPage = PDFPage()
        generatedPDF.insert(blankPage, at: 0)
        try check(generatedPDF.write(to: pdfURL), "could not write PDF clipboard fixture")
        if case .image(_, let pdfLabel, _) = await MacPreviewRenderer.clipboardFilePreview(at: pdfURL) {
            try check(pdfLabel == "PDF · 1/1", "clipboardFilePreview misreported PDF label: \(pdfLabel)")
        } else { throw Failure("clipboardFilePreview did not render PDF page 1") }

        let swiftClip = root.appendingPathComponent("clip-code.swift")
        try Data("struct ClipCode { let x = 1 }\n".utf8).write(to: swiftClip)
        if case .text(let snippet, true, _) = await MacPreviewRenderer.clipboardFilePreview(at: swiftClip) {
            try check(snippet.contains("struct ClipCode"), "clipboardFilePreview returned wrong code snippet")
        } else { throw Failure("clipboardFilePreview did not return .text(isCode: true) for .swift") }

        let clipFolder = root.appendingPathComponent("ClipFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: clipFolder, withIntermediateDirectories: true)
        if case .thumbnail = await MacPreviewRenderer.clipboardFilePreview(at: clipFolder) {} else {
            throw Failure("clipboardFilePreview did not return .thumbnail for resident folder")
        }
        if case .missing = await MacPreviewRenderer.clipboardFilePreview(at: root.appendingPathComponent("absent.txt")) {} else {
            throw Failure("clipboardFilePreview did not return .missing for missing path")
        }

        // 4. Window Management: `?` -> `win`, orientation-aware ordering, portrait thirds, multi-window autoTile, batch restore.
        let catalog = LumenCommandCatalog()
        try check(catalog.resolve("win") == .window("") && catalog.resolve("win 上") == .window("上"),
                  "LumenCommandCatalog did not resolve win command")
        let portraitOrder = LaunchCatalog.windowActions(isPortrait: true).prefix(8).map(\.destination)
        try check(portraitOrder == [.window(.autoTile), .window(.topHalf), .window(.bottomHalf),
                                    .window(.topThird), .window(.middleThird), .window(.bottomThird),
                                    .window(.topTwoThirds), .window(.bottomTwoThirds)],
                  "portrait win command did not prioritize autoTile + top/bottom/thirds")
        let landscapeOrder = LaunchCatalog.windowActions(isPortrait: false).prefix(3).map(\.destination)
        try check(landscapeOrder == [.window(.autoTile), .window(.leftHalf), .window(.rightHalf)],
                  "landscape win command did not prioritize autoTile + left/right")

        // Portrait display: frame (0,0,1080,1920), visibleFrame (0,40,1080,1842). AX Y top = 1920 - maxY.
        let portraitPlanner = WindowLayoutPlanner(displays: [
            .init(frame: CGRect(x: 0, y: 0, width: 1080, height: 1920),
                  visibleFrame: CGRect(x: 0, y: 40, width: 1080, height: 1842)),
        ])
        let origPortrait = CGRect(x: 50, y: 100, width: 400, height: 300)
        // Thirds math: 1842 / 3 = 614 each -> split1 AppKit = 654, split2 AppKit = 1268, visible top = 1882 -> AX y = 38.
        let thirdExpected: [(WindowCommand, CGRect)] = [
            (.topThird, CGRect(x: 0, y: 38, width: 1080, height: 614)),
            (.middleThird, CGRect(x: 0, y: 652, width: 1080, height: 614)),
            (.bottomThird, CGRect(x: 0, y: 1266, width: 1080, height: 614)),
            (.topTwoThirds, CGRect(x: 0, y: 38, width: 1080, height: 1228)),
            (.bottomTwoThirds, CGRect(x: 0, y: 652, width: 1080, height: 1228)),
        ]
        for (cmd, expectedFrame) in thirdExpected {
            let actual = portraitPlanner.placement(for: cmd, currentAX: origPortrait)?.frame
            try check(actual == expectedFrame, "portrait \(cmd) frame mismatch: got \(String(describing: actual)), expected \(expectedFrame)")
        }

        // autoTile math: 2 & 3 windows on portrait vs landscape, plus AXWindowAccess batch autoTile + restore.
        try check(portraitPlanner.autoTilePlan(windowCount: 2, on: 0) == [
            CGRect(x: 0, y: 38, width: 1080, height: 921),
            CGRect(x: 0, y: 959, width: 1080, height: 921),
        ], "portrait 2-window autoTile did not split top/bottom")
        try check(portraitPlanner.autoTilePlan(windowCount: 3, on: 0) == [
            CGRect(x: 0, y: 38, width: 1080, height: 614),
            CGRect(x: 0, y: 652, width: 1080, height: 614),
            CGRect(x: 0, y: 1266, width: 1080, height: 614),
        ], "portrait 3-window autoTile did not split vertical thirds")

        let landscapePlanner = WindowLayoutPlanner(displays: [Self.windowPlanner.displays[0]])
        try check(landscapePlanner.autoTilePlan(windowCount: 4, on: 0) == [
            CGRect(x: 0, y: 38, width: 720, height: 411),
            CGRect(x: 720, y: 38, width: 720, height: 411),
            CGRect(x: 0, y: 449, width: 720, height: 411),
            CGRect(x: 720, y: 449, width: 720, height: 411),
        ], "landscape 4-window autoTile did not build 2x2 grid")

        let tileAdapter = SmokeWindowAccess()
        tileAdapter.trusted = true
        let f1 = CGRect(x: 40, y: 80, width: 500, height: 350)
        let f2 = CGRect(x: 300, y: 120, width: 520, height: 360)
        let f3 = CGRect(x: 100, y: 320, width: 480, height: 320)
        tileAdapter.states = [1: .init(frame: f1), 2: .init(frame: f2), 3: .init(frame: f3)]
        tileAdapter.onScreen = [1, 2, 3]
        let tileAccess = AXWindowAccess(adapter: tileAdapter)
        try check(tileAccess.perform(.autoTile, targetPID: 42_001, planner: portraitPlanner) == nil,
                  "AXWindowAccess autoTile failed")
        try check(tileAdapter.states[1]?.frame == CGRect(x: 0, y: 38, width: 1080, height: 614) &&
                  tileAdapter.states[2]?.frame == CGRect(x: 0, y: 652, width: 1080, height: 614) &&
                  tileAdapter.states[3]?.frame == CGRect(x: 0, y: 1266, width: 1080, height: 614),
                  "autoTile did not position all 3 portrait windows cleanly")
        try check(tileAccess.perform(.restore, targetPID: 42_001, planner: portraitPlanner) == nil &&
                  tileAdapter.states[1]?.frame == f1 &&
                  tileAdapter.states[2]?.frame == f2 &&
                  tileAdapter.states[3]?.frame == f3,
                  "batch restore did not return all auto-tiled windows to their original frames")

        // Adaptive autoTile regressions: edge clamping + shrink-first, AXEnhancedUserInterface,
        // portrait/master-stack/ultrawide minimum-size reflow, master slot assignment, and batch restore.
        let fullLandscape = WindowLayoutPlanner(displays: [
            .init(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                  visibleFrame: CGRect(x: 0, y: 62, width: 1800, height: 1068)),
        ])
        let fullBounds = fullLandscape.axFrame(fullLandscape.displays[0].visibleFrame) // (0, 39, 1800, 1068)
        let adaptive = SmokeWindowAccess()
        adaptive.trusted = true
        adaptive.focused = 2
        let g1Orig = CGRect(x: 0, y: 39, width: 1800, height: 1068)
        let g2Orig = CGRect(x: 500, y: 120, width: 1300, height: 900)
        let g3Orig = CGRect(x: 700, y: 400, width: 1100, height: 700)
        adaptive.states = [
            1: .init(frame: g1Orig, edgeClampBounds: fullBounds, enhancedUI: true),
            2: .init(frame: g2Orig, edgeClampBounds: fullBounds),
            3: .init(frame: g3Orig, minimumWidth: 900, edgeClampBounds: fullBounds, enhancedUI: true),
        ]
        adaptive.onScreen = [2, 1, 3] // Window 2 is frontmost, window 1 is top-left, window 3 enforces 900pt min width.
        let adaptiveAccess = AXWindowAccess(adapter: adaptive)
        try check(adaptiveAccess.perform(.autoTile, targetPID: 42_001, planner: fullLandscape) == nil,
                  "adaptive master-stack autoTile failed")
        // Master is frontmost window 2; window 3 forces 900pt right width so master becomes 900x1068 & stack 900x534 each.
        try check(adaptive.states[2]?.frame == CGRect(x: 0, y: 39, width: 900, height: 1068) &&
                  adaptive.states[1]?.frame == CGRect(x: 900, y: 39, width: 900, height: 534) &&
                  adaptive.states[3]?.frame == CGRect(x: 900, y: 573, width: 900, height: 534) &&
                  adaptive.states[1]?.enhancedUI == true &&
                  adaptive.states[3]?.enhancedUI == true,
                  "adaptive master-stack did not reflow around minWidth / enhancedUI / edgeClamp: \(adaptive.states)")
        try check(adaptiveAccess.perform(.restore, targetPID: 42_001, planner: fullLandscape) == nil &&
                  adaptive.states[1]?.frame == g1Orig &&
                  adaptive.states[2]?.frame == g2Orig &&
                  adaptive.states[3]?.frame == g3Orig,
                  "adaptive batch restore did not return all edge-clamped windows to originals")

        // Master-stack vertical reflow: right-top enforces minHeight 640 on 1800x1068 -> right-bottom gets 428.
        adaptive.states = [
            1: .init(frame: CGRect(x: 20, y: 50, width: 800, height: 600), edgeClampBounds: fullBounds),
            2: .init(frame: CGRect(x: 400, y: 100, width: 700, height: 640), minimumHeight: 640, edgeClampBounds: fullBounds),
            3: .init(frame: CGRect(x: 600, y: 600, width: 700, height: 500), edgeClampBounds: fullBounds),
        ]
        adaptive.onScreen = [1, 2, 3]
        try check(adaptiveAccess.perform(.autoTile, targetPID: nil, planner: fullLandscape) == nil &&
                  adaptive.states[1]?.frame == CGRect(x: 0, y: 39, width: 990, height: 1068) &&
                  adaptive.states[2]?.frame == CGRect(x: 990, y: 39, width: 810, height: 640) &&
                  adaptive.states[3]?.frame == CGRect(x: 990, y: 679, width: 810, height: 428),
                  "adaptive master-stack did not reflow vertically around minimumHeight: \(adaptive.states)")

        // Portrait 3-row reflow: window 1 enforces minimumHeight 760 on 1080x1842 -> others rebalance to 541 each.
        let pBounds = portraitPlanner.axFrame(portraitPlanner.displays[0].visibleFrame)
        adaptive.states = [
            1: .init(frame: CGRect(x: 0, y: 100, width: 900, height: 760), minimumHeight: 760, edgeClampBounds: pBounds),
            2: .init(frame: CGRect(x: 0, y: 600, width: 900, height: 500), edgeClampBounds: pBounds),
            3: .init(frame: CGRect(x: 0, y: 1200, width: 900, height: 500), edgeClampBounds: pBounds),
        ]
        adaptive.onScreen = [1, 2, 3]
        try check(adaptiveAccess.perform(.autoTile, targetPID: nil, planner: portraitPlanner) == nil &&
                  adaptive.states[1]?.frame == CGRect(x: 0, y: 38, width: 1080, height: 760) &&
                  adaptive.states[2]?.frame == CGRect(x: 0, y: 798, width: 1080, height: 541) &&
                  adaptive.states[3]?.frame == CGRect(x: 0, y: 1339, width: 1080, height: 541),
                  "portrait 3-row autoTile did not reflow around minimumHeight: \(adaptive.states)")

        // Ultrawide 3-column reflow: 3008x1662 with 1 column minWidth 1200 -> others rebalance to 904 each.
        let ultrawide = WindowLayoutPlanner(displays: [
            .init(frame: CGRect(x: 0, y: 0, width: 3008, height: 1692),
                  visibleFrame: CGRect(x: 0, y: 0, width: 3008, height: 1662)),
        ])
        let uBounds = ultrawide.axFrame(ultrawide.displays[0].visibleFrame)
        adaptive.states = [
            1: .init(frame: CGRect(x: 0, y: 30, width: 1200, height: 1000), minimumWidth: 1200, edgeClampBounds: uBounds),
            2: .init(frame: CGRect(x: 1100, y: 30, width: 1000, height: 1000), edgeClampBounds: uBounds),
            3: .init(frame: CGRect(x: 2000, y: 30, width: 1000, height: 1000), edgeClampBounds: uBounds),
        ]
        adaptive.onScreen = [1, 2, 3]
        try check(adaptiveAccess.perform(.autoTile, targetPID: nil, planner: ultrawide) == nil &&
                  adaptive.states[1]?.frame == CGRect(x: 0, y: 30, width: 1200, height: 1662) &&
                  adaptive.states[2]?.frame == CGRect(x: 1200, y: 30, width: 904, height: 1662) &&
                  adaptive.states[3]?.frame == CGRect(x: 2104, y: 30, width: 904, height: 1662),
                  "ultrawide 3-column autoTile did not rebalance around minWidth: \(adaptive.states)")

        // 5. AppearanceMode persistence + NSApp.appearance synchronization.
        let model = app.model
        let appearanceDefaults = shortcutFixturePreferences ?? UserDefaults.standard
        let previousAppearance = model.appearanceMode
        defer {
            model.setAppearanceMode(previousAppearance)
            NSApp.appearance = previousAppearance.nsAppearance
        }
        model.setAppearanceMode(.dark)
        try await until("AppearanceMode.dark did not sync NSApp.appearance") {
            NSApp.appearance?.name == .darkAqua && appearanceDefaults.string(forKey: "appearance") == "dark"
        }
        model.setAppearanceMode(.light)
        try await until("AppearanceMode.light did not sync NSApp.appearance") {
            NSApp.appearance?.name == .aqua && appearanceDefaults.string(forKey: "appearance") == "light"
        }
        model.setAppearanceMode(.system)
        try await until("AppearanceMode.system did not clear NSApp.appearance") {
            NSApp.appearance == nil && appearanceDefaults.string(forKey: "appearance") == "system"
        }
        print("Build 33 Phase 1 regressions passed (plainText UTF-8/NUL, clipboard migration + rich preview, portrait thirds/autoTile/restore, AppearanceMode)")
    }

    private func verifyBuild33Phase2Regressions(_ app: AppDelegate) async throws {
        let model = app.model
        let fm = FileManager.default
        let root = URL(fileURLWithPath: IndexScope.folderPath(directory), isDirectory: true)
            .appendingPathComponent("phase2-b33-regressions-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. Network filesystem f_fstypename allowlist & resident-file boundary.
        for allowed in ["smbfs", "SMBFS", "nfs", "afpfs", "webdav"] {
            try check(LocalFile.isAllowedNetworkFilesystem(allowed), "expected \(allowed) to be an allowed network filesystem")
        }
        var netStat = statfs()
        withUnsafeMutableBytes(of: &netStat.f_fstypename) { buffer in
            let bytes = Array("SMBFS\0".utf8)
            buffer.copyBytes(from: bytes)
        }
        try check(LocalFile.fsTypeName(of: netStat) == "SMBFS" && LocalFile.isAllowedNetworkFilesystem(LocalFile.fsTypeName(of: netStat)),
                  "fsTypeName(of:) did not NUL-terminate statfs.f_fstypename cleanly")
        for rejected in ["apfs", "hfs", "autofs", "devfs", ""] {
            try check(!LocalFile.isAllowedNetworkFilesystem(rejected), "expected \(rejected) to be rejected by network filesystem allowlist")
        }
        let residentFile = root.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: residentFile)
        try check(try LocalFile.withResidentFile(residentFile) { 42 } == 42, "withResidentFile rejected a regular local file")
        var rejectedMissing = false
        do { _ = try LocalFile.withResidentFile(root.appendingPathComponent("missing.txt")) { 1 } } catch { rejectedMissing = true }
        try check(rejectedMissing, "withResidentFile did not reject missing file")
        var rejectedRemoteURL = false
        do { _ = try LocalFile.withResidentFile(URL(string: "https://example.com/hello.txt")!) { 1 } } catch { rejectedRemoteURL = true }
        try check(rejectedRemoteURL, "withResidentFile did not reject non-file URL")

        // 2. Bundled gemma-assets.json manifest, mirror URLs, SHA-256 verification, and file classification.
        guard let manifest = GemmaAssetManager.loadManifest() else {
            throw Failure("GemmaAssetManager.loadManifest() returned nil")
        }
        try check(manifest.model.name == "embeddinggemma-2-Q8_0.gguf", "unexpected manifest model name")
        try check(manifest.image_projector.name == "mmproj-embeddinggemma-2-Q8_0.gguf", "unexpected manifest projector name")
        try check(manifest.runtime.count == 12, "expected 12 pinned Gemma runtime entries, got \(manifest.runtime.count)")
        for asset in GemmaAsset.allCases {
            for mirror in GemmaMirror.allCases {
                guard let url = GemmaAssetManager.downloadURL(asset: asset, mirror: mirror, manifest: manifest) else {
                    throw Failure("missing downloadURL for \(asset.rawValue) / \(mirror.rawValue)")
                }
                let host = url.host ?? ""
                switch (asset, mirror) {
                case (.runtimeArchive, _):
                    try check(host.contains("github"), "expected GitHub runtime URL, got \(url)")
                case (_, .huggingFace):
                    try check(host.contains("huggingface.co"), "expected huggingface.co URL, got \(url)")
                case (_, .hfMirror):
                    try check(host.contains("hf-mirror.com"), "expected hf-mirror.com URL, got \(url)")
                }
            }
        }
        let helloSHA = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        try check(GemmaAssetManager.verifyFileSHA256(at: residentFile, expectedSHA256: helloSHA, expectedSize: 5),
                  "verifyFileSHA256 failed on valid regular file")
        try check(!GemmaAssetManager.verifyFileSHA256(at: residentFile, expectedSHA256: helloSHA, expectedSize: 6),
                  "verifyFileSHA256 accepted wrong size")
        let tamperedFile = root.appendingPathComponent("tampered.txt")
        try Data("jello".utf8).write(to: tamperedFile)
        try check(!GemmaAssetManager.verifyFileSHA256(at: tamperedFile, expectedSHA256: helloSHA, expectedSize: 5),
                  "verifyFileSHA256 accepted 1-byte tampered file")
        let symlinkFile = root.appendingPathComponent("hello-link.txt")
        try fm.createSymbolicLink(at: symlinkFile, withDestinationURL: residentFile)
        try check(!GemmaAssetManager.verifyFileSHA256(at: symlinkFile, expectedSHA256: helloSHA, expectedSize: 5),
                  "verifyFileSHA256 accepted symlink")

        let archiveName = manifest.archive.name ?? "llama-b11457-bin-macos-arm64.tar.gz"
        let fakeArchive = root.appendingPathComponent(archiveName)
        fm.createFile(atPath: fakeArchive.path, contents: nil)
        let archiveHandle = try FileHandle(forWritingTo: fakeArchive)
        try archiveHandle.truncate(atOffset: UInt64(manifest.archive.size))
        try archiveHandle.close()
        let wrongSizeArchive = root.appendingPathComponent("wrong-\(archiveName)")
        try Data("bad".utf8).write(to: wrongSizeArchive)
        let symlinkArchive = root.appendingPathComponent("link-\(archiveName)")
        try fm.createSymbolicLink(at: symlinkArchive, withDestinationURL: fakeArchive)
        let classified = GemmaAssetManager.classify([fakeArchive, wrongSizeArchive, symlinkArchive], manifest: manifest)
        try check(classified[.runtimeArchive] == fakeArchive && classified.count == 1,
                  "GemmaAssetManager.classify misclassified local files: \(classified)")

        // 3. ContentFilter defaults/round-trip, IndexScope.contentArguments, and ExternalVolume decoding.
        let defaultFilter = ContentFilter()
        try check(defaultFilter.enable_pdf && defaultFilter.enable_docx && defaultFilter.enable_text
                  && defaultFilter.enable_images && !defaultFilter.enable_code
                  && defaultFilter.allow_extensions.isEmpty && defaultFilter.deny_extensions.isEmpty
                  && defaultFilter.deny_folders.isEmpty, "ContentFilter defaults changed unexpectedly")
        let decodedEmpty = try JSONDecoder().decode(ContentFilter.self, from: Data("{}".utf8))
        try check(decodedEmpty == defaultFilter, "empty JSON did not decode to ContentFilter defaults")
        var customFilter = ContentFilter()
        customFilter.enable_code = true
        customFilter.allow_extensions = ["swift", "json"]
        customFilter.deny_extensions = ["tmp"]
        customFilter.deny_folders = ["dist"]
        let encodedFilter = try JSONEncoder().encode(customFilter)
        try check(try JSONDecoder().decode(ContentFilter.self, from: encodedFilter) == customFilter,
                  "ContentFilter JSON round-trip mismatch")
        let probeScope = IndexScope(roots: [], allow: [], deny: [], documents: true,
                                    content_roots: [root.path], content_filter: customFilter)
        let contentArgs = probeScope.contentArguments
        try check(contentArgs.first == "content-scope"
                  && contentArgs.contains("--content-root")
                  && contentArgs.contains(root.path)
                  && contentArgs.contains("--bundled-pdf-helper")
                  && contentArgs.contains("--content-filter-json"),
                  "IndexScope.contentArguments missing expected flags: \(contentArgs)")

        let networkVolumeJSON = Data(#"{"uuid":"net-1","path":"/Volumes/movie","available":true,"indexed":false,"needs_refresh":false,"kind":"network","protocol":"smb"}"#.utf8)
        let networkVolume = try JSONDecoder().decode(ExternalVolume.self, from: networkVolumeJSON)
        try check(networkVolume.isNetwork && networkVolume.protocolBadge == "SMB", "ExternalVolume failed to decode network SMB badge")
        let legacyVolumeJSON = Data(#"{"uuid":"ext-1","path":"/Volumes/USB","available":true,"indexed":false,"needs_refresh":false}"#.utf8)
        let legacyVolume = try JSONDecoder().decode(ExternalVolume.self, from: legacyVolumeJSON)
        try check(!legacyVolume.isNetwork && legacyVolume.protocolBadge == nil, "ExternalVolume failed legacy decoding")

        // 4. Bundled lumen preview-content-scope & volumes check on isolated temp corpus.
        guard let lumenURL = Bundle.main.url(forResource: "lumen", withExtension: nil) else {
            throw Failure("missing bundled Resources/lumen binary")
        }
        let corpus = root.appendingPathComponent("corpus", isDirectory: true)
        for rel in ["docs", "src", "node_modules/pkg", "notes"] {
            try fm.createDirectory(at: corpus.appendingPathComponent(rel, isDirectory: true), withIntermediateDirectories: true)
        }
        try Data("%PDF-1.4\n".utf8).write(to: corpus.appendingPathComponent("docs/a.pdf"))
        try Data("struct Demo {}\n".utf8).write(to: corpus.appendingPathComponent("src/main.swift"))
        try Data("ignored\n".utf8).write(to: corpus.appendingPathComponent("node_modules/pkg/b.txt"))
        try Data("# Note\nhello\n".utf8).write(to: corpus.appendingPathComponent("notes/note.md"))
        let probeDB = root.appendingPathComponent("probe.sqlite")
        func runLumen(_ args: [String]) throws -> Data {
            let process = Process()
            process.executableURL = lumenURL
            process.arguments = args
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let err = String(data: errData, encoding: .utf8) ?? ""
                throw Failure("lumen \(args.first ?? "") failed (\(process.terminationStatus)): \(err)")
            }
            return outData
        }
        _ = try runLumen(["index", "--db", probeDB.path, "--allow", corpus.path])
        let previewDefaultData = try runLumen(["preview-content-scope", "--db", probeDB.path, "--content-root", corpus.path])
        let previewDefault = try JSONDecoder().decode(ContentScopePreview.self, from: previewDefaultData)
        try check(previewDefault.by_category.pdf == 1 && previewDefault.by_category.text == 1
                  && previewDefault.by_category.code == 0,
                  "unexpected preview-content-scope default breakdown: \(previewDefault)")
        try check(!previewDefault.top_subfolders.contains { $0.name == "node_modules" }
                  && previewDefault.top_subfolders.contains { $0.name == "docs" && !$0.suggested_noise }
                  && previewDefault.top_subfolders.contains { $0.name == "notes" && !$0.suggested_noise },
                  "preview-content-scope unexpected subfolders: \(previewDefault.top_subfolders)")
        var codeFilter = ContentFilter()
        codeFilter.enable_code = true
        let previewCodeData = try runLumen(["preview-content-scope", "--db", probeDB.path, "--content-root", corpus.path] + codeFilter.arguments)
        let previewCode = try JSONDecoder().decode(ContentScopePreview.self, from: previewCodeData)
        try check(previewCode.by_category.code == 1, "preview-content-scope with enable_code=true did not count src/main.swift: \(previewCode)")
        var denyDocsFilter = ContentFilter()
        denyDocsFilter.deny_folders = [corpus.appendingPathComponent("docs").path]
        let previewDenyData = try runLumen(["preview-content-scope", "--db", probeDB.path, "--content-root", corpus.path] + denyDocsFilter.arguments)
        let previewDeny = try JSONDecoder().decode(ContentScopePreview.self, from: previewDenyData)
        try check(previewDeny.by_category.pdf == 0 && previewDeny.by_category.text == 1,
                  "preview-content-scope with deny_folders did not exclude docs: \(previewDeny)")
        let volumesData = try runLumen(["volumes", "--db", probeDB.path])
        let decodedVolumes = try JSONDecoder().decode([ExternalVolume].self, from: volumesData)
        for volume in decodedVolumes where volume.isNetwork {
            try check(!volume.path.contains("@") && !volume.path.contains("://"), "network volume path leaked URI/credentials")
        }

        // 5. SettingsSession progressive-disclosure contentFilter draft toggle & discard.
        let session = SettingsSession(model: model, manageLoginItem: false, pageChanged: { _, _ in })
        let hadChanges = session.hasChanges
        session.updateContentFilter { $0.enable_code = true }
        try check(session.hasChanges && session.contentFilter.enable_code, "SettingsSession.updateContentFilter did not mark draft changed")
        session.discard()
        try check(session.hasChanges == hadChanges && !session.contentFilter.enable_code, "SettingsSession.discard did not restore contentFilter")
        print("Build 33 Phase 2 regressions passed (network f_fstypename, GemmaAssetManager, ContentFilter, preview-content-scope, ExternalVolume, SettingsSession)")
    }

    private func verifyV061SettingsAndLocalEmbedding(_ app: AppDelegate, settings: NSPanel, session: SettingsSession) async throws {
        // 1. Config roundtrip under isolated UserDefaults (zero secrets).
        let suite = "io.github.surfire.lumen.smoke.v061.embedding.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure("failed to create isolated UserDefaults suite for v061 embedding smoke")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let defaultConfig = TextEmbeddingBackendConfig.load(from: defaults)
        try check(defaultConfig.mode == .builtin && defaultConfig.baseURL == "http://127.0.0.1:8000/v1"
                  && defaultConfig.model.isEmpty && defaultConfig.dimensions == nil && defaultConfig.signature == nil,
                  "unexpected default TextEmbeddingBackendConfig: \(defaultConfig)")

        let savedConfig = TextEmbeddingBackendConfig(
            mode: .localOpenAI,
            baseURL: "http://127.0.0.1:11434/v1",
            model: "bge-m3",
            dimensions: 1024,
            signature: "openai-local:bge-m3@1024"
        )
        savedConfig.save(to: defaults)
        let reloadedConfig = TextEmbeddingBackendConfig.load(from: defaults)
        try check(reloadedConfig == savedConfig, "TextEmbeddingBackendConfig roundtrip mismatch: \(reloadedConfig)")
        if let rawData = defaults.data(forKey: TextEmbeddingBackendConfig.defaultsKey),
           let rawText = String(data: rawData, encoding: .utf8) {
            for forbidden in ["apiKey", "api_key", "secret", "token", "Bearer"] {
                try check(!rawText.contains(forbidden), "unexpected secret field '\(forbidden)' in UserDefaults config")
            }
        } else {
            throw Failure("TextEmbeddingBackendConfig did not persist under \(TextEmbeddingBackendConfig.defaultsKey)")
        }

        // 2. Loopback URL validation (matching Rust local_openai::validate_loopback_url).
        for validURL in [
            "http://127.0.0.1:8000/v1",
            "http://127.0.0.1:11434",
            "http://localhost:11434/v1",
            "http://[::1]:8000/v1",
            "unix:///tmp/omlx.sock",
        ] {
            try check(isLoopbackEndpointURL(validURL), "isLoopbackEndpointURL rejected valid loopback URL: \(validURL)")
        }
        for invalidURL in [
            "",
            "https://api.openai.com",
            "https://api.openai.com/v1",
            "https://127.0.0.1:8000/v1",
            "http://192.168.1.5:8000",
            "http://192.168.1.5:8000/v1",
            "http://user:pass@127.0.0.1:8000/v1",
            "http://127.0.0.1:8000/v1?token=1",
            "http://127.0.0.1:8000/v1#frag",
            "http://127.0.0.1:/v1",
            "unix://relative.sock",
            "unix://127.0.0.1/tmp/a.sock",
        ] {
            try check(!isLoopbackEndpointURL(invalidURL), "isLoopbackEndpointURL accepted non-loopback/unsafe URL: \(invalidURL)")
        }

        // 3. Decoupled CLI argument generation (text backend vs built-in Gemma image search).
        let fakeGemma = directory.appendingPathComponent("fake-gemma-home", isDirectory: true)
        let fakeProjector = fakeGemma.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
        let cliEngine = LauncherEngine(
            executable: Bundle.main.url(forResource: "lumen", withExtension: nil) ?? directory,
            database: directory.appendingPathComponent("v061-cli-args.sqlite"),
            gemmaHome: fakeGemma
        )
        try check(cliEngine.embedArguments(stream: false) == ["embed", "--gemma", "--max", "32", "--gemma-home", fakeGemma.path]
                  && cliEngine.modelStatusArguments(verify: true) == ["model-status", "--gemma", "--verify", "--gemma-home", fakeGemma.path]
                  && cliEngine.semanticServeArguments() == ["semantic-serve", "--gemma-home", fakeGemma.path]
                  && cliEngine.imageIndexArguments(projector: fakeProjector, stream: true) == ["image-index", "--projector", fakeProjector.path, "--stream", "--max", "16", "--gemma-home", fakeGemma.path]
                  && cliEngine.imageServeArguments(projector: fakeProjector) == ["image-serve", "--projector", fakeProjector.path, "--gemma-home", fakeGemma.path],
                  "default builtin CLI arguments mismatch")

        cliEngine.setTextEmbeddingBackend(savedConfig)
        let expectedOpenAI = ["--openai-url", "http://127.0.0.1:11434/v1", "--openai-model", "bge-m3"]
        try check(cliEngine.embedArguments(stream: true) == ["embed"] + expectedOpenAI + ["--stream", "--max", "32"]
                  && cliEngine.modelStatusArguments(verify: true) == ["model-status"] + expectedOpenAI + ["--verify"]
                  && cliEngine.statusArguments(includeScope: true) == ["status", "--include-scope"] + expectedOpenAI
                  && cliEngine.statusArguments(includeScope: true, includeLocalOpenAI: false) == ["status", "--include-scope"]
                  && cliEngine.diagnoseArguments(path: "/tmp/doc.pdf") == ["diagnose"] + expectedOpenAI + ["--", "/tmp/doc.pdf"]
                  && cliEngine.semanticServeArguments() == ["semantic-serve"] + expectedOpenAI + ["--gemma-home", fakeGemma.path]
                  && cliEngine.imageIndexArguments(projector: fakeProjector, stream: false) == ["image-index", "--projector", fakeProjector.path, "--max", "16", "--gemma-home", fakeGemma.path]
                  && cliEngine.imageServeArguments(projector: fakeProjector) == ["image-serve", "--projector", fakeProjector.path, "--gemma-home", fakeGemma.path],
                  "localOpenAI CLI arguments failed to decouple text vs image")

        // Verify invalid non-loopback config in Launcher never passes --openai-url or falls back to --gemma.
        let invalidBackend = TextEmbeddingBackendConfig(mode: .localOpenAI, baseURL: "https://api.openai.com/v1", model: "text-embedding-3-small")
        try check(!invalidBackend.isValidLocalOpenAI && invalidBackend.openAICliArguments.isEmpty,
                  "non-loopback TextEmbeddingBackendConfig reported valid")

        // 4. Settings UI structure, zero "鹿鸣" branding, window dimensions, and live Light/Dark rendering across all 6 pages.
        try check(LauncherSettings.aboutDisplayTitle() == "Lumen", "About title must be strictly Lumen")
        try check(settings.contentMinSize.width >= 740 && settings.contentMinSize.height >= 560,
                  "Settings min size too small: \(settings.contentMinSize)")
        let expectedRawPages: Set<String> = ["general", "index", "quicklinks", "snippets", "translation", "scripts", "advanced"]
        try check(Set(SettingsPage.allCases.map(\.rawValue)) == expectedRawPages,
                  "SettingsPage cases changed: \(SettingsPage.allCases.map(\.rawValue))")
        let model = app.model
        for pageCase in SettingsPage.allCases {
            for isZH in [true, false] {
                let savedLang = model.language
                model.language = isZH ? "zh" : "en"
                let title = pageCase.title(model)
                let subtitle = pageCase.subtitle(model)
                model.language = savedLang
                try check(!title.isEmpty && !subtitle.isEmpty && !title.contains("鹿鸣") && !subtitle.contains("鹿鸣"),
                          "Invalid page title/subtitle for \(pageCase.rawValue): \(title) / \(subtitle)")
            }
        }

        // Verify TextEmbeddingBackendConfig wiring on an isolated Launcher instance.
        let isoSuite = "io.github.surfire.lumen.smoke.v061.launcher.\(UUID().uuidString)"
        if let isoDefaults = UserDefaults(suiteName: isoSuite) {
            defer { isoDefaults.removePersistentDomain(forName: isoSuite) }
            let isoEngine = LauncherEngine(executable: fakeGemma, database: directory.appendingPathComponent("iso.sqlite"), gemmaHome: fakeGemma)
            let isoLauncher = Launcher(engine: isoEngine, defaults: isoDefaults, locale: "en",
                                       currencyStore: makeCurrencyStore(),
                                       bookmarkLibrary: makeBookmarkLibrary(),
                                       personalDataStore: makePersonalDataStore(),
                                       snippetsDirectory: directory.appendingPathComponent("v061-snippets-\(UUID().uuidString)", isDirectory: true))
            defer { isoLauncher.close() }
            try check(isoLauncher.textEmbeddingBackend.mode == .builtin, "Launcher did not default to .builtin")
            isoLauncher.applyTextEmbeddingBackend(savedConfig)
            try check(isoLauncher.textEmbeddingBackend == savedConfig && isoEngine.textEmbeddingBackend == savedConfig,
                      "applyTextEmbeddingBackend did not update Launcher and LauncherEngine")
            try check(TextEmbeddingBackendConfig.load(from: isoDefaults) == savedConfig,
                      "applyTextEmbeddingBackend did not persist config to UserDefaults")
        }

        let savedPage = session.page
        let savedAppearance = settings.appearance
        defer {
            session.page = savedPage
            settings.appearance = savedAppearance
        }
        for pageCase in SettingsPage.allCases {
            session.page = pageCase
            try await Task.sleep(for: .milliseconds(40))
            let light = try render(.aqua, window: settings)
            let dark = try render(.darkAqua, window: settings)
            if let contentView = settings.contentView {
                try check(settings.frame.width <= 780.5 && contentView.frame.width <= 780.5,
                          "SettingsPage.\(pageCase.rawValue) expanded window past 780pt: window=\(settings.frame.width) view=\(contentView.frame.width)")
            }
            let sidebarMarginX = max(1, Int(Double(light.pixelsWide) * 0.005))
            let sidebarHeaderY = max(1, Int(Double(light.pixelsHigh) * 0.04))
            if let margin = light.colorAt(x: sidebarMarginX, y: sidebarHeaderY)?.usingColorSpace(.sRGB) {
                let marginLuma = 0.2126 * margin.redComponent + 0.7152 * margin.greenComponent + 0.0722 * margin.blueComponent
                try check(marginLuma > 0.90,
                          "SettingsPage.\(pageCase.rawValue) clipped sidebar left margin (luma=\(marginLuma))")
            }
            let canvasX = max(1, Int(Double(light.pixelsWide) * 0.75))
            let canvasY = max(1, Int(Double(light.pixelsHigh) * 0.08))
            if let lc = light.colorAt(x: canvasX, y: canvasY)?.usingColorSpace(.sRGB),
               let dc = dark.colorAt(x: canvasX, y: canvasY)?.usingColorSpace(.sRGB) {
                let lightLuma = 0.2126 * lc.redComponent + 0.7152 * lc.greenComponent + 0.0722 * lc.blueComponent
                let darkLuma = 0.2126 * dc.redComponent + 0.7152 * dc.greenComponent + 0.0722 * dc.blueComponent
                try check(lightLuma > 0.85 && darkLuma < 0.25,
                          "SettingsPage.\(pageCase.rawValue) did not adapt dynamically to Light/Dark (light=\(lightLuma), dark=\(darkLuma))")
            }
        }
        try check(!settings.isVisible && !NSApp.isActive, "Settings verification activated the app or showed a window")
        try await verifyV063SwiftDecoupleSettings()
        try verifyFileDefaultActionPersistence()
        print("v0.6.1 Settings UI & Local OpenAI Embedding smoke passed (config roundtrip, loopback validation, decoupled CLI args, zero 鹿鸣, Light/Dark rendering)")
    }

    private func verifyV063SwiftDecoupleSettings() async throws {
        // Issues #1, #2, #4: cold-start readiness with missing socket, dimension refresh, and lease permission error.
        let dir = directory.appendingPathComponent("v063-swift-decouple-settings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("index.sqlite")
        try Data().write(to: db)
        let engineFile = dir.appendingPathComponent("engine")
        let script = #"""
        #!/usr/bin/python3
        import json, signal, sys
        from pathlib import Path
        root = Path(__file__).parent
        command, *args = sys.argv[3:]
        if command == 'status':
            with (root / 'status-calls.log').open('a') as f:
                f.write(' '.join(args) + '\n')
            if '--openai-url' in args and (root / 'fail-openai-status').exists():
                sys.exit('connect unix socket: No such file or directory')
            dims = int((root / 'server-dims').read_text().strip()) if (root / 'server-dims').exists() else 16
            embedded = 5 if dims == 16 else 0
            print(json.dumps(dict(
                items=3, documents=1,
                scope=dict(roots=[str(root)], allow=[], deny=[], documents=True, content_roots=[str(root)]),
                content=dict(pending=0, checked=1, total=1),
                gemma=dict(documents_enabled=True, embedded_chunks=embedded, skipped_chunks=0,
                           pending=(dims != 16), limited=False, chunk_limit=100),
                images=dict(enabled=False, vectors=0, pending=False, limited=False, vector_limit=100)
            )))
        elif command == 'model-status':
            if (root / 'fail-model-status').exists():
                print(json.dumps(dict(available=False, verified=False, diagnostic='connect: No such file or directory')))
                sys.exit(1)
            dims = int((root / 'server-dims').read_text().strip()) if (root / 'server-dims').exists() else 16
            print(json.dumps(dict(
                available=True, verified='--verify' in args,
                dimensions=dims, signature=f'openai-local:qwen3@{dims}'
            )))
        elif command == 'watch':
            if '--help' in args:
                print('--progress')
            else:
                with (root / 'watch-launches.log').open('a') as f:
                    f.write('watch\n')
                if (root / 'perm-denied-watch').exists():
                    sys.exit('open index writer lease: Permission denied')
                print('{"event":"ready"}', flush=True)
                signal.pause()
        """#
        try Data(script.utf8).write(to: engineFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engineFile.path)

        let failOpenAI = dir.appendingPathComponent("fail-openai-status")
        let failModel = dir.appendingPathComponent("fail-model-status")
        let serverDims = dir.appendingPathComponent("server-dims")
        try Data().write(to: failOpenAI)
        try Data().write(to: failModel)
        try Data("16".utf8).write(to: serverDims)

        let suite1 = "io.github.surfire.lumen.smoke.v063.decouple.\(UUID().uuidString)"
        guard let defaults1 = UserDefaults(suiteName: suite1) else {
            throw Failure("failed to create isolated UserDefaults for v063 decouple smoke")
        }
        defer { defaults1.removePersistentDomain(forName: suite1) }
        let missingSockURL = "unix://\(dir.path)/missing-\(UUID().uuidString).sock"
        TextEmbeddingBackendConfig(mode: .localOpenAI, baseURL: missingSockURL, model: "qwen3").save(to: defaults1)

        let engine1 = LauncherEngine(executable: engineFile, database: db, supportsStreamingBatches: true)
        let model1 = makeIsolatedLauncher(engine: engine1, defaults: defaults1, locale: "en")
        defer { model1.close() }
        model1.start(automaticallyIndex: false)

        try await until("cold start with offline localOpenAI failed to become searchable and watch-ready") {
            model1.canSearch && model1.indexPhase == .ready && model1.watchState == .running
        }
        try await until("refreshCoverage did not probe localOpenAI status and surface AI notice") {
            model1.embeddingNotice?.problem == .embeddings &&
                model1.localModelState == .unavailable(.verification)
        }
        try check(model1.canSearch && model1.indexPhase == .ready && model1.indexNotice == nil,
                  "offline localOpenAI status revoked file search readiness: phase=\(model1.indexPhase) notice=\(String(describing: model1.indexNotice))")
        let statusCalls = try String(contentsOf: dir.appendingPathComponent("status-calls.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try check(statusCalls.first?.contains("--openai-url") == false &&
                  statusCalls.contains(where: { $0.contains("--openai-url") }),
                  "expected cold-start status without --openai-url followed by coverage refresh with --openai-url: \(statusCalls)")

        // Issue #2: verifyLocalModel dimension update (16d -> 24d) automatically refreshes coverage.
        try? FileManager.default.removeItem(at: failOpenAI)
        try? FileManager.default.removeItem(at: failModel)
        model1.verifyLocalModel()
        try await until("verifyLocalModel 16d did not update backend dims and coverage") {
            model1.localModelState == .ready &&
                model1.textEmbeddingBackend.dimensions == 16 &&
                model1.gemmaCoverage?.embedded_chunks == 5 &&
                model1.gemmaCoverage?.pending == false &&
                model1.embeddingNotice == nil
        }
        try Data("24".utf8).write(to: serverDims)
        model1.verifyLocalModel()
        try await until("verifyLocalModel 24d did not trigger refreshCoverage for updated partition") {
            model1.localModelState == .ready &&
                model1.textEmbeddingBackend.dimensions == 24 &&
                model1.textEmbeddingBackend.signature == "openai-local:qwen3@24" &&
                model1.gemmaCoverage?.embedded_chunks == 0 &&
                model1.gemmaCoverage?.pending == true
        }
        model1.close()

        // Issue #4: "open index writer lease: Permission denied" fails watch immediately without lease retries.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("watch-launches.log"))
        try Data().write(to: dir.appendingPathComponent("perm-denied-watch"))
        let suite2 = "io.github.surfire.lumen.smoke.v063.watchperm.\(UUID().uuidString)"
        guard let defaults2 = UserDefaults(suiteName: suite2) else {
            throw Failure("failed to create isolated UserDefaults for v063 watch perm smoke")
        }
        defer { defaults2.removePersistentDomain(forName: suite2) }
        let engine2 = LauncherEngine(executable: engineFile, database: db, supportsStreamingBatches: true)
        let model2 = makeIsolatedLauncher(engine: engine2, defaults: defaults2, locale: "en")
        defer { model2.close() }
        model2.start(automaticallyIndex: false)
        try await until("watcher permission failure did not transition immediately to .failed") {
            model2.watchState == .failed && model2.watchNotice?.problem == .watch
        }
        let watchLaunches = try String(contentsOf: dir.appendingPathComponent("watch-launches.log"), encoding: .utf8)
            .split(separator: "\n").count
        try check(watchLaunches == 1, "watcher retried lease permission error (\(watchLaunches) launches)")
        if let notice = model2.watchNotice {
            let renderedTitle = model2.title(for: notice)
            try check(!renderedTitle.contains("写锁") && !renderedTitle.contains("index lock"),
                      "permission error notice title mentioned lock contention: \(renderedTitle)")
        }
        model2.close()
        print("v0.6.3 Swift decouple settings regressions passed (#1 cold-start readiness, #2 dims coverage refresh, #4 lease permission failure)")
    }

    private func verifyV060SwiftUXRegressions(_ app: AppDelegate) async throws {
        // 1. Query-conditioned hashed frecency: query-specific boost outranks globally opened targets, zero plaintext in UserDefaults.
        let suiteName = "io.github.surfire.lumen.smoke.v060.frecency.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure("failed to create isolated UserDefaults suite for v060 frecency smoke")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let frecency = LauncherFrecency(defaults: defaults)
        let globalHit = SearchHit(path: "/private/tmp/v060-secret-dir/PlaintextGlobalAlpha.pdf",
                                  name: "PlaintextGlobalAlpha.pdf", kind: "file", availability: "local",
                                  matched_by: "name", snippet: nil, document_stamp: nil, pdf_page: nil)
        let queryHit = SearchHit(path: "/private/tmp/v060-secret-dir/PlaintextQueryBeta.pdf",
                                 name: "PlaintextQueryBeta.pdf", kind: "file", availability: "local",
                                 matched_by: "name", snippet: nil, document_stamp: nil, pdf_page: nil)
        let globalID = LauncherFrecency.fileID(globalHit.path)
        let queryID = LauncherFrecency.fileID(queryHit.path)
        let now = Date.now

        for step in 0..<8 {
            frecency.noteOpened(globalID, query: "UnrelatedPlaintextQuery", now: now.addingTimeInterval(Double(step)))
        }
        frecency.noteOpened(queryID, query: "  Quarterly   Report  ", now: now.addingTimeInterval(10))

        let globalBoostForQuery = frecency.boost(globalID, query: "quarterly report", now: now.addingTimeInterval(11))
        let specificBoostForQuery = frecency.boost(queryID, query: "QUARTERLY REPORT", now: now.addingTimeInterval(11))
        try check(specificBoostForQuery > globalBoostForQuery && specificBoostForQuery >= 15,
                  "query-conditioned frecency did not boost query-specific target (\(specificBoostForQuery)) above global target (\(globalBoostForQuery))")
        try check(frecency.rankFiles([globalHit, queryHit], query: "  quarterly report ").first == queryHit,
                  "rankFiles(query:) did not promote query-conditioned file hit over globally opened file hit")
        try check(frecency.rankFiles([globalHit, queryHit]).first == globalHit,
                  "rankFiles() without query did not preserve global frecency ranking")

        let reloadedFrecency = LauncherFrecency(defaults: defaults)
        try check(reloadedFrecency.rankFiles([globalHit, queryHit], query: "quarterly report").first == queryHit,
                  "reloaded LauncherFrecency did not persist query-conditioned ranking")

        guard let rawGlobalData = defaults.data(forKey: "launcher.frecency.v1"),
              let rawQueryData = defaults.data(forKey: "launcher.frecency.query.v1"),
              let rawGlobalText = String(data: rawGlobalData, encoding: .utf8),
              let rawQueryText = String(data: rawQueryData, encoding: .utf8) else {
            throw Failure("frecency UserDefaults data missing for launcher.frecency.v1 or launcher.frecency.query.v1")
        }
        for forbidden in ["Quarterly", "quarterly", "Report", "report", "UnrelatedPlaintextQuery", "unrelatedplaintextquery",
                          "v060-secret-dir", "PlaintextGlobalAlpha", "PlaintextQueryBeta", ".pdf"] {
            try check(!rawGlobalText.contains(forbidden) && !rawQueryText.contains(forbidden),
                      "plaintext token '\(forbidden)' leaked into UserDefaults frecency payload")
        }
        let decodedQueryMap = try JSONDecoder().decode([String: [String: Double]].self, from: rawQueryData)
        try check(!decodedQueryMap.isEmpty && decodedQueryMap.keys.allSatisfy { $0.hasPrefix("q:") },
                  "launcher.frecency.query.v1 keys did not use 'q:' SHA-256 format: \(decodedQueryMap.keys)")

        // 2. App word/camelCase initials (vsc, wc, am, st, it) & curated aliases (ps, wx, ai, pr, ae, term, pref, top).
        let dummyURL = URL(fileURLWithPath: "/Applications/Dummy.app", isDirectory: true)
        try check(LaunchCatalog.initialsAliases("Visual Studio Code") == ["vsc"] &&
                  LaunchCatalog.initialsAliases("Activity Monitor") == ["am"] &&
                  LaunchCatalog.initialsAliases("WeChat") == ["wc"] &&
                  LaunchCatalog.initialsAliases("SublimeText") == ["st"] &&
                  LaunchCatalog.initialsAliases("iTerm") == ["it"],
                  "LaunchCatalog.initialsAliases did not produce expected word/camelCase initials")

        let vscApp = LaunchAction(id: "app:v060.vsc", english: "Visual Studio Code", chinese: "Visual Studio Code",
                                  symbol: "app", destination: .application(dummyURL, stamp: "0"), aliases: [])
        let wechatApp = LaunchAction(id: "app:v060.wechat", english: "WeChat", chinese: "微信",
                                     symbol: "app", destination: .application(dummyURL, stamp: "0"), aliases: [])
        let activityApp = LaunchAction(id: "app:v060.am", english: "Activity Monitor", chinese: "活动监视器",
                                       symbol: "app", destination: .application(dummyURL, stamp: "0"), aliases: [])
        let sublimeApp = LaunchAction(id: "app:v060.st", english: "SublimeText", chinese: "SublimeText",
                                      symbol: "app", destination: .application(dummyURL, stamp: "0"), aliases: [])
        let itermApp = LaunchAction(id: "app:v060.it", english: "iTerm", chinese: "iTerm",
                                    symbol: "app", destination: .application(dummyURL, stamp: "0"), aliases: [])
        let psApp = LaunchAction(id: "app:v060.ps", english: "Adobe Photoshop 2026", chinese: "Photoshop",
                                 symbol: "app", destination: .application(dummyURL, stamp: "0"), aliases: [])
        let distractorPS = LaunchAction(id: "app:v060.psviewer", english: "PSViewer", chinese: "PSViewer",
                                        symbol: "app", destination: .application(dummyURL, stamp: "0"), aliases: [])
        let distractorVSC = LaunchAction(id: "app:v060.vscatalog", english: "VSCatalog", chinese: "VSCatalog",
                                         symbol: "app", destination: .application(dummyURL, stamp: "0"), aliases: [])
        let catalog = [distractorPS, distractorVSC, vscApp, wechatApp, activityApp, sublimeApp, itermApp, psApp]

        for action in catalog {
            try check(Set(action.normalizedSearchable).count == action.normalizedSearchable.count,
                      "LaunchAction.normalizedSearchable contained duplicate entries: \(action.normalizedSearchable)")
        }
        for (query, expected) in [
            ("vsc", vscApp), ("vscode", vscApp), ("code", vscApp),
            ("wc", wechatApp), ("wx", wechatApp),
            ("am", activityApp), ("top", activityApp),
            ("st", sublimeApp), ("it", itermApp), ("ps", psApp),
        ] {
            let match = LaunchCatalog.matches(query, actions: catalog).first
            try check(match?.action == expected && (match?.score ?? 0) >= 96,
                      "LaunchCatalog.matches('\(query)') matched \(String(describing: match?.action.id)) (score \(String(describing: match?.score))), expected \(expected.id)")
        }

        // Also verify query-conditioned action frecency in LaunchCatalog.matches.
        for step in 0..<6 {
            frecency.noteOpened(sublimeApp.id, query: "unrelated", now: now.addingTimeInterval(Double(step)))
        }
        frecency.noteOpened(vscApp.id, query: "editor", now: now.addingTimeInterval(10))
        try check(frecency.boost(vscApp.id, query: "editor", now: now.addingTimeInterval(11)) >
                  frecency.boost(sublimeApp.id, query: "editor", now: now.addingTimeInterval(11)),
                  "query-conditioned action frecency did not outrank globally opened action")

        // 3. ContentPreview.Subfolder decoding both with and without noise_reason + localized noise reason labels.
        let withReasonJSON = Data(#"{"path":"/tmp/ComfyUI/output","name":"output","count":1200,"suggested_noise":true,"noise_reason":"ai_runtime"}"#.utf8)
        let withoutReasonJSON = Data(#"{"path":"/tmp/docs","name":"docs","count":12,"suggested_noise":false}"#.utf8)
        let decodedWithReason = try JSONDecoder().decode(ContentPreview.Subfolder.self, from: withReasonJSON)
        let decodedWithoutReason = try JSONDecoder().decode(ContentPreview.Subfolder.self, from: withoutReasonJSON)
        try check(decodedWithReason.noise_reason == "ai_runtime" && decodedWithReason.suggested_noise && decodedWithReason.count == 1200,
                  "ContentPreview.Subfolder failed to decode noise_reason")
        try check(decodedWithoutReason.noise_reason == nil && !decodedWithoutReason.suggested_noise,
                  "ContentPreview.Subfolder failed backward-compatible decoding without noise_reason")
        try check(LauncherSettings.noiseReasonLabel("ai_runtime", zh: true) == "AI 运行时" &&
                  LauncherSettings.noiseReasonLabel("ai_runtime", zh: false) == "AI Runtime" &&
                  LauncherSettings.noiseReasonLabel("image_dump", zh: true) == "高图占比" &&
                  LauncherSettings.noiseReasonLabel("sequential_frames", zh: true) == "序列帧" &&
                  LauncherSettings.noiseReasonLabel("high_volume", zh: false) == "High Volume" &&
                  LauncherSettings.noiseReasonLabel("noise_dir", zh: false) == "Noise" &&
                  LauncherSettings.noiseReasonLabel(nil, zh: true) == nil,
                  "LauncherSettings.noiseReasonLabel localized mapping mismatch")

        // 4. LumenApp.linkedMediaURL(forSubtitlePath:) sibling matching.
        let mediaDir = URL(fileURLWithPath: IndexScope.folderPath(directory), isDirectory: true)
            .appendingPathComponent("v060-linked-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaDir) }

        let lectureSrt = mediaDir.appendingPathComponent("lecture.srt")
        let lectureMp4 = mediaDir.appendingPathComponent("lecture.mp4")
        let podcastVtt = mediaDir.appendingPathComponent("podcast.vtt")
        let podcastM4a = mediaDir.appendingPathComponent("podcast.m4a")
        let orphanSrt = mediaDir.appendingPathComponent("orphan.srt")
        let notesTxt = mediaDir.appendingPathComponent("notes.txt")
        let notesMp4 = mediaDir.appendingPathComponent("notes.mp4")

        for file in [lectureSrt, lectureMp4, podcastVtt, podcastM4a, orphanSrt, notesTxt, notesMp4] {
            try Data("fixture".utf8).write(to: file)
        }
        try check(LumenApp.linkedMediaURL(forSubtitlePath: lectureSrt.path)?.resolvingSymlinksInPath() == lectureMp4.resolvingSymlinksInPath(),
                  "linkedMediaURL did not resolve sibling .mp4 for .srt")
        try check(LumenApp.linkedMediaURL(forSubtitlePath: podcastVtt.path)?.resolvingSymlinksInPath() == podcastM4a.resolvingSymlinksInPath(),
                  "linkedMediaURL did not resolve sibling .m4a for .vtt")
        try check(LumenApp.linkedMediaURL(forSubtitlePath: orphanSrt.path) == nil,
                  "linkedMediaURL did not return nil when no sibling media exists")
        try check(LumenApp.linkedMediaURL(forSubtitlePath: notesTxt.path) == nil,
                  "linkedMediaURL matched non-subtitle .txt file")
        print("v0.6.0 Swift UX regressions passed (query-conditioned hashed frecency, app initials/aliases, noise_reason decoding, linkedMediaURL)")
    }

    private func verifyFileDefaultActionPersistence() throws {
        let suite = "io.github.surfire.lumen.smoke.v064.filedefault.\(UUID().uuidString)"
        guard let isoDefaults = UserDefaults(suiteName: suite) else {
            throw Failure("failed to create isolated UserDefaults suite for fileDefaultAction smoke")
        }
        defer { isoDefaults.removePersistentDomain(forName: suite) }

        let fakeGemma = directory.appendingPathComponent("v064-gemma", isDirectory: true)
        let db = directory.appendingPathComponent("v064-filedefault.sqlite")
        func makeLauncher() -> Launcher {
            Launcher(engine: LauncherEngine(executable: fakeGemma, database: db, gemmaHome: fakeGemma),
                     defaults: isoDefaults, locale: "en",
                     currencyStore: makeCurrencyStore(),
                     bookmarkLibrary: makeBookmarkLibrary(),
                     personalDataStore: makePersonalDataStore())
        }

        let initial = makeLauncher()
        defer { initial.close() }
        try check(initial.fileDefaultAction == .open && isoDefaults.string(forKey: "fileDefaultAction") == nil,
                  "fresh Launcher did not default fileDefaultAction to .open without writing UserDefaults")
        initial.setFileDefaultAction(.open)
        try check(isoDefaults.string(forKey: "fileDefaultAction") == nil,
                  "setFileDefaultAction(.open) wrote UserDefaults on unchanged value")
        initial.setFileDefaultAction(.revealInFinder)
        try check(initial.fileDefaultAction == .revealInFinder &&
                  isoDefaults.string(forKey: "fileDefaultAction") == "revealInFinder",
                  "setFileDefaultAction(.revealInFinder) did not update state and UserDefaults")

        let reloaded = makeLauncher()
        defer { reloaded.close() }
        try check(reloaded.fileDefaultAction == .revealInFinder,
                  "fileDefaultAction(.revealInFinder) did not survive reload across a fresh Launcher instance")
        reloaded.setFileDefaultAction(.open)
        try check(reloaded.fileDefaultAction == .open && isoDefaults.string(forKey: "fileDefaultAction") == "open",
                  "setFileDefaultAction(.open) did not persist back to UserDefaults")

        let reloadedOpen = makeLauncher()
        defer { reloadedOpen.close() }
        try check(reloadedOpen.fileDefaultAction == .open,
                  "fileDefaultAction(.open) did not survive reload across a fresh Launcher instance")

        isoDefaults.set("invalid-action", forKey: "fileDefaultAction")
        let fallback = makeLauncher()
        defer { fallback.close() }
        try check(fallback.fileDefaultAction == .open,
                  "unknown UserDefaults fileDefaultAction value did not fall back to .open")
    }

    private func makeFileDefaultActionFixtures() throws -> (openFile: URL, revealFile: URL, dblClickFile: URL, folder: URL) {
        let openFile = corpus.appendingPathComponent("v064-default-open-file.txt")
        let revealFile = corpus.appendingPathComponent("v064-default-reveal-file.txt")
        let dblClickFile = corpus.appendingPathComponent("v064-default-dblclick-file.txt")
        let folder = corpus.appendingPathComponent("v064-default-folder", isDirectory: true)
        try Data("v064 open fixture".utf8).write(to: openFile)
        try Data("v064 reveal fixture".utf8).write(to: revealFile)
        try Data("v064 double-click fixture".utf8).write(to: dblClickFile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (openFile, revealFile, dblClickFile, folder)
    }

    private func verifyFileDefaultActionRegressions(
        _ app: AppDelegate,
        fixtures: (openFile: URL, revealFile: URL, dblClickFile: URL, folder: URL)
    ) async throws {
        try verifyFileDefaultActionPersistence()

        guard let defaults = shortcutFixturePreferences else {
            throw Failure("missing isolated preferences for fileDefaultAction smoke")
        }
        let model = app.model
        let previousAction = model.fileDefaultAction
        defer {
            model.setFileDefaultAction(previousAction)
            opened = nil
            revealed = nil
        }

        let openFilePath = IndexScope.folderPath(fixtures.openFile)
        let revealFilePath = IndexScope.folderPath(fixtures.revealFile)
        let dblClickFilePath = IndexScope.folderPath(fixtures.dblClickFile)
        let folderPath = IndexScope.folderPath(fixtures.folder)

        func selectFixture(_ query: String, path: String, kind: String) async throws -> SearchHit {
            app.showSearch()
            try type(query, into: app)
            try await until("v064 fixture not indexed: \(query)") {
                !model.searching && model.hits.contains { $0.path == path && $0.kind == kind }
            }
            if model.selectedHit?.path != path { model.selection = path }
            guard let hit = model.selectedHit, hit.path == path else {
                throw Failure("could not select v064 fixture: \(query)")
            }
            return hit
        }

        func frecencyBoost(_ hit: SearchHit, query: String) -> Int {
            LauncherFrecency(defaults: defaults).boost(LauncherFrecency.fileID(hit.path), query: query)
        }

        // (a) Default `.open` mode: Return & double-click open + dismiss; Cmd+Return reveals + dismisses + records Frecency.
        model.setFileDefaultAction(.open)
        try check(model.fileDefaultAction == .open, "expected default fileDefaultAction to be .open")

        let openHit = try await selectFixture("v064-default-open-file", path: openFilePath, kind: "file")
        try check(!model.usesRevealDefault(for: openHit) &&
                  model.primaryFileAction(for: openHit) == .open &&
                  model.secondaryFileAction(for: openHit) == .reveal,
                  ".open mode did not report primary=.open / secondary=.reveal")
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.isOpen &&
                  app.contextActions.items.prefix(2).map(\.id) == ["open", "reveal"] &&
                  app.contextActions.items[0].symbol == "return" &&
                  app.contextActions.items[1].symbol == "folder",
                  ".open mode Cmd+K ordering or symbols mismatch: \(app.contextActions.items.map { ($0.id, $0.symbol) })")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.contextActions.isOpen && app.searchPresented, "Escape did not close Cmd+K menu in .open mode")

        opened = nil
        revealed = nil
        try key(kVK_Return, "\r", in: app)
        try await until(".open mode Return did not open file and dismiss search") {
            self.opened?.path == openFilePath && self.revealed == nil && !app.searchPresented && model.query.isEmpty
        }
        opened = nil

        _ = try await selectFixture("v064-default-open-file", path: openFilePath, kind: "file")
        opened = nil
        revealed = nil
        app.selectRow(.file(openHit), doubleClick: true)
        try await until(".open mode double-click did not open file and dismiss search") {
            self.opened?.path == openFilePath && self.revealed == nil && !app.searchPresented && model.query.isEmpty
        }
        opened = nil

        _ = try await selectFixture("v064-default-open-file", path: openFilePath, kind: "file")
        try check(frecencyBoost(openHit, query: "v064-default-open-file") == 0,
                  "open fixture unexpectedly started with non-zero frecency")
        opened = nil
        revealed = nil
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until(".open mode Cmd+Return did not reveal file and dismiss search") {
            self.revealed?.path == openFilePath && self.opened == nil && !app.searchPresented && model.query.isEmpty
        }
        try check(frecencyBoost(openHit, query: "v064-default-open-file") > 0,
                  ".open mode Cmd+Return revealInFinder did not record Frecency")
        revealed = nil

        // (b) `.revealInFinder` mode: regular files reveal on Return/double-click (+ Frecency) and open on Cmd+Return;
        // Cmd+K puts Show in Finder first; folders and .app bundles keep opening directly on Return and revealing on Cmd+Return.
        model.setFileDefaultAction(.revealInFinder)
        try check(model.fileDefaultAction == .revealInFinder &&
                  defaults.string(forKey: "fileDefaultAction") == "revealInFinder",
                  "setFileDefaultAction(.revealInFinder) did not update live Launcher and defaults")

        let revealHit = try await selectFixture("v064-default-reveal-file", path: revealFilePath, kind: "file")
        try check(model.usesRevealDefault(for: revealHit) &&
                  model.primaryFileAction(for: revealHit) == .reveal &&
                  model.secondaryFileAction(for: revealHit) == .open,
                  ".revealInFinder mode did not flip primary/secondary for regular file")

        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        let revealMenu = app.contextActions.items
        try check(app.contextActions.isOpen &&
                  revealMenu.prefix(2).map(\.id) == ["reveal", "open"] &&
                  revealMenu[0].title == model.t("在 Finder 中显示", "Show in Finder") &&
                  revealMenu[0].symbol == "return" &&
                  revealMenu[1].title == model.t("打开", "Open") &&
                  revealMenu[1].symbol == "arrow.up.forward.square" &&
                  revealMenu.contains { $0.id == "preview" } &&
                  revealMenu.contains { $0.id == "copy-name" } &&
                  revealMenu.contains { $0.id == "copy-path" },
                  ".revealInFinder mode Cmd+K menu mismatch: \(revealMenu.map { ($0.id, $0.title, $0.symbol) })")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(!app.contextActions.isOpen && app.searchPresented, "Escape did not close Cmd+K menu in .revealInFinder mode")

        try check(frecencyBoost(revealHit, query: "v064-default-reveal-file") == 0,
                  "reveal fixture unexpectedly started with non-zero frecency")
        opened = nil
        revealed = nil
        try key(kVK_Return, "\r", in: app)
        try await until(".revealInFinder mode Return did not reveal regular file and dismiss search") {
            self.revealed?.path == revealFilePath && self.opened == nil && !app.searchPresented && model.query.isEmpty
        }
        try check(frecencyBoost(revealHit, query: "v064-default-reveal-file") > 0,
                  ".revealInFinder mode Return reveal did not record Frecency")
        revealed = nil

        let dblClickHit = try await selectFixture("v064-default-dblclick-file", path: dblClickFilePath, kind: "file")
        try check(frecencyBoost(dblClickHit, query: "v064-default-dblclick-file") == 0,
                  "double-click fixture unexpectedly started with non-zero frecency")
        opened = nil
        revealed = nil
        app.selectRow(.file(dblClickHit), doubleClick: true)
        try await until(".revealInFinder mode double-click did not reveal regular file and dismiss search") {
            self.revealed?.path == dblClickFilePath && self.opened == nil && !app.searchPresented && model.query.isEmpty
        }
        try check(frecencyBoost(dblClickHit, query: "v064-default-dblclick-file") > 0,
                  ".revealInFinder mode double-click reveal did not record Frecency")
        revealed = nil

        _ = try await selectFixture("v064-default-reveal-file", path: revealFilePath, kind: "file")
        opened = nil
        revealed = nil
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until(".revealInFinder mode Cmd+Return did not open regular file and dismiss search") {
            self.opened?.path == revealFilePath && self.revealed == nil && !app.searchPresented && model.query.isEmpty
        }
        opened = nil

        let folderHit = try await selectFixture("v064-default-folder", path: folderPath, kind: "directory")
        try check(!model.usesRevealDefault(for: folderHit) &&
                  model.primaryFileAction(for: folderHit) == .open &&
                  model.secondaryFileAction(for: folderHit) == .reveal,
                  ".revealInFinder mode affected directory primary/secondary actions")
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        let folderMenu = app.contextActions.items
        try check(app.contextActions.isOpen &&
                  folderMenu.prefix(2).map(\.id) == ["open", "reveal"] &&
                  folderMenu[0].symbol == "return" &&
                  folderMenu[1].symbol == "folder" &&
                  folderMenu.contains { $0.id == "pin-folder" },
                  ".revealInFinder mode altered directory Cmd+K menu: \(folderMenu.map { ($0.id, $0.symbol) })")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)

        opened = nil
        revealed = nil
        try key(kVK_Return, "\r", in: app)
        try await until(".revealInFinder mode Return did not open directory directly") {
            self.opened?.path == folderPath && self.revealed == nil && !app.searchPresented && model.query.isEmpty
        }
        opened = nil

        _ = try await selectFixture("v064-default-folder", path: folderPath, kind: "directory")
        opened = nil
        revealed = nil
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until(".revealInFinder mode Cmd+Return did not reveal directory in Finder") {
            self.revealed?.path == folderPath && self.opened == nil && !app.searchPresented && model.query.isEmpty
        }
        revealed = nil

        let appFileHit = SearchHit(path: "/Applications/Example.APP", name: "Example.APP", kind: "file",
                                   availability: "local", matched_by: "name", snippet: nil, document_stamp: nil, pdf_page: nil)
        let appDirHit = SearchHit(path: "/Applications/Example.app", name: "Example.app", kind: "directory",
                                  availability: "local", matched_by: "name", snippet: nil, document_stamp: nil, pdf_page: nil)
        for appHit in [appFileHit, appDirHit] {
            try check(!model.usesRevealDefault(for: appHit) &&
                      model.primaryFileAction(for: appHit) == .open &&
                      model.secondaryFileAction(for: appHit) == .reveal,
                      ".revealInFinder mode did not keep .app bundle opening directly: \(appHit.path)")
        }

        model.setFileDefaultAction(previousAction)
        app.showSearch()
        print("v0.6.4 fileDefaultAction regressions passed (.open, .revealInFinder, Return/double-click/Cmd+Return/Cmd+K, folders/.app, Frecency, UserDefaults persistence)")
    }

    private func verifySpotlightParityFeatures(_ app: AppDelegate) async throws {
        let model = app.model
        let fm = FileManager.default
        let captureAll = exists("capture-icons") || exists("capture-snapshots") || exists("capture-spotlight")
        app.settings?.close()
        if !model.canSearch {
            app.startBackgroundIndex()
            try await until("spotlight smoke index ready") { model.canSearch }
        }

        // 1. Currency conversion + daily disk cache + zero network on fresh cache.
        let isoSuite = "io.github.surfire.lumen.smoke.v066.\(UUID().uuidString)"
        guard let isoDefaults = UserDefaults(suiteName: isoSuite) else {
            throw Failure("failed to create isolated UserDefaults suite for spotlight smoke")
        }
        defer { isoDefaults.removePersistentDomain(forName: isoSuite) }

        final class FetchCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var count: Int { lock.withLock { value } }
            func increment() { lock.withLock { value += 1 } }
        }

        let cacheURL = directory.appendingPathComponent("v066-currency-cache.json")
        try? fm.removeItem(at: cacheURL)
        defer { try? fm.removeItem(at: cacheURL) }
        let counter = FetchCounter()
        let mockRateJSON = Data(#"{"result":"success","time_last_update_utc":"Sat, 28 Nov 2026 00:00:00 +0000","base_code":"USD","rates":{"USD":1.0,"CNY":7.5,"EUR":0.9,"JPY":150.0,"GBP":0.78}}"#.utf8)
        let store = CurrencyRateStore(defaults: isoDefaults, cacheURL: cacheURL) { _ in
            counter.increment()
            return mockRateJSON
        }
        try check(store.snapshot.isFallback && store.autoRefreshEnabled && !store.refreshing && store.lastError == nil,
                  "CurrencyRateStore did not start on built-in fallback")
        guard let fallbackEn = CalculationResult.evaluate("$100 to cny", rates: store.snapshot, preferChinese: false),
              let fallbackZh = CalculationResult.evaluate("100美元换人民币", rates: store.snapshot, preferChinese: true) else {
            throw Failure("fallback currency conversion failed for English or Chinese prompt")
        }
        try check(fallbackEn.display.contains("CNY") && fallbackZh.display.contains("CNY") &&
                  fallbackEn.detail != nil && fallbackZh.detail != nil,
                  "currency calculation missing detail or currency unit")

        await store.refreshIfStale()
        try check(counter.count == 1 && !store.snapshot.isFallback && store.snapshot.rates["CNY"] == 7.5 &&
                  fm.fileExists(atPath: cacheURL.path) && store.lastError == nil,
                  "CurrencyRateStore.refreshIfStale did not persist fetched snapshot")
        await store.refreshIfStale()
        try check(counter.count == 1, "CurrencyRateStore re-fetched fresh same-day cache")

        let reloadedStore = CurrencyRateStore(defaults: isoDefaults, cacheURL: cacheURL) { _ in
            counter.increment()
            throw Failure("unexpected network call on fresh cached CurrencyRateStore")
        }
        try check(reloadedStore.snapshot == store.snapshot, "CurrencyRateStore did not reload persisted JSON cache")
        await reloadedStore.refreshIfStale()
        try check(counter.count == 1, "reloaded CurrencyRateStore hit network despite fresh disk cache")

        let badCacheURL = directory.appendingPathComponent("v066-currency-bad.json")
        defer { try? fm.removeItem(at: badCacheURL) }
        let badStore = CurrencyRateStore(defaults: isoDefaults, cacheURL: badCacheURL) { _ in
            Data(#"{"result":"error","rates":{"USD":1.0}}"#.utf8)
        }
        await badStore.refreshNow()
        try check(badStore.snapshot.isFallback && badStore.lastError != nil,
                  "CurrencyRateStore accepted incomplete/invalid currency JSON")

        let injected = CurrencyRateSnapshot(
            base: "USD",
            rates: ["USD": 1.0, "CNY": 8.0, "EUR": 0.9, "JPY": 150.0],
            updatedDate: "2026-11-28",
            fetchedAt: Date(),
            isFallback: false
        )
        model.currencyStore.injectForTesting(injected)
        defer { model.currencyStore.injectForTesting(.fallback) }

        app.showSearch()
        try type("$100 to cny", into: app)
        try await until("injected currency calculation appeared") {
            guard let calc = model.calculation,
                  case .calculation(let first)? = model.visibleResults.first else { return false }
            return first == calc && calc.display.contains("CNY")
        }
        guard let fxCalc = model.calculation else { throw Failure("missing currency calculation") }
        let numericCopy = Double(fxCalc.copyValue.replacingOccurrences(of: ",", with: ""))
        try check(numericCopy == 800.0 && fxCalc.detail?.contains("2026-11-28") == true,
                  "injected currency snapshot did not drive calculation: \(fxCalc)")
        if captureAll {
            try capture("lumen-spotlight-currency.png", appearance: .aqua, window: app.panel)
            print("Screenshot: lumen-spotlight-currency.png")
            app.panel.appearance = nil
        }
        func verifySpotlightInternalCopy(_ label: String) throws {
            let priorCount = app.clipboard.items.count
            try check(filePasteboard.types?.contains(ClipboardManager.internalType) == true, "\(label) was not marked internal")
            app.clipboard.poll()
            try check(app.clipboard.items.count == priorCount, "\(label) leaked into clipboard history")
        }

        try key(kVK_Return, "\r", in: app)
        try await until("Return on currency calculation copied value and dismissed search") {
            self.filePasteboard.string(forType: .string) == fxCalc.copyValue && !app.searchPresented
        }
        try verifySpotlightInternalCopy("Copy Currency Conversion")

        // 2. Prefix-free dictionary lookup (debounced, cancelled on query change, ranked below exact file hit).
        let priorDefinitionProvider = definitionProvider
        definitionProvider = { word in
            switch word.lowercased() {
            case "ephemeral": return "ephemeral | iˈfem(ə)rəl |\nadjective lasting for a very short time."
            case "archive": return "archive | ˈärˌkīv |\nnoun a collection of historical documents."
            default: return nil
            }
        }
        defer { definitionProvider = priorDefinitionProvider }

        app.showSearch()
        try type("ephem", into: app)
        try await Task.sleep(for: .milliseconds(25))
        try type("ephemeral", into: app)
        try check(model.dictionaryQuickResult == nil, "stale prefix dictionary lookup appeared before debounce")
        try await until("prefix-free dictionary result appeared") {
            model.dictionaryQuickResult?.word == "ephemeral" &&
                model.visibleResults.contains {
                    if case .dictionary(let d) = $0 { return d.word == "ephemeral" }
                    return false
                }
        }
        guard let dictQuick = model.dictionaryQuickResult else { throw Failure("missing dictionaryQuickResult") }
        try check(!dictQuick.summary.contains("\n") && dictQuick.summary.count <= 160,
                  "dictionary summary was not compact single-line: \(dictQuick.summary)")
        if captureAll {
            try capture("lumen-spotlight-dictionary.png", appearance: .aqua, window: app.panel)
            print("Screenshot: lumen-spotlight-dictionary.png")
            if exists("capture-spotlight") {
                try capture("spotlight-currency-dictionary.png", appearance: .aqua, window: app.panel)
                print("Screenshot: spotlight-currency-dictionary.png")
            }
            app.panel.appearance = nil
        }

        model.selection = "dict:ephemeral"
        try key(kVK_Return, "\r", in: app)
        try await until("Return on .dictionary row opened definition card") {
            if case .definition(let word, let text, false) = app.panelState.mode {
                return word == "ephemeral" && (text?.contains("lasting for a very short time") ?? false)
            }
            return false
        }
        try key(kVK_Return, "\r", in: app)
        try check(app.commands.definitionCopied &&
                  filePasteboard.string(forType: .string)?.contains("lasting for a very short time") == true,
                  "Return on dictionary card did not copy full definition")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(app.commands.definition == nil && app.panelState.mode == .search,
                  "Escape did not close dictionary card")

        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.map(\.id) == ["show-definition", "copy-definition", "copy-word"],
                  "dictionary Cmd+K menu mismatch: \(app.contextActions.items.map(\.id))")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)

        try type("ephemeral ", into: app)
        try check(model.dictionaryQuickResult == nil &&
                  !model.visibleResults.contains { if case .dictionary = $0 { return true }; return false },
                  "trailing whitespace did not immediately clear prefix-free dictionary result")

        try type("archive", into: app)
        try await until("archive file and dictionary merged") {
            !model.searching &&
                model.hits.contains { $0.name == "archive-one.txt" } &&
                model.dictionaryQuickResult?.word == "archive"
        }
        guard let fileIdx = model.visibleResults.firstIndex(where: {
            if case .file(let h) = $0 { return h.name == "archive-one.txt" }
            return false
        }),
              let dictIdx = model.visibleResults.firstIndex(where: {
                  if case .dictionary(let d) = $0 { return d.word == "archive" }
                  return false
              }) else {
            throw Failure("missing file or dictionary row for archive ranking check")
        }
        try check(fileIdx < dictIdx, "prefix-free dictionary ranked above stronger exact/prefix file hit")

        // 3. Browser bookmarks (synthetic Chromium JSON + Safari Plist + open/copy actions).
        let chromeObj: [String: Any] = [
            "roots": [
                "bookmark_bar": [
                    "type": "folder",
                    "name": "Bookmarks Bar",
                    "children": [[
                        "type": "folder",
                        "name": "Work",
                        "children": [[
                            "type": "url",
                            "name": "Lumen Docs Guide",
                            "url": "https://docs.example.com/lumen/guide",
                        ]],
                    ]],
                ]
            ]
        ]
        let chromeData = try JSONSerialization.data(withJSONObject: chromeObj)
        try chromeData.write(to: smokeChromiumBookmarksURL)
        let safariObj: [String: Any] = [
            "Title": "",
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [[
                "Title": "Reading",
                "WebBookmarkType": "WebBookmarkTypeList",
                "Children": [[
                    "WebBookmarkType": "WebBookmarkTypeLeaf",
                    "URIDictionary": ["title": "Swift Concurrency Notes"],
                    "URLString": "https://swift.example.org/concurrency",
                ]],
            ]],
        ]
        let safariData = try PropertyListSerialization.data(fromPropertyList: safariObj, format: .binary, options: 0)
        try safariData.write(to: smokeSafariBookmarksURL)
        defer {
            try? fm.removeItem(at: smokeChromiumBookmarksURL)
            try? fm.removeItem(at: smokeSafariBookmarksURL)
        }

        await model.bookmarkLibrary.syncNow(force: true)
        try check(model.bookmarkLibrary.enabled && model.bookmarkLibrary.count == 2 &&
                  model.bookmarkLibrary.matches("concurrency").contains { $0.hit.browser == "Safari" },
                  "BookmarkLibrary did not index synthetic Chromium and Safari bookmarks")

        try type("lumen docs guide", into: app)
        try await until("synthetic bookmark appeared in search results") {
            model.visibleResults.contains {
                if case .bookmark(let b) = $0 { return b.title == "Lumen Docs Guide" }
                return false
            }
        }
        guard let bmResult = model.visibleResults.first(where: {
            if case .bookmark(let b) = $0 { return b.title == "Lumen Docs Guide" }
            return false
        }) else { throw Failure("missing bookmark row") }
        model.selection = bmResult.id
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.map(\.id) == ["open-bookmark", "copy-bookmark-url"],
                  "bookmark Cmd+K actions mismatch: \(app.contextActions.items.map(\.id))")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_Return, "\r", in: app)
        try await until("bookmark Copy URL action wrote URL") {
            self.filePasteboard.string(forType: .string) == "https://docs.example.com/lumen/guide" && !app.searchPresented
        }
        try verifySpotlightInternalCopy("Copy Bookmark URL")

        let quicklinksBefore = dispatchedQuicklinks.count
        app.showSearch()
        try type("lumen docs guide", into: app)
        model.selection = bmResult.id
        try key(kVK_Return, "\r", in: app)
        try await until("Return on bookmark opened URL and dismissed search") {
            self.dispatchedQuicklinks.count == quicklinksBefore + 1 &&
                self.dispatchedQuicklinks.last?.absoluteString == "https://docs.example.com/lumen/guide" &&
                !app.searchPresented
        }

        // 4. Strictly opt-in Personal Sources (default-OFF, denied -> stays off, authorized -> search/complete).
        let personal = model.personalDataStore
        personalDataHarness.reset()
        try check(!personal.contactsEnabled && !personal.calendarEnabled && !personal.remindersEnabled,
                  "personal sources were not opt-in by default")
        await personal.refreshIfNeeded(force: true)
        try check(personalDataHarness.accessRequests == 0 && personal.matches("alice").isEmpty,
                  "refreshIfNeeded triggered TCC request or returned results while disabled")

        personalDataHarness.nextAccess = .denied
        await personal.setContactsEnabled(true)
        try check(!personal.contactsEnabled && personal.contactsAuth == .denied,
                  "denied contacts permission left toggle enabled")

        personalDataHarness.nextAccess = .authorized
        personalDataHarness.setContactsStatus(.authorized)
        personal.refreshAuthorizationStatuses()
        try check(personal.contactsAuth == .authorized, "refreshAuthorizationStatuses did not pick up System Settings grant")
        personalDataHarness.contacts = [
            ContactHit(id: "c1", fullName: "Alice Zhang", subtitle: "Acme Corp · +1-555-0100",
                       primaryPhone: "+1-555-0100", primaryEmail: "alice@example.com", organization: "Acme Corp")
        ]
        let start = Date().addingTimeInterval(3600)
        personalDataHarness.events = [
            CalendarEventHit(id: "e1", title: "Weekly Sync Alice", startDate: start,
                             endDate: start.addingTimeInterval(3600), isAllDay: false,
                             calendarTitle: "Work", location: "Zoom",
                             meetingURL: "https://meet.example.com/weekly-sync", dateSummary: "Today 15:00")
        ]
        personalDataHarness.reminders = [
            ReminderHit(id: "r1", title: "Send Alice proposal", dueDate: start, listTitle: "Tasks",
                        notes: nil, priority: 1, dueSummary: "Today 14:30", isCompleted: false)
        ]

        await personal.setContactsEnabled(true)
        await personal.setCalendarEnabled(true)
        await personal.setRemindersEnabled(true)
        try check(personal.contactsEnabled && personal.calendarEnabled && personal.remindersEnabled &&
                  personal.contactsCount == 1 && personal.eventsCount == 1 && personal.remindersCount == 1,
                  "enabling authorized personal sources did not populate counts")

        app.showSearch()
        try type("alice", into: app)
        try await until("personal data results appeared in search") {
            model.visibleResults.contains { if case .contact = $0 { return true }; return false } &&
                model.visibleResults.contains { if case .calendarEvent = $0 { return true }; return false } &&
                model.visibleResults.contains { if case .reminder = $0 { return true }; return false }
        }

        if captureAll {
            try capture("lumen-spotlight-sources-light.png", appearance: .aqua, window: app.panel)
            try capture("lumen-spotlight-sources-dark.png", appearance: .darkAqua, window: app.panel)
            print("Screenshot: lumen-spotlight-sources-light.png")
            print("Screenshot: lumen-spotlight-sources-dark.png")
            if exists("capture-spotlight") {
                try capture("spotlight-sources.png", appearance: .aqua, window: app.panel)
                print("Screenshot: spotlight-sources.png")
            }
            app.panel.appearance = nil
        }

        model.selection = "event:e1"
        let meetingBefore = dispatchedQuicklinks.count
        try key(kVK_Return, "\r", in: app)
        try await until("Return on calendar event joined meeting URL") {
            self.dispatchedQuicklinks.count == meetingBefore + 1 &&
                self.dispatchedQuicklinks.last?.absoluteString == "https://meet.example.com/weekly-sync" &&
                !app.searchPresented
        }

        app.showSearch()
        try type("alice", into: app)
        model.selection = "contact:c1"
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.map(\.id) == ["open-contact", "copy-phone", "copy-email", "copy-contact-name"],
                  "contact Cmd+K actions mismatch: \(app.contextActions.items.map(\.id))")
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try key(kVK_Return, "\r", in: app)
        try await until("contact Copy Phone action copied phone number") {
            self.filePasteboard.string(forType: .string) == "+1-555-0100" && !app.searchPresented
        }
        try verifySpotlightInternalCopy("Copy Contact Phone")

        app.showSearch()
        try type("alice", into: app)
        model.selection = "rem:r1"
        try key(kVK_Return, "\r", in: app)
        try await until("Return on reminder completed reminder via store") {
            self.personalDataHarness.completedIDs == ["r1"] && !app.searchPresented
        }

        if captureAll, !exists("settings-scenario") {
            app.showSettings()
            app.settingsSession.page = .general
            if let settingsWindow = app.settings {
                let originalFrame = settingsWindow.frame
                settingsWindow.setContentSize(NSSize(width: 780, height: 1160))
                try await Task.sleep(for: .milliseconds(120))
                try capture("lumen-settings-sources-light.png", appearance: .aqua, window: settingsWindow)
                try capture("lumen-settings-sources-dark.png", appearance: .darkAqua, window: settingsWindow)
                settingsWindow.appearance = nil
                settingsWindow.setFrame(originalFrame, display: false)
                settingsWindow.close()
                print("Screenshot: lumen-settings-sources-light.png")
                print("Screenshot: lumen-settings-sources-dark.png")
            }
        }

        personalDataHarness.reset()
        await personal.setContactsEnabled(false)
        await personal.setCalendarEnabled(false)
        await personal.setRemindersEnabled(false)
        try? fm.removeItem(at: smokeChromiumBookmarksURL)
        try? fm.removeItem(at: smokeSafariBookmarksURL)
        await model.bookmarkLibrary.syncNow(force: true)
        app.dismissSearch()
        print("v0.6.6 Spotlight-parity regressions passed (currency cache & eval, prefix-free dictionary & ranking, bookmarks, opt-in personal data)")
    }

    private struct Wave2CorpusFixtures {
        let spaceRoot: URL
        let subFolder: URL
        let spaceDoc: URL
        let nestedDoc: URL
        let clientDir: URL
        let outsideDir: URL
        let insideQuote: URL
        let outsideQuote: URL
    }

    private func makeWave2CorpusFixtures() throws -> Wave2CorpusFixtures {
        let fm = FileManager.default
        let spaceRoot = corpus.appendingPathComponent("Mobile Documents/com~apple~CloudDocs/Scope Space Dir", isDirectory: true)
        let subFolder = spaceRoot.appendingPathComponent("Sub Folder", isDirectory: true)
        let spaceDoc = spaceRoot.appendingPathComponent("space-doc.txt")
        let nestedDoc = subFolder.appendingPathComponent("nested-note.txt")
        try fm.createDirectory(at: subFolder, withIntermediateDirectories: true)
        try Data("Space directory document".utf8).write(to: spaceDoc)
        try Data("Nested directory document".utf8).write(to: nestedDoc)

        let clientDir = corpus.appendingPathComponent("P2AClientDocs", isDirectory: true)
        let outsideDir = corpus.appendingPathComponent("P2AOtherDocs", isDirectory: true)
        try fm.createDirectory(at: clientDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let insideQuote = clientDir.appendingPathComponent("客户报价单.txt")
        let outsideQuote = outsideDir.appendingPathComponent("无关报价单.txt")
        try Data("inside quote".utf8).write(to: insideQuote)
        try Data("outside quote".utf8).write(to: outsideQuote)
        return Wave2CorpusFixtures(
            spaceRoot: spaceRoot,
            subFolder: subFolder,
            spaceDoc: spaceDoc,
            nestedDoc: nestedDoc,
            clientDir: clientDir,
            outsideDir: outsideDir,
            insideQuote: insideQuote,
            outsideQuote: outsideQuote
        )
    }

    private func verifyWave2Features(_ app: AppDelegate, fixtures: Wave2CorpusFixtures) async throws {
        let model = app.model
        let fm = FileManager.default

        // MARK: - 1. P0-2 Directory Scope (paths with spaces, multi-level Tab, Backspace pop, Esc clear, Cmd+K actions)
        let spaceRoot = fixtures.spaceRoot
        let subFolder = fixtures.subFolder
        let spaceDoc = fixtures.spaceDoc
        let nestedDoc = fixtures.nestedDoc
        let spaceRootPath = IndexScope.folderPath(spaceRoot)
        let subFolderPath = IndexScope.folderPath(subFolder)
        let spaceDocPath = IndexScope.folderPath(spaceDoc)
        let nestedDocPath = IndexScope.folderPath(nestedDoc)

        app.showSearch()
        try type("Scope Space Dir", into: app)
        try await until("Scope Space Dir was indexed") {
            model.hits.contains { $0.path == spaceRootPath && $0.kind == "directory" }
        }
        model.selectedID = spaceRootPath
        try key(kVK_Tab, "\t", in: app)
        let field = try editor(app)
        try check(model.activeScopedDirectory == LauncherFileQuery.normalizedDirectoryScope(spaceRootPath) &&
                  model.scopedDirectories.count == 1 &&
                  model.activeScopeBreadcrumbs == ["Scope Space Dir"] &&
                  field.string.isEmpty &&
                  app.panel.frame.size == PanelGeometry.size(for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults),
                  "P0-2 Tab did not push Scope Space Dir into DirectoryScope cleanly")
        try await until("Scope Space Dir listed child folder and file") {
            model.hits.contains { $0.path == subFolderPath && $0.kind == "directory" } &&
                model.hits.contains { $0.path == spaceDocPath }
        }

        // Level 2 Tab drill-down.
        model.selectedID = subFolderPath
        try key(kVK_Tab, "\t", in: app)
        try check(model.scopedDirectories.count == 2 &&
                  model.activeScopeBreadcrumbs == ["Scope Space Dir", "Sub Folder"] &&
                  field.string.isEmpty,
                  "P0-2 second Tab did not drill down into Sub Folder")
        try await until("Sub Folder scoped search found nested-note.txt and excluded root files") {
            model.hits.contains { $0.path == nestedDocPath } &&
                !model.hits.contains { $0.name == "archive-one.txt" }
        }

        // Non-empty Backspace edits text without popping scope; empty Backspace pops 1 level.
        try type("n", into: app)
        try key(kVK_Delete, "\u{7f}", in: app)
        try check(field.string.isEmpty && model.scopedDirectories.count == 2,
                  "non-empty Backspace unexpectedly popped directory scope")
        try key(kVK_Delete, "\u{7f}", in: app)
        try check(model.scopedDirectories.count == 1 &&
                  model.activeScopeBreadcrumbs == ["Scope Space Dir"],
                  "empty Backspace did not pop one directory scope level")

        // Esc on empty scoped query clears directory scope without dismissing panel.
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
        try check(model.activeScopedDirectory == nil && model.scopedDirectories.isEmpty && app.searchPresented,
                  "Esc did not clear directory scope while keeping search open")

        // Cmd+K searchInFolder on regular file pushes parent directory scope.
        try type("nested-note", into: app)
        try await until("nested-note.txt indexed for searchInFolder") {
            model.hits.contains { $0.path == nestedDocPath }
        }
        model.selectedID = nestedDocPath
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        guard let searchInFolderIdx = app.contextActions.items.firstIndex(where: { $0.id == "search-in-folder" }) else {
            throw Failure("missing search-in-folder Cmd+K action for regular file")
        }
        app.contextActions.run(searchInFolderIdx)
        try check(model.activeScopedDirectory == LauncherFileQuery.normalizedDirectoryScope(subFolderPath) &&
                  field.string.isEmpty && app.searchPresented,
                  "searchInFolder did not push parent folder scope")
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)

        // Cmd+K copyFile writes .fileURL + internalType, and rejects SF_DATALESS/placeholder without materializing.
        try type("space-doc", into: app)
        try await until("space-doc.txt ready for Cmd+K file tools") {
            model.hits.contains { $0.path == spaceDocPath }
        }
        model.selectedID = spaceDocPath
        let priorClipboardCount = app.clipboard.items.count
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        guard let copyFileIdx = app.contextActions.items.firstIndex(where: { $0.id == "copy-file" }) else {
            throw Failure("missing copy-file Cmd+K action")
        }
        app.contextActions.run(copyFileIdx)
        try await until("copyFile wrote fileURL with internal marker") {
            self.filePasteboard.types?.contains(.fileURL) == true &&
                self.filePasteboard.types?.contains(ClipboardManager.internalType) == true &&
                model.searchNotice?.problem == .copiedFile
        }
        let copiedURLs = filePasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try check(copiedURLs?.first?.standardizedFileURL.path == spaceDoc.standardizedFileURL.path,
                  "copyFile wrote wrong fileURL: \(String(describing: copiedURLs))")
        app.clipboard.poll()
        try check(app.clipboard.items.count == priorClipboardCount, "copyFile leaked internal copy into clipboard history")

        try check(LauncherFileTools.isResidentForFileCopy(spaceDoc) &&
                  !LauncherFileTools.isResidentForFileCopy(directory.appendingPathComponent("missing-file.txt")) &&
                  !LauncherFileTools.isResidentForFileCopy(URL(string: "https://example.com")!),
                  "LauncherFileTools.isResidentForFileCopy failed resident/missing/non-file checks")

        filePasteboard.clearContents()
        let placeholderHit = SearchHit(path: spaceDocPath, name: "space-doc.txt", kind: "file",
                                       availability: "placeholder", matched_by: "name",
                                       snippet: nil, document_stamp: nil, pdf_page: nil)
        app.perform(.copyFile, on: placeholderHit)
        try check(model.searchNotice?.problem == .cloudCopyBlocked &&
                  filePasteboard.types?.isEmpty != false,
                  "copyFile did not block cloud placeholder without writing pasteboard")
        simulatedDatalessPaths.insert(spaceDocPath)
        defer { simulatedDatalessPaths.remove(spaceDocPath) }
        // Clear the prior .cloudCopyBlocked notice so `until` waits for async `resolve` (`actionValidating = false`) before openInTerminal runs.
        app.perform(.copyName, on: model.selectedHit!)
        try check(model.searchNotice?.problem == .copiedName, "copyName failed to reset searchNotice before simulated SF_DATALESS check")
        filePasteboard.clearContents()
        app.perform(.copyFile, on: model.selectedHit!)
        try await until("copyFile blocked simulated SF_DATALESS file without writing pasteboard") {
            model.searchNotice?.problem == .cloudCopyBlocked &&
                self.filePasteboard.types?.isEmpty != false
        }
        simulatedDatalessPaths.remove(spaceDocPath)

        // openInTerminal directory resolution for regular file vs directory.
        try check(LauncherFileTools.targetDirectoryForTerminal(path: spaceDocPath, isDirectory: false).standardizedFileURL.path
                  == spaceRoot.standardizedFileURL.path &&
                  LauncherFileTools.targetDirectoryForTerminal(path: spaceRootPath, isDirectory: true).standardizedFileURL.path
                  == spaceRoot.standardizedFileURL.path,
                  "targetDirectoryForTerminal resolved wrong directory")
        let fakeTerminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        preferredTerminalOverride = fakeTerminalURL
        defer { preferredTerminalOverride = nil }
        openedInTerminal.removeAll()
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        guard let termIdx = app.contextActions.items.firstIndex(where: { $0.id == "open-in-terminal" }) else {
            throw Failure("missing open-in-terminal Cmd+K action")
        }
        app.contextActions.run(termIdx)
        try await until("openInTerminal resolved parent directory for regular file") {
            self.openedInTerminal.count == 1 && !app.searchPresented
        }
        try check(openedInTerminal[0].directory.standardizedFileURL.path == spaceRoot.standardizedFileURL.path,
                  "openInTerminal did not target parent directory for file")

        // openWith lazy discovery: NOT called on Cmd+K menu open, called ONLY when "open-with" is selected.
        var openWithDiscoveryCalls = 0
        let mockApp1 = LauncherFileTools.OpenWithApp(
            name: "StubEdit",
            url: URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true),
            bundleID: "com.apple.TextEdit"
        )
        openWithAppsOverride = { _ in
            openWithDiscoveryCalls += 1
            return [mockApp1]
        }
        defer { openWithAppsOverride = nil }
        app.showSearch()
        try type("space-doc", into: app)
        try await until("space-doc reloaded for openWith test") {
            model.hits.contains { $0.path == spaceDocPath }
        }
        model.selectedID = spaceDocPath
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(openWithDiscoveryCalls == 0, "openWithApplications ran eagerly during Cmd+K menu build")
        guard let openWithIdx = app.contextActions.items.firstIndex(where: { $0.id == "open-with" }) else {
            throw Failure("missing open-with Cmd+K action")
        }
        app.contextActions.run(openWithIdx)
        try check(openWithDiscoveryCalls == 1 &&
                  app.contextActions.isOpen &&
                  app.contextActions.items.map(\.id) == ["open-with-back", "open-with-app:com.apple.TextEdit"],
                  "openWith secondary menu or lazy discovery failed: \(app.contextActions.items.map(\.id))")
        app.contextActions.run(0) // "← Back" restores main Cmd+K menu without re-querying openWith.
        try check(openWithDiscoveryCalls == 1 &&
                  app.contextActions.isOpen &&
                  app.contextActions.items.contains { $0.id == "open-with" },
                  "openWith back button did not restore main Cmd+K menu")
        let nextOpenWithIdx = app.contextActions.items.firstIndex(where: { $0.id == "open-with" })!
        app.contextActions.run(nextOpenWithIdx)
        openedWith.removeAll()
        app.contextActions.run(1)
        try await until("openWith dispatched selected application with target file") {
            self.openedWith.count == 1 && !app.searchPresented
        }
        try check(openedWith[0].file.standardizedFileURL.path == spaceDoc.standardizedFileURL.path &&
                  openedWith[0].application == mockApp1.url,
                  "openWith dispatched wrong file or application")
        try check(!LauncherFileTools.openWithApplications(for: spaceDoc).isEmpty,
                  "real LaunchServices openWithApplications returned empty for .txt")

        // MARK: - 2. P2-A Folder Alias Search ("kh 报价" scoping + "kh" + Tab DirectoryScope)
        let clientDir = fixtures.clientDir
        let insideQuote = fixtures.insideQuote
        let outsideQuote = fixtures.outsideQuote
        let clientDirPath = IndexScope.folderPath(clientDir)
        let insideQuotePath = IndexScope.folderPath(insideQuote)
        let outsideQuotePath = IndexScope.folderPath(outsideQuote)

        app.showSearch()
        try type("无关报价单", into: app)
        try await until("P2-A files indexed") {
            model.hits.contains { $0.path == outsideQuotePath }
        }
        let khShortcut = SavedShortcut(id: UUID(), title: "客户资料", alias: "kh", target: .folder(clientDirPath), pinned: false)
        try check(model.shortcuts.save(khShortcut), "could not save kh folder shortcut")
        defer { model.shortcuts.remove(khShortcut) }

        try type("kh 报价", into: app)
        try await until("kh 报价 scoped search matched only inside kh folder") {
            model.activeAliasFolder?.id == khShortcut.id &&
                model.hits.contains { $0.path == insideQuotePath } &&
                !model.searching
        }
        try check(!model.hits.contains { $0.path == outsideQuotePath },
                  "kh alias search leaked files outside the aliased folder")

        try type("kh", into: app)
        try key(kVK_Tab, "\t", in: app)
        try check(model.activeScopedDirectory == LauncherFileQuery.normalizedDirectoryScope(clientDirPath) &&
                  (try editor(app)).string.isEmpty,
                  "kh + Tab did not enter DirectoryScope for kh folder")
        model.clearDirectoryScope()
        model.shortcuts.remove(khShortcut)

        // MARK: - 3. P0-1 Open/Save Quick Switch (Unit + AppDelegate integration)
        let isoBridge = makeFileDialogBridge()
        let testPID = NSRunningApplication.current.processIdentifier
        fileDialogAXAdapter.reset()
        defer {
            fileDialogAXAdapter.reset()
            simulatedFrontmostApp = nil
        }

        // Untrusted degradation.
        try check(isoBridge.detectActiveDialog(frontmostApp: NSRunningApplication.current) == nil &&
                  isoBridge.openFinderFolders().isEmpty,
                  "FileDialogBridge did not return nil/empty when AX untrusted")
        var untrustedNavResult: Bool?
        isoBridge.navigate(FileDialogContext(appPID: testPID, appName: "TestApp", appBundleID: "com.test.app", kind: .save),
                           toPath: spaceDocPath, isDirectory: false) { untrustedNavResult = $0 }
        try check(untrustedNavResult == false, "navigate succeeded while AX untrusted")

        // Static Open vs Save target path resolution.
        try check(FileDialogBridge.resolvedTargetPath(for: "/Users/test/a.txt", isDirectory: false, in: .open) == "/Users/test/a.txt" &&
                  FileDialogBridge.resolvedTargetPath(for: "/Users/test/a.txt", isDirectory: false, in: .save) == "/Users/test" &&
                  FileDialogBridge.resolvedTargetPath(for: "/Users/test/Dir", isDirectory: true, in: .save) == "/Users/test/Dir",
                  "FileDialogBridge.resolvedTargetPath failed open vs save filename preservation")

        // Configure trusted Save dialog + Finder windows + Go-to-Folder popover simulation.
        fileDialogAXAdapter.setTrusted(true)
        let saveSheet = FileDialogAXElement.mock("save-sheet")
        let hostWin = FileDialogAXElement.mock("host-win")
        let browserEl = FileDialogAXElement.mock("save-browser")
        let saveAsField = FileDialogAXElement.mock("save-as-field")
        let saveBtn = FileDialogAXElement.mock("save-btn")
        let gotoPopover = FileDialogAXElement.mock("goto-popover")
        let gotoField = FileDialogAXElement.mock("goto-field")

        fileDialogAXAdapter.configureNode(hostWin, role: kAXWindowRole as String, children: [], sheets: [saveSheet])
        fileDialogAXAdapter.configureNode(saveSheet, role: kAXSheetRole as String, identifier: "save-panel",
                                          children: [browserEl, saveAsField, saveBtn], defaultButton: saveBtn)
        fileDialogAXAdapter.configureNode(browserEl, role: kAXBrowserRole as String)
        fileDialogAXAdapter.configureNode(saveAsField, role: kAXTextFieldRole as String, identifier: "saveAsNameTextField",
                                          value: "Untitled.txt", enabled: true, parent: saveSheet)
        fileDialogAXAdapter.configureNode(saveBtn, role: kAXButtonRole as String, title: "Save")
        fileDialogAXAdapter.configureNode(gotoPopover, role: kAXPopoverRole as String, parent: saveSheet, children: [gotoField])
        fileDialogAXAdapter.configureNode(gotoField, role: kAXTextFieldRole as String, identifier: "GoToWindowTextField",
                                          placeholder: "Go to folder", value: "", enabled: true, parent: gotoPopover)
        fileDialogAXAdapter.configureApp(pid: testPID, bundleID: "com.test.editor", focusedWindow: hostWin, focusedElement: saveAsField)

        // Finder windows (1 valid resident folder + 1 duplicate + 1 nonexistent folder).
        let spaceRootFinderURL = URL(fileURLWithPath: spaceRootPath, isDirectory: true)
        let finderWin1 = FileDialogAXElement.mock("finder-win-1")
        let finderWin2 = FileDialogAXElement.mock("finder-win-2")
        let finderWinBad = FileDialogAXElement.mock("finder-win-bad")
        fileDialogAXAdapter.configureNode(finderWin1, role: kAXWindowRole as String, url: spaceRootFinderURL)
        fileDialogAXAdapter.configureNode(finderWin2, role: kAXWindowRole as String, url: spaceRootFinderURL)
        fileDialogAXAdapter.configureNode(finderWinBad, role: kAXWindowRole as String,
                                          url: directory.appendingPathComponent("MissingFinderDir", isDirectory: true))
        fileDialogAXAdapter.configureFinder(pid: 99_001, windows: [finderWin1, finderWin2, finderWinBad])

        let detectedSave = isoBridge.detectActiveDialog(frontmostApp: NSRunningApplication.current)
        try check(detectedSave?.kind == .save && detectedSave?.appPID == testPID,
                  "detectActiveDialog failed to classify Save sheet: \(String(describing: detectedSave))")
        let listedFolders = isoBridge.openFinderFolders()
        try check(listedFolders.map(\.path) == [spaceRootPath],
                  "openFinderFolders did not deduplicate/filter local folders: \(listedFolders)")

        // Test Go-to-Folder AX write without clipboard mutation + Save-As field protection.
        filePasteboard.clearContents()
        filePasteboard.setString("preserve-my-clipboard", forType: .string)
        fileDialogAXAdapter.onShortcut = { [weak fileDialogAXAdapter] keyCode, flags in
            guard let adapter = fileDialogAXAdapter else { return }
            if keyCode == CGKeyCode(kVK_ANSI_G) && flags == [.maskCommand, .maskShift] {
                adapter.setSystemFocused(gotoField)
            }
        }
        var navSuccess: Bool?
        isoBridge.navigate(detectedSave!, toPath: spaceDocPath, isDirectory: false) { navSuccess = $0 }
        try await until("FileDialogBridge navigate did not complete") { navSuccess != nil }
        try check(navSuccess == true &&
                  fileDialogAXAdapter.lastWrittenValue(for: gotoField) == spaceRootPath &&
                  fileDialogAXAdapter.lastWrittenValue(for: saveAsField) == nil &&
                  filePasteboard.string(forType: .string) == "preserve-my-clipboard",
                  "FileDialogBridge navigate mutated Save-As field or clipboard or failed path write")

        // Timeout degradation when Go-to-Folder never opens (focus stays on Save-As field).
        fileDialogAXAdapter.onShortcut = nil
        fileDialogAXAdapter.setSystemFocused(saveAsField)
        var timedOutSuccess: Bool?
        isoBridge.navigate(detectedSave!, toPath: spaceRootPath, isDirectory: true) { timedOutSuccess = $0 }
        try await until("FileDialogBridge navigate timeout did not settle") { timedOutSuccess != nil }
        try check(timedOutSuccess == false &&
                  fileDialogAXAdapter.lastWrittenValue(for: saveAsField) == nil &&
                  filePasteboard.string(forType: .string) == "preserve-my-clipboard",
                  "FileDialogBridge timeout wrote Save-As field or failed to return false")

        // Fix 1 regressions: XPC openAndSavePanelService preserves servicePID/dialogElement,
        // waits for focus after .nonactivatingPanel dismissal, and hard-aborts (0 shortcuts!)
        // if focus stays on host document editor.
        let hostPID: pid_t = 77_001
        let servicePID: pid_t = 88_100
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hostDocWindow = FileDialogAXElement.mock("host-doc-window")
        let hostDocEditor = FileDialogAXElement.mock("host-doc-editor")
        let remoteSheet = FileDialogAXElement.mock("remote-open-sheet")
        let remoteBrowser = FileDialogAXElement.mock("remote-open-browser")
        let remoteOpenBtn = FileDialogAXElement.mock("remote-open-btn")
        let remoteFocused = FileDialogAXElement.mock("remote-focused-list")
        let remoteGotoField = FileDialogAXElement.mock("remote-goto-field")
        let remoteGotoPopover = FileDialogAXElement.mock("remote-goto-popover")
        let lumenOwnField = FileDialogAXElement.mock("lumen-own-field")

        fileDialogAXAdapter.configureNode(hostDocWindow, role: kAXWindowRole as String, children: [hostDocEditor])
        fileDialogAXAdapter.configureNode(hostDocEditor, role: kAXTextAreaRole as String, parent: hostDocWindow, window: hostDocWindow)
        fileDialogAXAdapter.configureNode(remoteSheet, role: kAXSheetRole as String, identifier: "open-panel",
                                          children: [remoteBrowser, remoteOpenBtn], defaultButton: remoteOpenBtn)
        fileDialogAXAdapter.configureNode(remoteBrowser, role: kAXBrowserRole as String)
        fileDialogAXAdapter.configureNode(remoteOpenBtn, role: kAXButtonRole as String, title: "Open")
        fileDialogAXAdapter.configureNode(remoteFocused, role: kAXOutlineRole as String, parent: remoteSheet,
                                          window: remoteSheet, topLevel: remoteSheet)
        fileDialogAXAdapter.configureNode(remoteGotoPopover, role: kAXPopoverRole as String, parent: remoteSheet, children: [remoteGotoField])
        fileDialogAXAdapter.configureNode(remoteGotoField, role: kAXTextFieldRole as String, identifier: "GoToWindowTextField",
                                          placeholder: "Go to folder", value: "", enabled: true, parent: remoteGotoPopover)
        fileDialogAXAdapter.configureNode(lumenOwnField, role: kAXTextFieldRole as String)
        fileDialogAXAdapter.setElementPID(lumenOwnField, pid: ownPID)
        fileDialogAXAdapter.configureService(pid: servicePID, windows: [remoteSheet])
        fileDialogAXAdapter.setElementPID(remoteSheet, pid: servicePID)
        fileDialogAXAdapter.setElementPID(remoteFocused, pid: servicePID)
        fileDialogAXAdapter.setElementPID(remoteGotoField, pid: servicePID)
        fileDialogAXAdapter.configureApp(pid: hostPID, bundleID: "com.apple.TextEdit",
                                         focusedWindow: hostDocWindow, focusedElement: remoteFocused)
        fileDialogAXAdapter.setElementPID(hostDocWindow, pid: hostPID)
        fileDialogAXAdapter.setElementPID(hostDocEditor, pid: hostPID)
        fileDialogAXAdapter.setActive(true, pid: hostPID)

        // Ensure detectActiveDialog captures servicePID & dialogElement from XPC service element.
        let hostProxyApp = NSRunningApplication.current
        _ = hostProxyApp // real frontmostApp is only needed for pid; bridge also accepts context directly.
        fileDialogAXAdapter.setSystemFocused(remoteFocused)
        // Also test detectActiveDialog on current PID with XPC focused element -> preserves servicePID & dialogElement.
        fileDialogAXAdapter.configureApp(pid: testPID, bundleID: "com.apple.TextEdit",
                                         focusedWindow: hostDocWindow, focusedElement: remoteFocused)
        fileDialogAXAdapter.setElementPID(remoteFocused, pid: servicePID)
        let detectedRemote = isoBridge.detectActiveDialog(frontmostApp: NSRunningApplication.current)
        try check(detectedRemote?.kind == .open &&
                  detectedRemote?.servicePID == servicePID &&
                  detectedRemote?.dialogElement == remoteSheet,
                  "detectActiveDialog did not preserve servicePID/dialogElement for remote XPC dialog: \(String(describing: detectedRemote))")

        // Use non-own hostPID context so Lumen ownPID vs host editor focus guards run identically to production.
        let remoteHostContext = FileDialogContext(
            appPID: hostPID,
            appName: "TextEdit",
            appBundleID: "com.apple.TextEdit",
            kind: .open,
            servicePID: servicePID,
            dialogElement: remoteSheet
        )

        // Hard-abort when focus stays on host document editor (must post ZERO shortcuts!).
        fileDialogAXAdapter.clearWritesAndShortcuts()
        fileDialogAXAdapter.onShortcut = nil
        fileDialogAXAdapter.onPerformAction = nil
        fileDialogAXAdapter.setSystemFocused(hostDocEditor)
        var hardAbortResult: Bool?
        isoBridge.navigate(remoteHostContext, toPath: spaceRootPath, isDirectory: true) { hardAbortResult = $0 }
        try await until("FileDialogBridge hard-abort did not complete") { hardAbortResult != nil }
        try check(hardAbortResult == false &&
                  fileDialogAXAdapter.recordedShortcuts().isEmpty &&
                  fileDialogAXAdapter.lastWrittenValue(for: remoteGotoField) == nil &&
                  fileDialogAXAdapter.recordedPerformedActions().contains { $0.0 == (kAXRaiseAction as String) && $0.1 == remoteSheet },
                  "FileDialogBridge posted shortcuts or skipped AXRaise when focus stayed on host editor: shortcuts=\(fileDialogAXAdapter.recordedShortcuts())")

        // Focus starts on Lumen .nonactivatingPanel (ownPID); AXRaise restores dialog focus and navigation succeeds.
        fileDialogAXAdapter.clearWritesAndShortcuts()
        fileDialogAXAdapter.setSystemFocused(lumenOwnField)
        fileDialogAXAdapter.onPerformAction = { [weak fileDialogAXAdapter] action, element in
            if action == (kAXRaiseAction as String) && element == remoteSheet {
                fileDialogAXAdapter?.setSystemFocused(remoteFocused)
            }
        }
        fileDialogAXAdapter.onShortcut = { [weak fileDialogAXAdapter] keyCode, flags in
            if keyCode == CGKeyCode(kVK_ANSI_G) && flags == [.maskCommand, .maskShift] {
                fileDialogAXAdapter?.setSystemFocused(remoteGotoField)
            }
        }
        var delayedFocusResult: Bool?
        isoBridge.navigate(remoteHostContext, toPath: spaceRootPath, isDirectory: true) { delayedFocusResult = $0 }
        try await until("FileDialogBridge delayed dialog focus navigate did not complete") { delayedFocusResult != nil }
        try check(delayedFocusResult == true &&
                  fileDialogAXAdapter.lastWrittenValue(for: remoteGotoField) == spaceRootPath &&
                  fileDialogAXAdapter.recordedShortcuts().filter { $0.0 == CGKeyCode(kVK_ANSI_G) }.count == 1,
                  "FileDialogBridge failed to wait for dialog focus or write path after AXRaise: result=\(String(describing: delayedFocusResult))")
        fileDialogAXAdapter.onPerformAction = nil

        // End-to-end AppDelegate integration for P0-1.
        fileDialogAXAdapter.configureApp(pid: testPID, bundleID: "com.test.editor",
                                         focusedWindow: hostWin, focusedElement: saveAsField)
        fileDialogAXAdapter.clearWritesAndShortcuts()
        fileDialogAXAdapter.setSystemFocused(saveAsField)
        fileDialogAXAdapter.onShortcut = { [weak fileDialogAXAdapter] keyCode, flags in
            if keyCode == CGKeyCode(kVK_ANSI_G) && flags == [.maskCommand, .maskShift] {
                fileDialogAXAdapter?.setSystemFocused(gotoField)
            }
        }
        simulatedFrontmostApp = NSRunningApplication.current
        app.dismissSearch()
        app.showSearch()
        try check(model.activeFileDialog?.kind == .save &&
                  model.openFinderFolders.map(\.path) == [spaceRootPath] &&
                  model.visibleResults.first == .finderFolder(OpenFinderFolder(path: spaceRootPath, name: "Scope Space Dir")) &&
                  app.panel.frame.size == PanelGeometry.size(
                      for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults, hasFileDialogBanner: true
                  ),
                  "AppDelegate showSearch did not present Quick Switch banner + Finder folder row")
        app.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let fileDialogLight = try render(.aqua, window: app.panel)
        app.panel.appearance = nil
        let fdSize = app.panel.frame.size
        let fdYRange = PanelGeometry.headerHeight..<(PanelGeometry.headerHeight + FileDialogBanner.launcherHeight)
        try check(!hasBannerInk(in: fileDialogLight, panelSize: fdSize,
                                xPoints: (fdSize.width - 92)..<(fdSize.width - 34),
                                yPoints: fdYRange) &&
                  app.panel.onDismissContext?() == false,
                  "FileDialogBanner unexpectedly rendered ⌘⇧⌫ hint or handled onDismissContext")

        // Cmd+Return preserves normal Reveal without dialog navigation.
        try type("space-doc", into: app)
        try await until("space-doc loaded under activeFileDialog") {
            model.hits.contains { $0.path == spaceDocPath }
        }
        model.selectedID = spaceDocPath
        revealed = nil
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("Cmd+Return preserved normal Reveal during Quick Switch") {
            self.revealed?.path == spaceDocPath && !app.searchPresented && model.activeFileDialog == nil
        }
        try check(fileDialogAXAdapter.lastWrittenValue(for: gotoField) == nil,
                  "Cmd+Return unexpectedly triggered dialog navigation")

        // Plain Return on .finderFolder navigates active dialog & clears activeFileDialog.
        app.showSearch()
        try check(model.activeFileDialog?.kind == .save && model.selectedResult == .finderFolder(OpenFinderFolder(path: spaceRootPath, name: "Scope Space Dir")),
                  "reopened Quick Switch did not auto-select Finder folder")
        try key(kVK_Return, "\r", in: app)
        try await until("Return on .finderFolder navigated dialog via FileDialogBridge") {
            !app.searchPresented &&
                model.activeFileDialog == nil &&
                self.fileDialogAXAdapter.lastWrittenValue(for: gotoField) == spaceRootPath
        }

        // Open dialog + banner dismissal.
        let openWindow = FileDialogAXElement.mock("open-win")
        let openField = FileDialogAXElement.mock("open-list")
        fileDialogAXAdapter.configureNode(openWindow, role: kAXWindowRole as String, subrole: kAXDialogSubrole as String,
                                          identifier: "open-panel", children: [openField])
        fileDialogAXAdapter.configureNode(openField, role: kAXOutlineRole as String)
        fileDialogAXAdapter.configureApp(pid: testPID, bundleID: "com.apple.Preview", focusedWindow: openWindow, focusedElement: openField)
        app.showSearch()
        try check(model.activeFileDialog?.kind == .open, "AppDelegate did not detect Open dialog")
        model.clearFileDialogContext()
        try check(model.activeFileDialog == nil && model.openFinderFolders.isEmpty,
                  "clearFileDialogContext did not clear Quick Switch state")
        app.dismissSearch()
        fileDialogAXAdapter.reset()
        simulatedFrontmostApp = nil

        // MARK: - 4. P1-A Selection & Clipboard Context Pass-Through
        let contextPB = contextPasteboard
        contextPB.clearContents()
        let isoContextBridge = makeSelectionContextBridge()
        selectionAXAdapter.reset()
        defer {
            selectionAXAdapter.reset()
            contextPB.clearContents()
            contextCaptureEnabled = false
            simulatedFrontmostApp = nil
        }

        // Priority & privacy boundaries.
        selectionAXAdapter.trusted = true
        contextPB.setString("clipboard fallback text", forType: .string)
        selectionAXAdapter.focusedByPID[testPID] = SelectionAXElementState(
            role: "AXTextArea", subrole: nil, selectedText: "selected editor text",
            isSelectedTextSettable: true, isEditable: true
        )
        selectionAXAdapter.selectedFileURLsByPID[testPID] = [spaceDoc]
        let ctx1 = isoContextBridge.capture(pid: testPID, bundleIdentifier: "com.apple.finder", appName: "Finder", pasteboard: contextPB)
        try check(ctx1 == .selectedText(text: "selected editor text", appName: "Finder", canReplace: true),
                  "AXSelectedText did not win priority over Finder files and clipboard: \(String(describing: ctx1))")

        // AXSecureTextField hard-abort without clipboard fallback (role and subrole).
        selectionAXAdapter.focusedByPID[testPID] = SelectionAXElementState(
            role: "AXSecureTextField", subrole: nil, selectedText: "secret", isSelectedTextSettable: true, isEditable: true
        )
        try check(isoContextBridge.capture(pid: testPID, bundleIdentifier: "com.apple.Safari", appName: "Safari", pasteboard: contextPB) == nil,
                  "AXSecureTextField role did not hard-abort without clipboard fallback")
        selectionAXAdapter.focusedByPID[testPID] = SelectionAXElementState(
            role: "AXTextField", subrole: "AXSecureTextField", selectedText: "secret", isSelectedTextSettable: true, isEditable: true
        )
        try check(isoContextBridge.capture(pid: testPID, bundleIdentifier: "com.apple.Safari", appName: "Safari", pasteboard: contextPB) == nil,
                  "AXSecureTextField subrole did not hard-abort without clipboard fallback")

        // Finder files beat clipboard fallback.
        selectionAXAdapter.focusedByPID[testPID] = SelectionAXElementState(
            role: "AXOutline", subrole: nil, selectedText: nil, isSelectedTextSettable: false, isEditable: false
        )
        let ctxFiles = isoContextBridge.capture(pid: testPID, bundleIdentifier: "com.apple.finder", appName: "Finder", pasteboard: contextPB)
        try check(ctxFiles == .selectedFiles(paths: [spaceDoc.standardizedFileURL.path], appName: "Finder"),
                  "Finder selected files did not beat clipboard fallback: \(String(describing: ctxFiles))")

        // Concealed / transient pasteboard rejection.
        selectionAXAdapter.focusedByPID.removeValue(forKey: testPID)
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            let pbItem = NSPasteboardItem()
            pbItem.setString("sensitive", forType: .string)
            pbItem.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            contextPB.clearContents()
            contextPB.writeObjects([pbItem])
            try check(isoContextBridge.capture(pid: testPID, bundleIdentifier: "com.test.app", appName: "App", pasteboard: contextPB) == nil,
                      "SelectionContextBridge captured sensitive pasteboard type \(marker)")
        }

        // Non-sensitive clipboard fallback succeeds.
        contextPB.clearContents()
        contextPB.setString("plain clipboard text", forType: .string)
        try check(isoContextBridge.capture(pid: testPID, bundleIdentifier: "com.test.app", appName: "App", pasteboard: contextPB)
                  == .clipboardText(text: "plain clipboard text"),
                  "SelectionContextBridge did not fall back to plain clipboard text")

        // End-to-end AppDelegate integration for P1-A (tr + Cmd+Return replace, qa, web quicklink, script, × dismissal).
        let loopbackHTTP = try SmokeLoopbackHTTPServer(replyText: "你好世界")
        defer { loopbackHTTP.stop() }
        app.translation.newProvider()
        app.translation.editDraft(\.name, value: "Loopback Context Probe")
        app.translation.editDraft(\.endpoint, value: "http://127.0.0.1:\(loopbackHTTP.port)/v1")
        app.translation.editDraft(\.model, value: "context-model")
        app.translation.saveProvider()
        defer {
            while app.translation.canRemoveProvider { app.translation.removeProvider() }
        }

        let ctxScriptDir = directory.appendingPathComponent("P1AContextScripts", isDirectory: true)
        try fm.createDirectory(at: ctxScriptDir, withIntermediateDirectories: true)
        let ctxScript = ctxScriptDir.appendingPathComponent("ctx-probe")
        try Data("#!/bin/sh\n# @lumen.title Context Arg Probe\n# @lumen.argument1 Prompt arg\nprintf '%s' \"$1\"\n".utf8).write(to: ctxScript)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ctxScript.path)
        app.scriptCatalog.selectFolder(ctxScriptDir)
        app.scriptCatalog.setScriptsEnabled(true)
        defer { app.scriptCatalog.setScriptsEnabled(false) }
        try await until("P1-A context script loaded") {
            !app.scriptCatalog.scriptLoading && app.scriptCatalog.scripts.contains { $0.title == "Context Arg Probe" }
        }

        selectionAXAdapter.focusedByPID[testPID] = SelectionAXElementState(
            role: "AXTextArea", subrole: nil, selectedText: "hello world",
            isSelectedTextSettable: true, isEditable: true
        )
        contextCaptureEnabled = true
        simulatedFrontmostApp = NSRunningApplication.current
        app.showSearch()
        try check(model.activeContext == .selectedText(text: "hello world", appName: NSRunningApplication.current.localizedName, canReplace: true) &&
                  app.panel.frame.size == PanelGeometry.size(
                      for: app.panelState, rows: model.visibleResults, showsResults: model.showsResults, hasContextBanner: true
                  ),
                  "showSearch did not capture AXSelectedText context or update panel geometry")

        // qa empty + non-empty instruction pass-through.
        try type("qa ", into: app)
        try check(app.commands.resolution == .question("hello world"),
                  "qa with empty instruction did not use activeContext: \(app.commands.resolution)")
        try type("qa summarize", into: app)
        try check(app.commands.resolution == .question("summarize\n\n\"\"\"\nhello world\n\"\"\""),
                  "qa with instruction did not wrap activeContext: \(app.commands.resolution)")

        // Web quicklink pass-through ("g ").
        try type("g ", into: app)
        guard case .web("google", _, let webURL) = app.commands.resolution,
              URLComponents(url: webURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "q", value: "hello world")) == true else {
            throw Failure("g with empty argument did not resolve web URL from activeContext: \(app.commands.resolution)")
        }

        // Script with @lumen.argument1 prefills executionArgument without auto-running.
        try type("Context Arg Probe", into: app)
        try key(kVK_Return, "\r", in: app)
        if case .argument("Prompt arg", required: false)? = app.commands.visibleExecution?.phase {
            try check(app.commands.executionArgument == "hello world",
                      "executable prompt did not prefill activeContext: \(app.commands.executionArgument)")
        } else {
            throw Failure("Return on Context Arg Probe bypassed interactive argument prompt")
        }
        try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)

        // tr + loopback translation + Cmd+Return replace-in-place.
        try type("tr", into: app)
        try check(app.translation.command?.text == "hello world" && app.translation.command?.target == .simplifiedChinese,
                  "bare tr did not populate from activeContext: \(String(describing: app.translation.command))")
        try key(kVK_Return, "\r", in: app)
        try await until("loopback tr did not finish") {
            app.translation.output == "你好世界" && app.translation.activity == nil
        }
        let pasteCountBeforeReplace = pasteIntoPreviousAppCount
        filePasteboard.clearContents()
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        try await until("Cmd+Return replace-in-place did not copy, dismiss, and paste") {
            !app.searchPresented &&
                self.filePasteboard.string(forType: .string) == "你好世界" &&
                self.filePasteboard.types?.contains(ClipboardManager.internalType) == true &&
                self.pasteIntoPreviousAppCount == pasteCountBeforeReplace + 1
        }

        // Re-open and test context dismissal:
        // 1. SelectionContextBanner renders ⌘⇧⌫ hint alongside close button.
        // 2. Cmd+Shift+Delete & Cmd+Shift+ForwardDelete clear activeContext while preserving "qa 总结" in searchField.
        // 3. Submitted QA request excludes the dismissed context.
        // 4. Cmd+Shift+Delete when activeContext == nil returns false.
        app.showSearch()
        app.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let bannerLight = try render(.aqua, window: app.panel)
        _ = try render(.darkAqua, window: app.panel)
        if exists("capture-icons") || exists("capture-snapshots") {
            if let png = bannerLight.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("lumen-context-banner-light.png"))
            }
        }
        app.panel.appearance = nil
        // Verify SelectionContextBanner draws the ⌘⇧⌫ keycap hint immediately left of the close button (30pt banner below 56pt header).
        let panelSize = app.panel.frame.size
        let bannerYRange = PanelGeometry.headerHeight..<(PanelGeometry.headerHeight + SelectionContextBanner.launcherHeight)
        try check(hasBannerInk(in: bannerLight, panelSize: panelSize,
                               xPoints: (panelSize.width - 92)..<(panelSize.width - 34),
                               yPoints: bannerYRange) &&
                  hasBannerInk(in: bannerLight, panelSize: panelSize,
                               xPoints: (panelSize.width - 32)..<(panelSize.width - 10),
                               yPoints: bannerYRange),
                  "SelectionContextBanner did not render ⌘⇧⌫ keycap hint beside close button")

        try type("qa 总结", into: app)
        try check(app.commands.resolution == .question("总结\n\n\"\"\"\nhello world\n\"\"\""),
                  "qa 总结 did not wrap activeContext before Cmd+Shift+Delete: \(app.commands.resolution)")
        try key(kVK_Delete, "\u{7f}", in: app, throughPanel: true, flags: [.command, .shift])
        try check(model.activeContext == nil &&
                  app.searchField.stringValue == "qa 总结" &&
                  (try editor(app)).string == "qa 总结" &&
                  app.commands.resolution == .question("总结"),
                  "Cmd+Shift+Delete did not clear activeContext while keeping searchField text intact: ctx=\(String(describing: model.activeContext)), text=\(app.searchField.stringValue), res=\(app.commands.resolution)")

        let cmdShiftDeleteAgain = try event(kVK_Delete, "\u{7f}", in: app, flags: [.command, .shift])
        try check(app.panel.onDismissContext?() == false && !app.panel.performKeyEquivalent(with: cmdShiftDeleteAgain),
                  "Cmd+Shift+Delete did not return false when activeContext == nil")

        // Submit QA now and verify the HTTP payload sent to the provider excludes the dismissed "hello world" context.
        let messagesBeforeQA = loopbackHTTP.recordedUserMessages().count
        try key(kVK_Return, "\r", in: app)
        try await until("QA after Cmd+Shift+Delete did not finish") {
            app.commands.answer == .answer("你好世界")
        }
        try check(Array(loopbackHTTP.recordedUserMessages().dropFirst(messagesBeforeQA)) == ["总结"],
                  "submitted QA prompt leaked dismissed context: \(loopbackHTTP.recordedUserMessages())")

        // Also test ForwardDelete (Fn+Cmd+Shift+Delete) dismissal preserving typed text.
        app.dismissSearch()
        app.showSearch()
        try type("qa 总结", into: app)
        try check(model.activeContext != nil, "reopened search did not capture context for ForwardDelete check")
        try key(kVK_ForwardDelete, "\u{f728}", in: app, throughPanel: true, flags: [.command, .shift])
        try check(model.activeContext == nil &&
                  app.searchField.stringValue == "qa 总结" &&
                  app.commands.resolution == .question("总结"),
                  "Cmd+Shift+ForwardDelete did not clear activeContext cleanly")
        app.dismissSearch()
        contextCaptureEnabled = false
        simulatedFrontmostApp = nil

        // MARK: - 5. P2-B Independent SnippetLibrary, Settings Page, Legacy Migration & Crash Removal
        let legacyClipboardRoot = clipboardFixtureRoot.appendingPathComponent("P2BLegacyClipboard", isDirectory: true)
        try fm.createDirectory(at: legacyClipboardRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let legacyDBURL = legacyClipboardRoot.appendingPathComponent(".history.sqlite")
        var rawDB: OpaquePointer?
        try check(sqlite3_open(legacyDBURL.path, &rawDB) == SQLITE_OK, "could not create legacy clipboard sqlite fixture")
        let createLegacySQL = """
            CREATE TABLE clips (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT,
                image BLOB,
                thumbnail BLOB,
                captured REAL NOT NULL,
                bundle_id TEXT,
                app_name TEXT,
                digest BLOB NOT NULL,
                file_path TEXT,
                pinned INTEGER NOT NULL DEFAULT 0,
                recency INTEGER NOT NULL
            );
            INSERT INTO clips (text, captured, digest, pinned, recency)
            VALUES ('legacy row before alias column', 1000.0, X'01020304', 0, 1);
            """
        try check(sqlite3_exec(rawDB, createLegacySQL, nil, nil, nil) == SQLITE_OK, "could not seed legacy clipboard table")
        sqlite3_close(rawDB)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyDBURL.path)

        let migratedStore = ClipboardStore(directory: legacyClipboardRoot, limit: 2)
        let migratedItems = try migratedStore.items()
        try check(migratedItems.count == 1 && migratedItems[0].text == "legacy row before alias column" && migratedItems[0].alias == nil,
                  "ClipboardStore failed idempotent alias column migration on legacy sqlite")

        // Verify explicit pinned:false evicts under limit=2 while pinned:true retains.
        _ = try migratedStore.createTemplate(text: "Unpinned {{date}}", alias: "unp", pinned: false, capturedAt: .now)
        _ = try migratedStore.createTemplate(text: "Pinned {{date}}", alias: "pin", pinned: true, capturedAt: .now)
        _ = try migratedStore.upsertText("Filler 1", capturedAt: .now.addingTimeInterval(1), bundleID: nil, appName: nil)
        _ = try migratedStore.upsertText("Filler 2", capturedAt: .now.addingTimeInterval(2), bundleID: nil, appName: nil)
        let afterEviction = try migratedStore.items()
        try check(afterEviction.contains { $0.alias == "pin" && $0.pinned } &&
                  !afterEviction.contains { $0.alias == "unp" },
                  "ClipboardStore did not evict unpinned template or failed to retain pinned template: \(afterEviction)")

        // Single-pass non-recursive variable expansion.
        let fixedZone = TimeZone(secondsFromGMT: 0)!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = fixedZone
        let fixedDate = utcCal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9, minute: 5))!
        let expanded = ClipboardTemplateExpander.expand(
            "{{date}}|{{time}}|{{datetime}}|{{clipboard}}",
            clipboardText: "{{date}} {{clipboard}} literal",
            now: fixedDate,
            timeZone: fixedZone
        )
        try check(expanded == "2026-11-28|09:05|2026-11-28 09:05|{{date}} {{clipboard}} literal",
                  "ClipboardTemplateExpander failed single-pass non-recursive expansion: \(expanded)")

        // SnippetLibrary CRUD, reserved/duplicate/invalid alias rejection, permissions, and legacy migration.
        let isoSnippetsDir = clipboardFixtureRoot.appendingPathComponent("IsoSnippets", isDirectory: true)
        let isoLib = SnippetLibrary(directory: isoSnippetsDir)
        for reservedVerb in ["qa", "tr", "translate", "img", "cb", "clip", "win"] {
            try check(isoLib.save(alias: reservedVerb, content: "content") == .reservedAlias(reservedVerb),
                      "SnippetLibrary did not reject reserved verb '\(reservedVerb)'")
        }
        try check(isoLib.save(alias: "bad alias", content: "content") == .invalidAlias &&
                  isoLib.save(alias: "ok", content: "   \n  ") == .emptyContent,
                  "SnippetLibrary did not reject invalid alias or empty content")

        guard case .saved(let savedInvoice) = isoLib.save(
            alias: "fapiao",
            title: "公司发票",
            content: "抬头：Lumen\n日期：{{date}}",
            pinnedToHome: true
        ) else {
            throw Failure("SnippetLibrary failed to save valid snippet")
        }
        try check(isoLib.save(alias: "FAPIAO", content: "dup") == .aliasInUse("fapiao"),
                  "SnippetLibrary allowed duplicate alias")
        guard case .saved(let updatedInvoice) = isoLib.save(
            id: savedInvoice.id,
            alias: "fapiao",
            title: "开票信息",
            content: "抬头：Lumen Inc.\n日期：{{date}}",
            pinnedToHome: true
        ) else {
            throw Failure("SnippetLibrary failed to update existing snippet")
        }
        let snippetDirMode = try fm.attributesOfItem(atPath: isoSnippetsDir.path)[.posixPermissions] as? NSNumber
        let snippetFileMode = try fm.attributesOfItem(atPath: isoSnippetsDir.appendingPathComponent("snippets.json").path)[.posixPermissions] as? NSNumber
        try check(snippetDirMode?.intValue == 0o700 && snippetFileMode?.intValue == 0o600,
                  "SnippetLibrary storage permissions were not 0700/0600")
        let reloadedLib = SnippetLibrary(directory: isoSnippetsDir)
        try check(reloadedLib.snippets == [updatedInvoice] && reloadedLib.homeItems == [updatedInvoice],
                  "SnippetLibrary did not round-trip updated snippet from disk")
        isoLib.togglePinToHome(updatedInvoice.id)
        try check(isoLib.homeItems.isEmpty, "togglePinToHome did not unpin snippet")
        isoLib.remove(updatedInvoice.id)
        try check(isoLib.snippets.isEmpty, "SnippetLibrary.remove did not delete snippet")

        // Legacy ClipboardStore -> SnippetLibrary one-time idempotent migration.
        let legacyMigrateClipRoot = clipboardFixtureRoot.appendingPathComponent("LegacyMigrateClips", isDirectory: true)
        let legacyMigrateStore = ClipboardStore(directory: legacyMigrateClipRoot, limit: 10)
        _ = try legacyMigrateStore.createTemplate(text: "Legacy Template {{date}}", alias: "leg", pinned: true, capturedAt: .now)
        let migratedLibDir = clipboardFixtureRoot.appendingPathComponent("MigratedSnippets", isDirectory: true)
        let migratedLib = SnippetLibrary(directory: migratedLibDir)
        migratedLib.migrateLegacyClipboardTemplates(from: legacyMigrateStore)
        try check(migratedLib.migratedLegacyClipboard &&
                  migratedLib.snippets.count == 1 &&
                  migratedLib.snippets.first?.alias == "leg" &&
                  migratedLib.snippets.first?.content == "Legacy Template {{date}}",
                  "SnippetLibrary failed legacy ClipboardStore template migration: \(migratedLib.snippets)")
        migratedLib.remove(migratedLib.snippets[0].id)
        migratedLib.migrateLegacyClipboardTemplates(from: legacyMigrateStore)
        try check(migratedLib.snippets.isEmpty, "SnippetLibrary re-migrated legacy templates after deletion")

        // End-to-end AppDelegate integration:
        // 1. Save pinned & unpinned snippets into model.snippets; clipboard.clearAll() leaves snippets 100% intact.
        // 2. Empty search shows pinnedToHome snippet alongside shortcuts.home (and omits unpinned).
        // 3. Main search .snippet expansion, internal paste, lastUsedAt update, and Cmd+K actions.
        let clipMgr = app.clipboard
        clipMgr.clearAll()
        try writeClipboardText("Disposable clip before clearAll")
        clipMgr.poll()
        try check(!clipMgr.items.isEmpty, "clipboard fixture failed to record clip")

        guard case .saved(let greetSnippet) = model.snippets.save(
            alias: "greet",
            title: "Greeting Template",
            content: "Hello on {{date}} from {{clipboard}}",
            pinnedToHome: true
        ), case .saved(let sigSnippet) = model.snippets.save(
            alias: "sig",
            title: "Signature",
            content: "Best,\nLumen",
            pinnedToHome: false
        ) else {
            throw Failure("could not save smoke snippets on model.snippets")
        }
        defer {
            model.snippets.remove(greetSnippet.id)
            model.snippets.remove(sigSnippet.id)
            clipMgr.clearAll()
        }

        clipMgr.clearAll()
        try await until("clipboard.clearAll finished while leaving model.snippets intact") {
            clipMgr.items.isEmpty
        }
        let diskSnippetsAfterClear = SnippetLibrary(directory: model.snippets.directory).snippets
        try check(model.snippets.snippets.count >= 2 &&
                  diskSnippetsAfterClear.contains(where: { $0.id == greetSnippet.id }) &&
                  diskSnippetsAfterClear.contains(where: { $0.id == sigSnippet.id }),
                  "clipboard.clearAll affected independent SnippetLibrary")

        // Empty search home rows surface pinnedToHome snippets, omitting unpinned ones.
        app.showSearch()
        try type("", into: app)
        try await until("empty search home surfaced pinnedToHome snippet") {
            model.visibleResults.contains(.snippet(greetSnippet)) &&
                !model.visibleResults.contains(.snippet(sigSnippet))
        }

        // Main search .snippet match -> Return expands variables, writes internally, notes usage, dismisses, and pastes.
        try writeClipboardText("LumenSnippetUser")
        try type("greet", into: app)
        try await until("main search surfaced .snippet row for alias greet") {
            if case .snippet(let s)? = model.selectedResult {
                return s.id == greetSnippet.id && s.pinnedToHome
            }
            return false
        }
        let pasteCountBeforeSnippet = pasteIntoPreviousAppCount
        try key(kVK_Return, "\r", in: app)
        let todayPrefix = ClipboardTemplateExpander.expand("Hello on {{date}} from LumenSnippetUser")
        try await until("Return on .snippet expanded template, copied internally, dismissed, and pasted") {
            !app.searchPresented &&
                self.filePasteboard.string(forType: .string) == todayPrefix &&
                self.filePasteboard.types?.contains(ClipboardManager.internalType) == true &&
                self.pasteIntoPreviousAppCount == pasteCountBeforeSnippet + 1 &&
                model.snippets.snippets.first(where: { $0.id == greetSnippet.id })?.lastUsedAt != nil
        }

        // .snippet Cmd+K actions (paste-snippet, copy-snippet, toggle-snippet-pin, manage-snippets).
        app.showSearch()
        try type("greet", into: app)
        try await until("reopened search matched greet snippet") {
            if case .snippet(let s)? = model.selectedResult { return s.id == greetSnippet.id }
            return false
        }
        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        try check(app.contextActions.items.map(\.id) == ["paste-snippet", "copy-snippet", "toggle-snippet-pin", "manage-snippets"],
                  "snippet Cmd+K menu mismatch: \(app.contextActions.items.map(\.id))")
        filePasteboard.clearContents()
        try writeClipboardText("CopyOnlyUser")
        let expectedCopyOnly = ClipboardTemplateExpander.expand("Hello on {{date}} from CopyOnlyUser")
        let pasteCountBeforeCopyOnly = pasteIntoPreviousAppCount
        app.contextActions.run(1) // copy-snippet
        try await until("copy-snippet copied expanded text without triggering paste") {
            !app.searchPresented &&
                self.filePasteboard.string(forType: .string) == expectedCopyOnly &&
                self.filePasteboard.types?.contains(ClipboardManager.internalType) == true &&
                self.pasteIntoPreviousAppCount == pasteCountBeforeCopyOnly
        }

        // ClipboardHistoryView (管理短语… / 存为短语…) + cb Cmd+K save-as-snippet -> Settings .snippets prefill & Light/Dark render.
        let clipTextForSnippet = "Meeting follow-up for {{date}}"
        try writeClipboardText(clipTextForSnippet)
        clipMgr.poll()
        app.showSearch()
        try type("cb ", into: app)
        try await until("cb loaded clip for Save as Snippet check") {
            app.commands.selectedClipboardItem?.text == clipTextForSnippet
        }
        app.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let cbLight = try render(.aqua, window: app.panel)
        _ = try render(.darkAqua, window: app.panel)
        if exists("capture-icons") || exists("capture-snapshots") {
            if let png = cbLight.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("lumen-clipboard-snippets-light.png"))
            }
        }
        app.panel.appearance = nil
        let cbTexts = recognizedStrings(in: cbLight).joined(separator: " ")
        try check((cbTexts.contains("管理短语") || cbTexts.contains("Manage Snippets")) &&
                  (cbTexts.contains("存为短语") || cbTexts.contains("Save as Snippet")),
                  "ClipboardHistoryView did not render 管理短语… and 存为短语… buttons (recognized: \(cbTexts))")

        try key(kVK_ANSI_K, "k", in: app, throughPanel: true, flags: [.command])
        guard let saveSnippetIdx = app.contextActions.items.firstIndex(where: { $0.id == "save-as-snippet" }) else {
            throw Failure("missing save-as-snippet in cb Cmd+K menu: \(app.contextActions.items.map(\.id))")
        }
        app.contextActions.run(saveSnippetIdx)
        try await until("cb Cmd+K save-as-snippet opened Settings on .snippets and consumed prefill") {
            app.settings?.contentView?.layoutSubtreeIfNeeded()
            return !app.searchPresented &&
                app.settings != nil &&
                app.settingsSession.page == .snippets &&
                app.settingsSession.pendingSnippetContent == nil
        }
        if let settingsWindow = app.settings {
            try await Task.sleep(for: .milliseconds(60))
            let light = try render(.aqua, window: settingsWindow)
            let dark = try render(.darkAqua, window: settingsWindow)
            if exists("capture-icons") || exists("capture-snapshots") {
                if let lp = light.representation(using: .png, properties: [:]) {
                    try lp.write(to: directory.appendingPathComponent("lumen-settings-snippets-prefill-light.png"))
                }
                if let dp = dark.representation(using: .png, properties: [:]) {
                    try dp.write(to: directory.appendingPathComponent("lumen-settings-snippets-prefill-dark.png"))
                }
            }
            settingsWindow.appearance = nil
            try check(light.pixelsWide > 0 && dark.pixelsWide > 0, "SnippetSettingsView failed Light/Dark render")
            if let settingsContent = settingsWindow.contentView {
                try await until("SnippetSettingsView populated NSTextView with prefilled content") {
                    settingsContent.layoutSubtreeIfNeeded()
                    return self.findTextView(in: settingsContent, containing: clipTextForSnippet) != nil
                }
            }
            settingsWindow.close()
        }
        print("Wave 2 features + UAT fixes 1/2/3 passed (Quick Switch focus/servicePID, Cmd+Shift+Delete context clear, independent SnippetLibrary + Settings)")
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
        var minimumHeight: CGFloat = 0
        var edgeClampBounds: CGRect? = nil
        var enhancedUI = false
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
    var onScreen: [Int] = []

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

    func onScreenWindows(excludingPID: pid_t) -> [(window: Int, attributes: WindowAttributes, frame: CGRect)] {
        onScreen.compactMap { id in
            guard let state = states[id] else { return nil }
            let attributes = WindowAttributes(role: state.role, subrole: state.subrole, minimized: state.minimized,
                                              fullScreen: state.fullScreen, positionSettable: state.positionSettable,
                                              sizeSettable: state.sizeSettable, frame: state.frame)
            return (id, attributes, state.frame)
        }
    }

    func withFrameMutation<T>(on window: Int, _ body: () -> T) -> T {
        let wasEnhanced = states[window]?.enhancedUI == true
        if wasEnhanced { states[window]?.enhancedUI = false }
        defer { if wasEnhanced { states[window]?.enhancedUI = true } }
        return body()
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
        if var state = states[window] {
            var next = CGRect(origin: position, size: state.frame.size)
            if let bounds = state.edgeClampBounds {
                next = WindowLayoutPlanner.Placement.clamp(next, to: bounds)
            }
            state.frame = next
            states[window] = state
        }
        return true
    }

    func setSize(_ size: CGSize, of window: Int) -> Bool {
        writes.append(.size(window, size))
        if var state = states[window] {
            if state.enhancedUI { return true }
            var width = max(size.width, state.minimumWidth)
            var height = max(size.height, state.minimumHeight)
            if let bounds = state.edgeClampBounds {
                width = min(width, max(bounds.maxX - state.frame.minX, state.minimumWidth))
                height = min(height, max(bounds.maxY - state.frame.minY, state.minimumHeight))
                state.frame.size = CGSize(width: width, height: height)
            } else {
                state.frame.size = CGSize(width: width, height: height)
                state.frame.origin.y += 20 // Simulate WindowServer shifting the origin on resize.
            }
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

private final class SmokeDefinitionStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable (String) -> String?)?

    func get() -> (@Sendable (String) -> String?)? {
        lock.withLock { provider }
    }

    func set(_ next: (@Sendable (String) -> String?)?) {
        lock.withLock { provider = next }
    }
}

private final class SmokePersonalDataHarness: @unchecked Sendable {
    private let lock = NSLock()
    var contactsStatus: PersonalDataAuthStatus = .notDetermined
    var calendarStatus: PersonalDataAuthStatus = .notDetermined
    var remindersStatus: PersonalDataAuthStatus = .notDetermined
    var nextAccess: PersonalDataAuthStatus = .denied
    var accessRequests = 0
    var contacts: [ContactHit] = []
    var events: [CalendarEventHit] = []
    var reminders: [ReminderHit] = []
    var completedIDs: [String] = []

    func reset() {
        lock.withLock {
            contactsStatus = .notDetermined
            calendarStatus = .notDetermined
            remindersStatus = .notDetermined
            nextAccess = .denied
            accessRequests = 0
            contacts = []
            events = []
            reminders = []
            completedIDs = []
        }
    }

    func setContactsStatus(_ status: PersonalDataAuthStatus) {
        lock.withLock { contactsStatus = status }
    }

    func makeProvider() -> PersonalDataProvider {
        PersonalDataProvider(
            contactsStatus: { [weak self] in
                self?.lock.withLock { self?.contactsStatus } ?? .notDetermined
            },
            requestContactsAccess: { [weak self] in
                guard let self else { return .denied }
                return self.lock.withLock {
                    self.accessRequests += 1
                    self.contactsStatus = self.nextAccess
                    return self.nextAccess
                }
            },
            fetchContacts: { [weak self] in
                self?.lock.withLock { self?.contacts } ?? []
            },
            calendarStatus: { [weak self] in
                self?.lock.withLock { self?.calendarStatus } ?? .notDetermined
            },
            requestCalendarAccess: { [weak self] in
                guard let self else { return .denied }
                return self.lock.withLock {
                    self.accessRequests += 1
                    self.calendarStatus = self.nextAccess
                    return self.nextAccess
                }
            },
            fetchEvents: { [weak self] _, _ in
                self?.lock.withLock { self?.events } ?? []
            },
            remindersStatus: { [weak self] in
                self?.lock.withLock { self?.remindersStatus } ?? .notDetermined
            },
            requestRemindersAccess: { [weak self] in
                guard let self else { return .denied }
                return self.lock.withLock {
                    self.accessRequests += 1
                    self.remindersStatus = self.nextAccess
                    return self.nextAccess
                }
            },
            fetchReminders: { [weak self] in
                self?.lock.withLock { self?.reminders } ?? []
            },
            completeReminder: { [weak self] id in
                guard let self else { return false }
                return self.lock.withLock {
                    guard let index = self.reminders.firstIndex(where: { $0.id == id }) else { return false }
                    self.reminders.remove(at: index)
                    self.completedIDs.append(id)
                    return true
                }
            }
        )
    }
}

final class SmokeFileDialogAXAdapter: FileDialogAXAdapter, @unchecked Sendable {
    struct NodeState {
        var role: String?
        var subrole: String?
        var identifier: String?
        var title: String?
        var descriptionText: String?
        var placeholder: String?
        var value: String?
        var enabled: Bool?
        var url: URL?
        var parent: FileDialogAXElement?
        var children: [FileDialogAXElement] = []
        var sheets: [FileDialogAXElement] = []
        var proxy: FileDialogAXElement?
        var window: FileDialogAXElement?
        var topLevel: FileDialogAXElement?
        var defaultButton: FileDialogAXElement?
    }

    private let lock = NSLock()
    private var trusted = false
    private var nodes: [FileDialogAXElement: NodeState] = [:]
    private var bundleIDs: [pid_t: String] = [:]
    private var appElements: [pid_t: FileDialogAXElement] = [:]
    private var focusedByPID: [pid_t: FileDialogAXElement] = [:]
    private var focusedWindowByPID: [pid_t: FileDialogAXElement] = [:]
    private var mainWindowByPID: [pid_t: FileDialogAXElement] = [:]
    private var windowsByPID: [pid_t: [FileDialogAXElement]] = [:]
    private var pidsByBundleID: [String: [pid_t]] = [:]
    private var elementPIDs: [FileDialogAXElement: pid_t] = [:]
    private var systemFocused: FileDialogAXElement?
    private var activePIDs: Set<pid_t> = []
    private var writtenValues: [FileDialogAXElement: String] = [:]
    private var shortcuts: [(CGKeyCode, CGEventFlags)] = []
    private var performedActions: [(String, FileDialogAXElement)] = []
    var onShortcut: ((CGKeyCode, CGEventFlags) -> Void)?
    var onPerformAction: ((String, FileDialogAXElement) -> Void)?

    func reset() {
        lock.withLock {
            trusted = false
            nodes.removeAll()
            bundleIDs.removeAll()
            appElements.removeAll()
            focusedByPID.removeAll()
            focusedWindowByPID.removeAll()
            mainWindowByPID.removeAll()
            windowsByPID.removeAll()
            pidsByBundleID.removeAll()
            elementPIDs.removeAll()
            systemFocused = nil
            activePIDs.removeAll()
            writtenValues.removeAll()
            shortcuts.removeAll()
            performedActions.removeAll()
            onShortcut = nil
            onPerformAction = nil
        }
    }

    func setTrusted(_ value: Bool) { lock.withLock { trusted = value } }

    func clearWritesAndShortcuts() {
        lock.withLock {
            writtenValues.removeAll()
            shortcuts.removeAll()
            performedActions.removeAll()
        }
    }

    func recordedShortcuts() -> [(CGKeyCode, CGEventFlags)] {
        lock.withLock { shortcuts }
    }

    func recordedPerformedActions() -> [(String, FileDialogAXElement)] {
        lock.withLock { performedActions }
    }

    func setElementPID(_ element: FileDialogAXElement, pid: pid_t) {
        lock.withLock { elementPIDs[element] = pid }
    }

    func setActive(_ active: Bool, pid: pid_t) {
        lock.withLock {
            if active { activePIDs.insert(pid) }
            else { activePIDs.remove(pid) }
        }
    }

    func configureService(pid: pid_t, windows: [FileDialogAXElement]) {
        lock.withLock {
            let appEl = FileDialogAXElement.mock("service-\(pid)")
            appElements[pid] = appEl
            bundleIDs[pid] = "com.apple.appkit.xpc.openAndSavePanelService"
            windowsByPID[pid] = windows
            focusedWindowByPID[pid] = windows.first
        }
    }

    func setSystemFocused(_ element: FileDialogAXElement?) {
        lock.withLock { systemFocused = element }
    }

    func lastWrittenValue(for element: FileDialogAXElement) -> String? {
        lock.withLock { writtenValues[element] }
    }

    func configureNode(
        _ element: FileDialogAXElement,
        role: String? = nil,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        descriptionText: String? = nil,
        placeholder: String? = nil,
        value: String? = nil,
        enabled: Bool? = nil,
        url: URL? = nil,
        parent: FileDialogAXElement? = nil,
        children: [FileDialogAXElement] = [],
        sheets: [FileDialogAXElement] = [],
        proxy: FileDialogAXElement? = nil,
        window: FileDialogAXElement? = nil,
        topLevel: FileDialogAXElement? = nil,
        defaultButton: FileDialogAXElement? = nil
    ) {
        lock.withLock {
            nodes[element] = NodeState(
                role: role, subrole: subrole, identifier: identifier, title: title,
                descriptionText: descriptionText, placeholder: placeholder, value: value,
                enabled: enabled, url: url, parent: parent, children: children, sheets: sheets,
                proxy: proxy, window: window, topLevel: topLevel, defaultButton: defaultButton
            )
        }
    }

    func configureApp(
        pid: pid_t,
        bundleID: String,
        focusedWindow: FileDialogAXElement,
        focusedElement: FileDialogAXElement
    ) {
        lock.withLock {
            let appEl = FileDialogAXElement.mock("app-\(pid)")
            appElements[pid] = appEl
            bundleIDs[pid] = bundleID
            focusedWindowByPID[pid] = focusedWindow
            mainWindowByPID[pid] = focusedWindow
            focusedByPID[pid] = focusedElement
            windowsByPID[pid] = [focusedWindow]
            elementPIDs[focusedElement] = pid
            systemFocused = focusedElement
        }
    }

    func configureFinder(pid: pid_t, windows: [FileDialogAXElement]) {
        lock.withLock {
            let appEl = FileDialogAXElement.mock("finder-\(pid)")
            appElements[pid] = appEl
            bundleIDs[pid] = "com.apple.finder"
            pidsByBundleID["com.apple.finder"] = [pid]
            windowsByPID[pid] = windows
        }
    }

    func isProcessTrusted() -> Bool { lock.withLock { trusted } }
    func applicationElement(for pid: pid_t) -> FileDialogAXElement? { lock.withLock { appElements[pid] } }
    func systemFocusedElement() -> FileDialogAXElement? { lock.withLock { systemFocused } }
    func focusedElement(in pid: pid_t) -> FileDialogAXElement? { lock.withLock { focusedByPID[pid] } }
    func pid(of element: FileDialogAXElement) -> pid_t? { lock.withLock { elementPIDs[element] } }
    func bundleIdentifier(for pid: pid_t) -> String? { lock.withLock { bundleIDs[pid] } }
    func runningApplicationPIDs(bundleIdentifier: String) -> [pid_t] { lock.withLock { pidsByBundleID[bundleIdentifier] ?? [] } }
    func isApplicationActive(pid: pid_t) -> Bool { lock.withLock { activePIDs.contains(pid) } }
    func activateApplication(pid: pid_t) -> Bool {
        _ = lock.withLock { activePIDs.insert(pid) }
        return true
    }

    func elementAttribute(_ attribute: String, of element: FileDialogAXElement) -> FileDialogAXElement? {
        lock.withLock {
            if let pid = appElements.first(where: { $0.value == element })?.key {
                switch attribute {
                case kAXFocusedWindowAttribute: return focusedWindowByPID[pid]
                case kAXMainWindowAttribute: return mainWindowByPID[pid]
                case kAXFocusedUIElementAttribute: return focusedByPID[pid]
                default: break
                }
            }
            guard let node = nodes[element] else { return nil }
            switch attribute {
            case kAXParentAttribute: return node.parent
            case kAXProxyAttribute: return node.proxy
            case kAXWindowAttribute: return node.window
            case kAXTopLevelUIElementAttribute: return node.topLevel
            case kAXDefaultButtonAttribute: return node.defaultButton
            default: return nil
            }
        }
    }

    func elementsAttribute(_ attribute: String, of element: FileDialogAXElement) -> [FileDialogAXElement] {
        lock.withLock {
            if let pid = appElements.first(where: { $0.value == element })?.key,
               attribute == (kAXWindowsAttribute as String) {
                return windowsByPID[pid] ?? []
            }
            guard let node = nodes[element] else { return [] }
            switch attribute {
            case kAXChildrenAttribute: return node.children
            case "AXSheets": return node.sheets
            default: return []
            }
        }
    }

    func stringAttribute(_ attribute: String, of element: FileDialogAXElement) -> String? {
        lock.withLock {
            guard let node = nodes[element] else { return nil }
            switch attribute {
            case kAXRoleAttribute: return node.role
            case kAXSubroleAttribute: return node.subrole
            case kAXIdentifierAttribute: return node.identifier
            case kAXTitleAttribute: return node.title
            case kAXDescriptionAttribute: return node.descriptionText
            case kAXPlaceholderValueAttribute: return node.placeholder
            case kAXValueAttribute: return node.value
            default: return nil
            }
        }
    }

    func boolAttribute(_ attribute: String, of element: FileDialogAXElement) -> Bool? {
        lock.withLock {
            guard attribute == (kAXEnabledAttribute as String) else { return nil }
            return nodes[element]?.enabled
        }
    }

    func urlAttribute(_ attribute: String, of element: FileDialogAXElement) -> URL? {
        lock.withLock {
            guard attribute == (kAXDocumentAttribute as String) || attribute == (kAXURLAttribute as String) else { return nil }
            return nodes[element]?.url
        }
    }

    func setStringAttribute(_ attribute: String, value: String, on element: FileDialogAXElement) -> Bool {
        lock.withLock {
            guard attribute == (kAXValueAttribute as String) else { return false }
            writtenValues[element] = value
            nodes[element]?.value = value
            return true
        }
    }

    func performAction(_ action: String, on element: FileDialogAXElement) -> Bool {
        let callback = lock.withLock { () -> ((String, FileDialogAXElement) -> Void)? in
            performedActions.append((action, element))
            return onPerformAction
        }
        callback?(action, element)
        return true
    }

    func postKeyboardShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let callback = lock.withLock { () -> ((CGKeyCode, CGEventFlags) -> Void)? in
            shortcuts.append((keyCode, flags))
            return onShortcut
        }
        callback?(keyCode, flags)
        return true
    }
}

final class SmokeSelectionAXAdapter: SelectionAXAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var trustedState = false
    private var focusedStates: [pid_t: SelectionAXElementState] = [:]
    private var selectedFiles: [pid_t: [URL]] = [:]

    var trusted: Bool {
        get { lock.withLock { trustedState } }
        set { lock.withLock { trustedState = newValue } }
    }

    var focusedByPID: [pid_t: SelectionAXElementState] {
        get { lock.withLock { focusedStates } }
        set { lock.withLock { focusedStates = newValue } }
    }

    var selectedFileURLsByPID: [pid_t: [URL]] {
        get { lock.withLock { selectedFiles } }
        set { lock.withLock { selectedFiles = newValue } }
    }

    func reset() {
        lock.withLock {
            trustedState = false
            focusedStates.removeAll()
            selectedFiles.removeAll()
        }
    }

    func isTrusted() -> Bool { trusted }
    func focusedElementState(in pid: pid_t) -> SelectionAXElementState? { lock.withLock { focusedStates[pid] } }
    func selectedFileURLs(in pid: pid_t, limit: Int) -> [URL] {
        lock.withLock { Array((selectedFiles[pid] ?? []).prefix(limit)) }
    }
}

private final class SmokeLoopbackHTTPServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let stopLock = NSLock()
    private var stopped = false
    private var userMessages: [String] = []

    func recordedUserMessages() -> [String] {
        stopLock.withLock { userMessages }
    }

    init(replyText: String) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        let payloadObject: [String: Any] = [
            "choices": [["message": ["content": replyText], "finish_reason": "stop"]]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payloadObject)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(jsonData)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                guard let self, !self.stopLock.withLock({ self.stopped }) else { break }
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 { break }
                var received = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                var expectedTotal: Int?
                while true {
                    let n = Darwin.read(clientFD, &buf, buf.count)
                    if n <= 0 { break }
                    received.append(contentsOf: buf.prefix(n))
                    if expectedTotal == nil, let headerRange = received.range(of: Data("\r\n\r\n".utf8)) {
                        let headerText = String(decoding: received[..<headerRange.lowerBound], as: UTF8.self)
                        let contentLength = headerText
                            .split(separator: "\r\n")
                            .compactMap { line -> Int? in
                                let lower = line.lowercased()
                                guard lower.hasPrefix("content-length:") else { return nil }
                                return Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                            }
                            .first ?? 0
                        expectedTotal = headerRange.upperBound + contentLength
                    }
                    if let expectedTotal, received.count >= expectedTotal { break }
                }
                if let headerRange = received.range(of: Data("\r\n\r\n".utf8)) {
                    let bodyData = received[headerRange.upperBound...]
                    if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                       let messages = json["messages"] as? [[String: Any]],
                       let userMessage = messages.last(where: { ($0["role"] as? String) == "user" })?["content"] as? String {
                        self.stopLock.withLock { self.userMessages.append(userMessage) }
                    }
                }
                responseData.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var sent = 0
                    while sent < raw.count {
                        let n = Darwin.write(clientFD, base.advanced(by: sent), raw.count - sent)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                Darwin.close(clientFD)
            }
        }
    }

    func stop() {
        stopLock.withLock {
            guard !stopped else { return }
            stopped = true
            Darwin.close(listenFD)
        }
    }

    deinit { stop() }
}
#endif
