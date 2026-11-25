import AppKit
import Carbon
import Combine

// Runs inside the built app with app-local AppKit and Carbon events and an isolated index.
@MainActor
final class LauncherSmoke {
    let corpus: URL
    let database: URL
    let executable: URL?
    let language: String
    let usesOffscreenWindows: Bool
    private let directory: URL
    private let startsWithIndex: Bool
    private let controlledTiming: Bool
    var opened: URL?
    var revealed: URL?
    var wasActivated = false

    private init(_ directory: URL, language: String, usesOffscreenWindows: Bool) {
        self.directory = directory
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
            try await verifySemanticInvalidation(app)
            try await verifyStaleBeforeDisplay(app)
            try await verifyReplacedDocument(app)
            try await verifyMissingPath(app)
            try await verifyEmbeddingRun(app)
            if exists("capture-snapshots") { try await captureSnapshots(app) }
        } else {
            try await until("watch capability checked") { model.watchState != .checking }
            if model.watchState == .unavailable {
                try check(executable == nil, "the supplied watch engine did not expose the watch command")
                print("Bundled engine reports manual index updates")
                model.verifyLocalModel()
                try await until("baseline engine reports missing BGE support") {
                    model.localModelState == .unavailable(.unsupported)
                }
            } else if exists("legacy-expected") {
                try await until("legacy index requires a manual rebuild") { model.watchState == .needsSetup }
                return
            } else {
                try await until("real watch ready event received") { model.watchState == .running }
                if exists("verify-engine-progress") {
                    try await until("real engine progress reached the launcher from both processes") {
                        observedScan.contains { $0.phase == "done" && $0.entries > 0 } && !observedWatch.isEmpty
                    }
                }
                if exists("actual-bge") {
                    try await verifyInstalledModel(app)
                    return
                }
                try await verifyWatch(app)
                try await verifyAppliedScope(app)
            }
        }

        try await verifyCloudAction(app)
        try type("archive", into: app)
        try await until("two archive rows from the bundled search engine") { model.hits.count == 2 && !model.searching }
        let expected = model.hits[1].path
        try key(kVK_DownArrow, "\u{f701}", in: app)
        try check(model.selection == expected, "down arrow did not select the second row")
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

    private func verifyInstalledModel(_ app: AppDelegate) async throws {
        let model = app.model
        model.semanticLanguage = language
        model.verifyLocalModel()
        try await until("packaged GUI found and verified installed BGE") { model.localModelState == .ready }
        model.buildEmbeddings()
        try await until("GUI built the actual local semantic index") {
            model.embeddingBatch?.new_embeddings == 2 && model.embeddingBatch?.has_more == false
        }
        let query = language == "zh" ? "屋顶降水如何透入绿地？" : "How can a new recruit learn the job quickly?"
        try type(query, into: app)
        model.semanticSearch()
        try await until("real BGE GUI returned the related original excerpt") {
            model.showingRelatedExcerpts && model.selectedHit?.name == "entry-a.md" &&
                model.selectedHit?.isSemanticCandidate == true &&
                model.selectedHit?.snippet?.contains(language == "zh" ? "种植带" : "experienced teammate") == true
        }
        try check(!NSApp.isActive && self.opened == nil, "model test activated the GUI or opened a document")
        print("Installed BGE GUI smoke passed (\(language))")
    }

    private func verifyTiming(_ app: AppDelegate) async throws {
        let model = app.model
        model.changeMode(.all)
        try await until("combined query intentionally held") { self.exists("combined-started") }
        try check(model.hits.contains { $0.name == "archive-one.txt" } && model.searching,
                  "name result was not published before the combined search")
        try signal("finish-combined")
        try await until("text results appended") { model.hits.contains { $0.matched_by == "text" } }
        model.changeMode(.name)

        try type("obsolete", into: app)
        try await until("obsolete reply intentionally held") { self.exists("obsolete-started") }
        try type("qingshan", into: app)
        try check(model.selection == nil, "edited query retained a stale selection")
        try key(kVK_Return, "\r", in: app)
        try check(opened == nil, "Return activated a stale result")
        try signal("finish-obsolete")
        try await until("latest query survived an obsolete reply") {
            model.hits.count == 1 && model.hits.first?.name == "青山月报.md" && !model.searching
        }

    }

    private func captureSnapshots(_ app: AppDelegate) async throws {
        try type("", into: app)
        try await until("idle launcher is 84 points tall") { app.panel.frame.height == 84 }
        try capture("lumen-idle-light.png", appearance: .aqua, app: app)
        try type("design", into: app)
        try await until("eight visible result rows are laid out") {
            app.model.hits.count >= 8 && !app.model.searching && app.panel.frame.height == 470
        }
        try capture("lumen-results-light.png", appearance: .aqua, app: app)
        try capture("lumen-results-dark.png", appearance: .darkAqua, app: app)
        app.panel.appearance = nil
        try check(!NSApp.isActive && !app.panel.isVisible, "offscreen snapshots activated the app")
    }

    private func capture(_ filename: String, appearance: NSAppearance.Name, app: AppDelegate) throws {
        guard let surface = app.panel.contentView, let appearance = NSAppearance(named: appearance) else {
            throw Failure("could not configure snapshot appearance")
        }
        app.panel.appearance = appearance
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
    }

    private func verifyCloudAction(_ app: AppDelegate) async throws {
        let model = app.model
        try type("cloudledger", into: app)
        try await until("provider metadata result") { model.selectedHit?.availability == "provider_metadata_only" }
        guard let hit = model.selectedHit else { throw Failure("missing cloud result") }
        try key(kVK_Return, "\r", in: app)
        try check(model.searchNotice?.problem == .online && opened == nil && revealed == nil,
                  "Return activated a cloud reference")
        app.revealInFinder(hit)
        try await until("explicit Finder action selected the cloud reference") { self.revealed?.path == hit.path }
        try check(opened == nil && model.query == "cloudledger", "Finder action opened the file or closed search")
    }

    private func verifySemanticInvalidation(_ app: AppDelegate) async throws {
        let model = app.model
        try type("health examination", into: app)
        model.semanticSearch()
        try await until("semantic snippet visible before replacement") {
            model.hits.first?.isSemanticCandidate == true && model.hits.first?.snippet?.contains("archive appears") == true
        }
        try check(model.relatedExcerptsLabel == "相关原文", "candidate label did not say related excerpts")
        guard let hit = model.selectedHit else { throw Failure("missing BGE candidate") }
        var resolved: URL?
        model.resolve(hit, revealInFinder: false) { resolved = $0 }
        try await until("candidate action rechecked the query through BGE") { resolved?.path == hit.path }
        try Data("Replacement body".utf8).write(to: corpus.appendingPathComponent("notes.md"), options: .atomic)
        try signal("update-watch")
        try await until("same-name replacement cleared the cached semantic result and selection") {
            model.hits.isEmpty && model.selection == nil && !model.searching && !model.semanticBusy
        }
        try key(kVK_Return, "\r", in: app)
        try check(opened == nil, "replacement kept the stale semantic hit actionable")
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
        model.changeMode(.text)
        try type("safety original paragraph", into: app)
        try await until("preview visible before replacing a same-name file") {
            model.selectedHit?.snippet?.contains("safety original paragraph") == true
        }
        let file = corpus.appendingPathComponent("content-safety-source.md")
        try Data("Different file at the same path.".utf8).write(to: file, options: .atomic)
        try key(kVK_Return, "\r", in: app)
        try await until("same-name replacement was refused before the watcher event") { model.searchNotice?.problem == .stale }
        try check(opened == nil && model.selection == nil, "the old preview opened a replacement file")
        model.changeMode(.name)
    }

    private func verifyStaleBeforeDisplay(_ app: AppDelegate) async throws {
        let model = app.model
        model.changeMode(.text)
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
        model.changeMode(.name)
    }

    private func verifyEmbeddingRun(_ app: AppDelegate) async throws {
        let model = app.model
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
        model.semanticLanguage = "zh"
        try check(model.embeddingState == .pausing, "changing language did not stop future batches")
        try signal("finish-embedding-7")
        try await until("old language batch drained") { model.indexWork == nil && model.embeddingState == .idle }
        try check(!exists("embedding-8-started"), "changing language queued a batch for the old profile")

        model.semanticLanguage = "en"
        model.buildEmbeddings()
        try await waitForEmbeddingBatch(8)
        model.scope.deny = corpus.appendingPathComponent("Excluded").path
        try check(model.embeddingState == .pausing, "editing scope did not stop future batches")
        try signal("finish-embedding-8")
        try await until("old scope batch drained") { model.indexWork == nil && model.embeddingState == .paused }
        try check(!exists("embedding-9-started"), "editing scope queued a batch for the old scope")
        try check(model.watchState == .running && watchLaunches() == 1, "embedding generation restarted the watcher")
    }

    private func waitForEmbeddingBatch(_ batch: Int) async throws {
        try await until("embedding batch \(batch) started") { self.exists("embedding-\(batch)-started") }
    }

    private func verifyModelResources(_ app: AppDelegate) async throws {
        let model = app.model
        try type("archive", into: app)
        try await until("name results visible without model resources") { model.selectedHit?.name == "archive-one.txt" }
        model.semanticSearch()
        try await until("missing local language resources diagnosed") { model.localModelState == .unavailable(.profile) }
        let label = model.modelDiagnostic(.profile)
        try check(label.contains("BGE") && !label.contains("synthetic-account") && !label.contains("/Users/"),
                  "model diagnostic exposed a raw path or account")
        try check(model.selectedHit?.name == "archive-one.txt" && !exists("bge-query-started"),
                  "missing model cleared lexical results or started the semantic backend")
        model.buildEmbeddings()
        try await until("missing resources prevented embedding") { model.localModelState == .unavailable(.profile) }
        try check(!exists("embeddings-started"), "embedding ran without a verified model")

        try signal("unverified-zh")
        model.verifyLocalModel()
        try await until("present but unverified model rejected") { model.localModelState == .unavailable(.verification) }
        model.changeMode(.text)
        try type("archive appears", into: app)
        try await until("full-text search still worked with an unverified model") { model.selectedHit?.matched_by == "text" }

        model.semanticLanguage = "en"
        try check(model.localModelState == .unchecked, "language change retained an old model verification")
        model.changeMode(.name)
        try type("health examination", into: app)
        model.semanticSearch()
        try await until("English BGE verification held by fixture") { self.exists("model-check-started") }
        try type("archive", into: app)
        try await until("name search continued during model verification") { model.selectedHit?.name == "archive-one.txt" }
        try signal("finish-model-check")
        try await until("verified English backend is ready") { model.localModelState == .ready }
        try check(!exists("bge-query-started") && model.selectedHit?.name == "archive-one.txt",
                  "verification completed a semantic request for obsolete input")
        model.semanticSearch()
        try await until("missing BGE vectors showed a safe hint and restored name search") {
            model.searchNotice?.problem == .semanticNotIndexed && model.searchNotice?.detail.isEmpty == true &&
                model.selectedHit?.name == "archive-one.txt"
        }
        try type("no related excerpts", into: app)
        model.semanticSearch()
        try await until("empty BGE reply kept the related-excerpt context") {
            model.showingRelatedExcerpts && model.hits.isEmpty && !model.semanticBusy
        }
    }

    private func verifyAppliedScope(_ app: AppDelegate) async throws {
        let model = app.model
        let excluded = corpus.appendingPathComponent("Excluded")
        try type("privateneedle", into: app)
        if !startsWithIndex {
            try await until("excluded target visible before applying scope") { model.selectedHit?.name == "privateneedle.txt" }
            model.scope.deny = excluded.path
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
        model.changeMode(.all)
        try type("privateneedle", into: app)
        try await until("old scope result visible with a follow-up query in flight") {
            model.selectedHit != nil && self.exists("scope-search-started")
        }
        opened = nil
        try signal("reject-scope")
        model.scope.deny = corpus.appendingPathComponent("Excluded").path
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
        model.scope.deny = corpus.path
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

    private func watchLaunches() -> Int {
        let url = directory.appendingPathComponent("watch-launches")
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

    private func key(_ code: Int, _ character: String, in app: AppDelegate, throughPanel: Bool = false) throws {
        let event = try event(code, character, in: app)
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

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
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
