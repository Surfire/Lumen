import AppKit
import Combine

enum SearchMode: String, CaseIterable, Identifiable {
    case name, all, text
    var id: String { rawValue }
}

enum IndexPhase: Equatable {
    case checking, needsIndex, ready, unreadable
}

enum IndexWork: Equatable {
    case names, documents, embeddings
}

enum EmbeddingState: Equatable {
    case idle, verifying, running, pausing, paused, finished
}

enum WatchState: Equatable {
    case checking, unavailable, needsSetup, paused, starting, running, failed
}

enum LocalModelState: Equatable {
    case unchecked, checking, ready, unavailable(LocalModelProblem)
}

enum LocalModelProblem: Equatable {
    case unsupported, runtime, worker, profile, verification

    // Classify the failure without presenting raw paths or process diagnostics.
    static func classify(_ diagnostic: String) -> Self? {
        let text = diagnostic.lowercased()
        if text.contains("unrecognized subcommand"), text.contains("model-status") { return .unsupported }
        if text.contains("isolated bge runtime") || text.contains("no module named") ||
            text.contains("packagenotfounderror") { return .runtime }
        if text.contains("bge worker is missing") { return .worker }
        if text.contains("profile is missing") || text.contains("pinned snapshot") { return .profile }
        if text.contains("verified local model files") || text.contains("offline bge worker") ||
            text.contains("unsupported bge worker") { return .verification }
        return nil
    }
}

private struct LocalModelStatus: Decodable {
    let available: Bool
    let verified: Bool
    let diagnostic: String?
}

struct EmbeddingBatch: Decodable {
    let new_embeddings: Int
    let skipped_chunks: Int
    let has_more: Bool
}

private struct WatchEvent: Decodable {
    enum Kind: String, Decodable { case ready, updated }
    let event: Kind
}

enum LauncherProblem {
    case status, indexing, search, semantic, semanticNotIndexed, embeddings, embeddingNoProgress, opening, scope, scopeState, watch, online, stale
}

struct LauncherNotice {
    let problem: LauncherProblem
    let detail: String
    init(_ problem: LauncherProblem, _ detail: String = "") {
        self.problem = problem
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class Launcher: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var hits: [SearchHit] = []
    @Published var selection: String?
    @Published private(set) var mode = SearchMode.name
    @Published private(set) var searching = false
    @Published private(set) var semanticBusy = false
    @Published private(set) var showingRelatedExcerpts = false
    @Published private(set) var localModelState = LocalModelState.unchecked
    @Published private(set) var searchNotice: LauncherNotice?
    @Published private(set) var indexPhase = IndexPhase.checking
    @Published private(set) var indexWork: IndexWork?
    @Published private(set) var indexReport: IndexReport?
    @Published private(set) var indexNotice: LauncherNotice?
    @Published private(set) var scanProgress: IndexProgress?
    @Published private(set) var watchProgress: IndexProgress?
    @Published private(set) var scopePending: Bool
    @Published private(set) var embeddingState = EmbeddingState.idle
    @Published private(set) var embeddingBatch: EmbeddingBatch?
    @Published private(set) var embeddingNotice: LauncherNotice?
    @Published private(set) var watchState = WatchState.checking
    @Published private(set) var watchNotice: LauncherNotice?
    @Published var hotKey: HotKey?
    @Published var hotKeyIssue: HotKeyIssue?
    @Published var language: String { didSet { defaults?.set(language, forKey: "language") } }
    @Published var semanticLanguage: String {
        didSet {
            guard semanticLanguage != oldValue else { return }
            defaults?.set(semanticLanguage, forKey: "semanticLanguage")
            pauseEmbeddings()
            cancelModelCheck()
            localModelState = .unchecked
            if embeddingState != .pausing { embeddingState = .idle }
            embeddingBatch = nil
            embeddingNotice = nil
            if semanticBusy || showingRelatedExcerpts { scheduleSearch() }
        }
    }
    @Published var scope: IndexScope {
        didSet {
            guard scope != oldValue else { return }
            pauseEmbeddings()
            defaults?.set(scope.allow, forKey: "allow")
            defaults?.set(scope.deny, forKey: "deny")
            defaults?.set(scope.documents, forKey: "documents")
        }
    }

    private let engine: LauncherEngine
    private let defaults: UserDefaults?
    private var watchSupported: Bool?
    private var watchReportsProgress = false
    private var indexReportsProgress = true
    private var scanGeneration: UInt64 = 0
    private var revision: UInt64 = 0
    private var searchInputGeneration: UInt64 = 0
    private var debounce: Task<Void, Never>?
    private var firstNamesReady = false
    private var watchGeneration: UInt64 = 0
    private var watcher: Process?
    private var afterWatcherStops: (() -> Void)?
    private var stoppingWatcher = false
    private var writer: Process?
    private var semanticProcess: Process?
    private var modelCheck: Process?
    private var modelCheckGeneration: UInt64 = 0
    private var actionProcess: Process?
    private var closed = false

    var zh: Bool {
        language == "zh" || (language == "system" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSearch: Bool { indexPhase == .ready && (!scopePending || firstNamesReady) }
    var isIndexing: Bool { indexWork == .names || indexWork == .documents }
    var activeProgress: IndexProgress? { isIndexing ? scanProgress : watchProgress }
    var activityBusy: Bool { indexWork != nil || watchState == .starting || watchProgress != nil }
    var relatedExcerptsLabel: String { t("相关原文", "Related Excerpts") }
    var canBuildEmbeddings: Bool {
        canSearch && !scopePending && indexWork == nil && localModelState != .checking && embeddingState != .verifying
    }

    init(engine: LauncherEngine, defaults: UserDefaults?, locale: String? = nil) {
        self.engine = engine
        self.defaults = defaults
        scopePending = engine.hasPendingScope
        language = locale ?? defaults?.string(forKey: "language") ?? "system"
        semanticLanguage = defaults?.string(forKey: "semanticLanguage") == "en" ? "en" : "zh"
        scope = IndexScope(allow: defaults?.string(forKey: "allow") ?? "",
                           deny: defaults?.string(forKey: "deny") ?? "",
                           documents: defaults?.bool(forKey: "documents") ?? false)
    }

    func start() {
        if engine.hasDatabase {
            _ = engine.run(["status"]) { [weak self] response in
                guard let self, !self.closed else { return }
                if let report = self.report(from: response) {
                    self.publish(report)
                } else {
                    self.indexPhase = .unreadable
                    self.indexNotice = LauncherNotice(.status, response.diagnostic)
                }
                self.startWatcherIfReady()
            }
        } else {
            indexPhase = .needsIndex
        }
        _ = engine.run(["watch", "--help"]) { [weak self] response in
            guard let self, !self.closed else { return }
            self.watchSupported = response.succeeded
            self.watchReportsProgress = response.succeeded && String(decoding: response.output, as: UTF8.self).contains("--progress")
            self.watchState = response.succeeded ? (self.scopePending ? .paused : .needsSetup) : .unavailable
            self.startWatcherIfReady()
        }
    }

    func close() {
        closed = true
        debounce?.cancel()
        cancelModelCheck()
        engine.close()
        for process in [watcher, writer, semanticProcess, actionProcess].compactMap({ $0 }) where process.isRunning {
            process.terminate()
        }
    }

    func t(_ chinese: String, _ english: String) -> String { zh ? chinese : english }

    func title(for notice: LauncherNotice) -> String {
        switch notice.problem {
        case .status: return t("无法读取已有索引。你可以重新建立索引。", "The existing index could not be read. You can rebuild it.")
        case .indexing: return t("索引建立失败。请查看详情后重试。", "Indexing failed. Check the details and try again.")
        case .search: return t("搜索引擎暂时无法返回结果。请重试。", "The search engine could not return results. Try again.")
        case .semantic: return t("本机语义搜索失败。", "Local semantic search failed.")
        case .semanticNotIndexed: return t("请先在设置中为当前语言生成 BGE 语义索引。", "Build the BGE semantic index for the selected language in Settings first.")
        case .embeddings: return t("本机语义索引生成失败。已保存的片段可在再次开始时继续使用。",
                                   "Local semantic indexing failed. Saved chunks are kept for the next run.")
        case .embeddingNoProgress: return t("本批没有新增或跳过片段，已停止生成。已完成的进度已保存。",
                                           "Indexing stopped after a batch made no progress. Completed work is saved.")
        case .opening: return t("macOS 无法打开这个项目。", "macOS could not open this item.")
        case .scope: return t("索引范围中的路径必须以 / 开头。", "Index scope paths must start with /.")
        case .scopeState: return t("无法保存索引范围更新状态。请检查索引目录权限后重试。", "Could not save the scope update state. Check index directory permissions and try again.")
        case .watch: return t("自动更新已停止。你仍可搜索或手动更新。", "Automatic updates stopped. Search and manual updates are still available.")
        case .online: return t("此项目仅索引名称和路径，可使用「在 Finder 中显示」。", "Only the name and path were indexed. Use Show in Finder to locate this item.")
        case .stale: return t("此结果已变化或无法访问。请重新搜索。", "This result changed or became unavailable. Search again.")
        }
    }

    func modelDiagnostic(_ issue: LocalModelProblem) -> String {
        switch issue {
        case .unsupported: return t("当前搜索引擎不支持离线 BGE。", "This search engine does not support offline BGE.")
        case .runtime: return t("本机 BGE 运行环境缺失或不完整。请准备离线运行环境后重新检查。",
                                "The local BGE runtime is missing or incomplete. Prepare the offline runtime and check again.")
        case .worker: return t("此应用缺少 BGE 工作程序。请使用包含离线 BGE 的构建。",
                               "The BGE worker is missing from this app. Use a build that includes offline BGE.")
        case .profile: return t("当前语言的本机 BGE 模型文件缺失或校验失败。请准备对应的离线模型后重新检查。",
                                "The local BGE files for the selected language are missing or failed verification. Prepare the matching offline model and check again.")
        case .verification: return t("本机 BGE 校验失败。请检查离线运行环境和当前语言的模型文件。",
                                     "Local BGE verification failed. Check the offline runtime and model files for the selected language.")
        }
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        scheduleSearch(inputChanged: true)
    }

    func changeMode(_ value: SearchMode) {
        guard mode != value else { return }
        mode = value
        scheduleSearch(inputChanged: true)
    }

    func retrySearch() { scheduleSearch(inputChanged: true) }

    func clear() {
        query = ""
        scheduleSearch(inputChanged: true)
    }

    private func invalidateSearch() {
        revision &+= 1
        debounce?.cancel()
        engine.discardQueuedSearch()
        if semanticProcess?.isRunning == true { semanticProcess?.terminate() }
        semanticProcess = nil
        if actionProcess?.isRunning == true { actionProcess?.terminate() }
        actionProcess = nil
        semanticBusy = false
        showingRelatedExcerpts = false
        searching = false
        hits = []
        selection = nil
        searchNotice = nil
    }

    private func scheduleSearch(inputChanged: Bool = false) {
        if inputChanged { searchInputGeneration &+= 1 }
        invalidateSearch()
        searching = hasQuery && canSearch
        guard searching else { return }
        let current = revision
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self, self.revision == current else { return }
            let first = self.mode == .all ? SearchMode.name : self.mode
            self.search(first, revision: current)
        }
    }

    private func search(_ lane: SearchMode, revision: UInt64) {
        engine.search(query, mode: lane.rawValue) { [weak self] result in
            guard let self, self.revision == revision, !self.closed else { return }
            switch result {
            case .success(let hits):
                self.accept(hits, revision: revision) { [weak self] in
                    guard let self else { return }
                    if lane == .name && self.mode == .all {
                        self.search(.all, revision: revision)
                    } else {
                        self.searching = false
                    }
                }
            case .failure(let error):
                self.searchNotice = LauncherNotice(.search, error.detail)
                self.searching = false
            }
        }
    }

    private func accept(_ hits: [SearchHit], revision: UInt64, complete: @escaping () -> Void) {
        guard hits.contains(where: \.hasPreview) else {
            publishHits(hits)
            complete()
            return
        }
        // Bind each preview to the document snapshot that actually produced it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let available = hits.filter { hit in
                guard hit.hasPreview else { return true }
                guard let indexedStamp = hit.document_stamp else { return false }
                return hit.pathStamp() == indexedStamp
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.revision == revision else { return }
                self.publishHits(available)
                complete()
            }
        }
    }

    private func publishHits(_ hits: [SearchHit]) {
        self.hits = hits
        if !hits.contains(where: { $0.path == selection }) { selection = hits.first?.path }
    }

    func moveSelection(_ step: Int) {
        guard !hits.isEmpty else { return }
        guard let index = hits.firstIndex(where: { $0.path == selection }) else {
            selection = (step > 0 ? hits.first : hits.last)?.path
            return
        }
        selection = hits[min(max(index + step, 0), hits.count - 1)].path
    }

    var selectedHit: SearchHit? { hits.first { $0.path == selection } }

    func openingFailed() { searchNotice = LauncherNotice(.opening) }

    func resolve(_ hit: SearchHit, revealInFinder: Bool, complete: @escaping (URL) -> Void) {
        guard canSearch, hasQuery, hits.contains(hit), actionProcess == nil else { return }
        guard !hit.isSemanticCandidate || localModelState == .ready else { return }
        guard revealInFinder ? hit.isCloudReference : hit.isLocal else {
            if hit.isCloudReference { searchNotice = LauncherNotice(.online) }
            return
        }
        let current = revision
        let arguments = hit.isSemanticCandidate ? semanticArguments() :
            ["query", "--mode", mode.rawValue, "--limit", "60", "--", query]
        actionProcess = engine.run(arguments) { [weak self] response in
            guard let self, !self.closed, self.revision == current else { return }
            let fresh = try? JSONDecoder().decode([SearchHit].self, from: response.output)
            guard response.succeeded, fresh?.contains(hit) == true else {
                if hit.isSemanticCandidate { recordModelFailure(response) }
                self.rejectStaleResult()
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let stamp = hit.pathStamp()
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.revision == current else { return }
                    guard let stamp, !hit.hasPreview || hit.document_stamp == stamp else {
                        self.rejectStaleResult()
                        return
                    }
                    self.actionProcess = nil
                    complete(URL(fileURLWithPath: hit.path))
                }
            }
        }
    }

    private func rejectStaleResult() {
        invalidateSearch()
        searchNotice = LauncherNotice(.stale)
    }

    private func semanticArguments() -> [String] {
        ["query", "--mode", "semantic", "--bge", "--language", semanticLanguage, "--", query]
    }

    func semanticSearch() {
        guard canSearch, hasQuery, !semanticBusy, localModelState != .checking else { return }
        let requested = searchInputGeneration
        withVerifiedModel { [weak self] in
            guard let self, self.searchInputGeneration == requested, self.canSearch, self.hasQuery else { return }
            self.searchRelatedExcerpts()
        }
    }

    private func searchRelatedExcerpts() {
        invalidateSearch()
        let current = revision
        semanticBusy = true
        semanticProcess = engine.run(semanticArguments()) { [weak self] response in
            guard let self, self.revision == current, !self.closed else { return }
            self.semanticProcess = nil
            if response.succeeded, let hits = try? JSONDecoder().decode([SearchHit].self, from: response.output) {
                self.accept(hits.filter(\.isSemanticCandidate), revision: current) { [weak self] in
                    guard let self else { return }
                    self.showingRelatedExcerpts = true
                    self.semanticBusy = false
                }
            } else {
                self.recordModelFailure(response)
                let diagnostic = response.diagnostic.lowercased()
                let needsIndex = diagnostic.contains("no paragraph embeddings") ||
                    diagnostic.contains("build embeddings first")
                self.scheduleSearch()
                self.searchNotice = LauncherNotice(needsIndex ? .semanticNotIndexed : .semantic)
            }
        }
    }

    private func withVerifiedModel(_ action: @escaping () -> Void) {
        if localModelState == .ready { action() }
        else { verifyLocalModel { if $0 { action() } } }
    }

    func verifyLocalModel(then complete: ((Bool) -> Void)? = nil) {
        guard localModelState != .checking else { return }
        modelCheckGeneration &+= 1
        let current = modelCheckGeneration
        localModelState = .checking
        modelCheck = engine.run(["model-status", "--language", semanticLanguage, "--verify"]) { [weak self] response in
            guard let self, !self.closed, self.modelCheckGeneration == current else { return }
            self.modelCheck = nil
            let status = try? JSONDecoder().decode(LocalModelStatus.self, from: response.output)
            if response.succeeded, let status, status.available, status.verified {
                self.localModelState = .ready
                complete?(true)
            } else {
                let issue = LocalModelProblem.classify(status?.diagnostic ?? response.diagnostic) ?? .verification
                self.localModelState = .unavailable(issue)
                if self.semanticBusy || self.showingRelatedExcerpts { self.scheduleSearch() }
                complete?(false)
            }
        }
    }

    private func cancelModelCheck() {
        modelCheckGeneration &+= 1
        if modelCheck?.isRunning == true { modelCheck?.terminate() }
        modelCheck = nil
    }

    private func recordModelFailure(_ response: EngineResponse) {
        if let issue = LocalModelProblem.classify(response.diagnostic) {
            cancelModelCheck()
            localModelState = .unavailable(issue)
            if embeddingState == .verifying { finishEmbeddings(.idle) }
        }
    }

    func buildIndex() {
        pauseEmbeddings()
        guard indexWork == nil, indexPhase != .checking else { return }
        let requested = scope
        firstNamesReady = false
        scopePending = true
        searchInputGeneration &+= 1
        invalidateSearch()
        engine.close()
        indexNotice = nil
        do {
            try engine.beginScopeUpdate()
        } catch {
            indexNotice = LauncherNotice(.scopeState, error.localizedDescription)
            withWatcherStopped {}
            return
        }
        guard requested.hasAbsolutePaths else {
            indexNotice = LauncherNotice(.scope)
            withWatcherStopped {}
            return
        }
        embeddingState = .idle
        embeddingBatch = nil
        embeddingNotice = nil
        let shouldStageDocuments = indexPhase != .ready && requested.documents
        var first = requested
        if shouldStageDocuments { first.documents = false }
        indexWork = first.documents ? .documents : .names
        withWatcherStopped { [weak self] in
            self?.scan(first, then: shouldStageDocuments ? requested : nil)
        }
    }

    private func scan(_ scope: IndexScope, then next: IndexScope?) {
        scanGeneration &+= 1
        let generation = scanGeneration
        scanProgress = nil
        let progressOption = indexReportsProgress ? ["--progress"] : []
        writer = engine.run(engine.indexArguments(scope: scope) + progressOption, onProgress: { [weak self] progress in
            guard let self, !self.closed, self.scanGeneration == generation else { return }
            if self.scanProgress != progress { self.scanProgress = progress }
        }) { [weak self] response in
            guard let self, !self.closed, self.scanGeneration == generation else { return }
            self.scanGeneration &+= 1
            self.writer = nil
            let didReport = self.scanProgress != nil
            self.scanProgress = nil
            if !response.succeeded, !didReport, self.indexReportsProgress,
               response.diagnostic.contains("unexpected argument '--progress'") {
                self.indexReportsProgress = false
                self.scan(scope, then: next)
                return
            }
            guard let report = self.report(from: response) else {
                self.firstNamesReady = false
                self.invalidateSearch()
                self.indexNotice = LauncherNotice(.indexing, response.diagnostic)
                self.indexWork = nil
                return
            }
            if let next {
                // The metadata pass has committed the requested path scope.
                self.firstNamesReady = true
                self.publish(report)
                self.indexWork = .documents
                self.scan(next, then: nil)
                return
            }
            do {
                try self.engine.finishScopeUpdate()
                self.scopePending = false
            } catch {
                self.indexNotice = LauncherNotice(.scopeState, error.localizedDescription)
            }
            self.firstNamesReady = false
            self.indexWork = nil
            self.publish(report)
            self.startWatcherIfReady()
        }
    }

    func buildEmbeddings() {
        guard canBuildEmbeddings else { return }
        embeddingNotice = nil
        if embeddingState != .paused { embeddingBatch = nil }
        if localModelState == .ready {
            startEmbeddings()
        } else {
            embeddingState = .verifying
            verifyLocalModel { [weak self] verified in
                guard let self, self.embeddingState == .verifying else { return }
                self.embeddingState = .idle
                if verified, self.canBuildEmbeddings { self.startEmbeddings() }
            }
        }
    }

    func pauseEmbeddings() {
        switch embeddingState {
        case .verifying:
            cancelModelCheck()
            localModelState = .unchecked
            embeddingState = .paused
        case .running:
            embeddingState = .pausing
        case .idle, .pausing, .paused, .finished:
            break
        }
    }

    private func startEmbeddings() {
        embeddingState = .running
        indexWork = .embeddings
        embedNextBatch(language: semanticLanguage)
    }

    private func embedNextBatch(language: String) {
        let arguments = ["embed", "--bge", "--language", language, "--max", "32"]
        writer = engine.run(arguments) { [weak self] response in
            guard let self, !self.closed else { return }
            self.writer = nil
            guard self.semanticLanguage == language else {
                self.finishEmbeddings(.idle)
                return
            }
            guard response.succeeded, let batch = try? JSONDecoder().decode(EmbeddingBatch.self, from: response.output) else {
                self.recordModelFailure(response)
                self.embeddingNotice = LauncherNotice(.embeddings)
                self.finishEmbeddings(.idle)
                return
            }
            self.embeddingBatch = batch
            if !batch.has_more {
                self.finishEmbeddings(.finished)
            } else if batch.new_embeddings == 0 && batch.skipped_chunks == 0 {
                self.embeddingNotice = LauncherNotice(.embeddingNoProgress)
                self.finishEmbeddings(.paused)
            } else if self.embeddingState == .running {
                self.embedNextBatch(language: language)
            } else {
                self.finishEmbeddings(.paused)
            }
        }
    }

    private func finishEmbeddings(_ state: EmbeddingState) {
        indexWork = nil
        embeddingState = state
    }

    private func report(from response: EngineResponse) -> IndexReport? {
        guard response.succeeded else { return nil }
        return try? JSONDecoder().decode(IndexReport.self, from: response.output)
    }

    private func publish(_ report: IndexReport) {
        indexPhase = .ready
        indexReport = report
        scheduleSearch()
    }

    private func startWatcherIfReady() {
        guard watchSupported == true, indexPhase == .ready, !scopePending,
              watcher == nil, !closed else { return }
        watchState = .starting
        watchNotice = nil
        watchGeneration &+= 1
        let generation = watchGeneration
        let arguments = ["watch"] + (watchReportsProgress ? ["--progress"] : [])
        watcher = engine.run(arguments, onLine: { [weak self] line in
            guard let self, self.watchGeneration == generation, !self.closed else { return }
            self.watchEvent(line)
        }, onProgress: { [weak self] progress in
            guard let self, !self.closed, self.watchGeneration == generation, !self.stoppingWatcher else { return }
            let active = progress.phase == "done" ? nil : progress
            if self.watchProgress != active { self.watchProgress = active }
        }) { [weak self] response in
            guard let self, !self.closed, self.watchGeneration == generation else { return }
            self.watchGeneration &+= 1
            self.watcher = nil
            self.watchProgress = nil
            if self.stoppingWatcher {
                self.stoppingWatcher = false
                let next = self.afterWatcherStops
                self.afterWatcherStops = nil
                next?()
            } else if response.diagnostic.contains("predates saved scope settings") ||
                        response.diagnostic.contains("no saved scope;") {
                self.watchState = .needsSetup
            } else {
                self.watchState = .failed
                self.watchNotice = LauncherNotice(.watch, response.diagnostic)
            }
        }
    }

    private func watchEvent(_ line: Data) {
        guard !stoppingWatcher, !scopePending,
              let notice = try? JSONDecoder().decode(WatchEvent.self, from: line) else { return }
        if notice.event == .ready { watchState = .running }
        watchProgress = nil
        scheduleSearch()
    }

    private func withWatcherStopped(_ next: @escaping () -> Void) {
        if watchSupported == true { watchState = .paused }
        watchProgress = nil
        guard let watcher else { next(); return }
        stoppingWatcher = true
        afterWatcherStops = next
        if watcher.isRunning { watcher.terminate() }
    }
}
