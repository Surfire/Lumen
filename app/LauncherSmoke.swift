import AppKit
import Carbon
import Combine

// Runs inside the built app with app-local AppKit and Carbon events and an isolated index.
@MainActor
final class LauncherSmoke {
    let corpus: URL
    let database: URL
    let executable: URL?
    let gemmaHome: URL
    let language: String
    let usesOffscreenWindows: Bool
    private let directory: URL
    private let startsWithIndex: Bool
    private let controlledTiming: Bool
    var opened: URL?
    var revealed: URL?
    var wasActivated = false
    var chosenSettingsDirectories: [URL]?
    var chosenDiagnosticFile: URL?

    private init(_ directory: URL, language: String, usesOffscreenWindows: Bool) {
        self.directory = directory
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
            try await verify(app)
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
        try check(app.searchField.placeholderString == (language == "zh" ? "搜索本机文件和文件夹" : "Search local files and folders"),
                  "search field did not use requested language")
        _ = try editor(app)

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
            model.scope.documents = controlledTiming
            app.startBackgroundIndex()
            try check(model.isIndexing && !app.searchPresented, "first-run index did not dismiss the launcher")
            if controlledTiming {
                try await until("cold progress available while launcher stays hidden") {
                    model.scanProgress?.entries == 17 && !app.searchPresented &&
                        app.statusMenu?.items.contains(where: { $0.title.contains("剩余时间待估") }) == true
                }
                try check(model.scanProgress?.fraction == nil && model.scanProgress?.eta == nil &&
                          app.statusMenu?.items.contains(where: { $0.title.contains("剩余时间待估") }) == true,
                          "cold progress showed an estimate or was missing from menu")
                app.showSearch()
                try key(kVK_Escape, "\u{1b}", in: app, throughPanel: true)
                try check(!app.searchPresented && model.isIndexing, "Escape canceled background indexing")
                try signal("finish-cold-progress")
            }
            do {
                try await until("first names snapshot ready without reopening") { model.indexPhase == .ready && !app.searchPresented }
                app.showSearch()
                try type("archive", into: app)
                try await until("names searchable after an explicit reopen") { model.hits.contains { $0.name == "archive-one.txt" } }
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

        try type("obsolete", into: app)
        try await until("obsolete reply intentionally held") { self.exists("obsolete-started") }
        try type("qingshan", into: app)
        try check(model.selection == selected && !model.hits.isEmpty && model.selectedHit == nil,
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
        try await until("body hit revalidated in its source lane") { self.revealed?.lastPathComponent == "body-match.md" }
        revealed = nil
        try check(app.panel.frame == frame && app.panel.contentView === chrome && resizeCount == 0,
                  "typing or result lane delivery resized or replaced the launcher")
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
        session.page = .about
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
        try await until("the draft did not hide live results") { model.selectedHit?.name == "protected-neighbor.md" }
        session.page = .about
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
        session.page = .about
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
        print("Settings smoke passed (four pages, shortcut, draft, exact-scope rebuild, Apply, and file diagnostics)")
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
                model.watchProgress?.entries == 6 && model.watchState == .running && model.hits.isEmpty
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
        try key(kVK_Return, "\r", in: app)
        try check(model.searchNotice?.problem == .online && opened == nil && revealed == nil,
                  "Return activated a cloud reference")
        if controlledTiming { try signal("hold-cloud-reveal") }
        try key(kVK_Return, "\r", in: app, throughPanel: true, flags: [.command])
        if controlledTiming {
            try await until("Finder action held for a concurrent watch event") { self.exists("cloud-reveal-started") }
            var refreshed = false
            let refresh = model.$searching.sink { if $0 { refreshed = true } }
            defer { refresh.cancel() }
            try signal("update-watch")
            try await until("watch refreshed the current query during Finder validation") {
                refreshed && !model.searching
            }
            try signal("finish-cloud-reveal")
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
        try signal("finish-semantic-enrichment")
        try await until("bounded related excerpts appended") {
            model.hits.filter(\.isSemanticCandidate).count == 3 && !model.semanticBusy
        }
        try check(Array(model.hits.prefix(direct.count)).map(\.path) == direct && model.selection == selected &&
                  Set(model.hits.map(\.path)).count == model.hits.count && app.panel.frame == frame,
                  "related excerpts duplicated results, changed direct rank, stole selection, or resized the panel")
        guard let hit = model.hits.first(where: { $0.name == "notes.md" && $0.isSemanticCandidate })
        else { throw Failure("missing Gemma candidate") }
        try check(model.relatedExcerptsLabel == "相关原文", "candidate label did not say related excerpts")
        var resolved: URL?
        model.resolve(hit, revealInFinder: false) { resolved = $0 }
        try await until("candidate action rechecked the query through explicit Gemma") { resolved?.path == hit.path }
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
        try check(lineCount("semantic-serve-launches") == 1 && exists("explicit-gemma-query-started"),
                  "refinements did not reuse one worker or result action skipped explicit Gemma")

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
        try signal("finish-model-check")
        try await until("verified Gemma backend is ready") { model.localModelState == .ready }
        try check(!exists("semantic-serve-launches") && model.selectedHit?.name == "notes.md",
                  "verification launched an unrelated semantic request")
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
        let spotlight = try event(kVK_Space, " ", in: app, flags: [.command])
        app.recordShortcut(spotlight)
        guard case .system? = app.model.hotKeyIssue else { throw Failure("Spotlight chord was not diagnosed as reserved") }
        app.recordShortcut(try event(kVK_ANSI_G, "G", in: app, flags: [.control, .option]))
        guard case .system? = app.model.hotKeyIssue else { throw Failure("VoiceOver chord was not diagnosed as reserved") }

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
        app.dismissSearch()
        try check(SendEventToEventTarget(carbon, GetApplicationEventTarget()) == noErr && app.searchPresented,
                  "a missing release event suppressed the next shortcut")
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
