import AppKit
import Combine

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
    case unchecked, available, checking, ready, unavailable(LocalModelProblem)
}

enum LocalModelProblem: Equatable {
    case unsupported, runtime, assets, verification

    // Classify failures without presenting local paths or account names.
    static func classify(_ diagnostic: String) -> Self? {
        let text = diagnostic.lowercased()
        if text.contains("unrecognized subcommand") || text.contains("requires apple silicon") { return .unsupported }
        if text.contains("resource directory is missing") || text.contains("llama-server") ||
            text.contains("/runtime/") || text.contains("runtime did not become healthy") { return .runtime }
        if text.contains("gemma asset") || text.contains("resource directory must") { return .assets }
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

struct FileDiagnosis: Decodable {
    let name: String
    let text: String
    let semantic: String
}

enum FileDiagnosisState {
    case idle, checking(String), result(String, FileDiagnosis), failed(String)
}

enum LauncherProblem {
    case status, indexing, search, embeddings, embeddingNoProgress, opening, scope, scopeState, watch, online, stale
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
    @Published private(set) var searching = false
    @Published private(set) var semanticBusy = false
    @Published private(set) var localModelState = LocalModelState.unchecked
    @Published private(set) var gemmaCoverage: GemmaCoverage?
    @Published private(set) var searchNotice: LauncherNotice?
    @Published private(set) var indexPhase = IndexPhase.checking
    @Published private(set) var indexWork: IndexWork?
    @Published private(set) var indexReport: IndexReport?
    @Published private(set) var savedScope: IndexScope?
    @Published private(set) var indexNotice: LauncherNotice?
    @Published private(set) var scanProgress: IndexProgress?
    @Published private(set) var watchProgress: IndexProgress?
    @Published private(set) var scopePending: Bool
    @Published private(set) var embeddingState = EmbeddingState.idle
    @Published private(set) var embeddingBatch: EmbeddingBatch?
    @Published private(set) var embeddingNotice: LauncherNotice?
    @Published private(set) var watchState = WatchState.checking
    @Published private(set) var watchNotice: LauncherNotice?
    @Published private(set) var fileDiagnosis = FileDiagnosisState.idle
    @Published var hotKey: HotKey?
    @Published var hotKeyIssue: HotKeyIssue?
    @Published var language: String { didSet { defaults?.set(language, forKey: "language") } }
    @Published var scope: IndexScope {
        didSet {
            guard scope != oldValue else { return }
            pauseEmbeddings()
            defaults?.set(scope.roots, forKey: "rootsPaths")
            defaults?.set(scope.allow, forKey: "allowPaths")
            defaults?.set(scope.deny, forKey: "denyPaths")
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
    private var resultsRevision: UInt64?
    private var rejectedPaths = Set<String>()
    private var presentedQuery = ""
    private var directHits: [SearchHit] = []
    private var coverageUpdate: Task<Void, Never>?
    private var coverageRead: Process?
    private var coverageGeneration: UInt64 = 0
    private var automaticBuildAttempted = false
    private var modelInspection: Process?
    private var diagnosisProcess: Process?
    private var diagnosisGeneration: UInt64 = 0
    private var debounce: Task<Void, Never>?
    private var semanticDebounce: Task<Void, Never>?
    private var firstNamesReady = false
    // An existing index may contain paths hidden by permission changes while Lumen was closed.
    private var scopeTrustedForLookup = false
    private var watchGeneration: UInt64 = 0
    private var watcher: Process?
    private var afterWatcherStops: (() -> Void)?
    private var stoppingWatcher = false
    private var writer: Process?
    private var textProcess: Process?
    private var relatedRevision: UInt64?
    private var modelCheck: Process?
    private var modelCheckGeneration: UInt64 = 0
    private var actionProcess: Process?
    private var actionIntent: UInt64 = 0
    private var closed = false

    var zh: Bool {
        language == "zh" || (language == "system" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    }

    var settingsScope: IndexScope { (!scopePending ? savedScope : nil) ?? scope }
    var canApplyScope: Bool { !closed && indexWork == nil && indexPhase != .checking }
    var needsScopeSetup: Bool {
        scopePending || indexPhase == .needsIndex || indexPhase == .unreadable || watchState == .needsSetup
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSearch: Bool { indexPhase == .ready && (firstNamesReady || (!scopePending && scopeTrustedForLookup)) }
    var isIndexing: Bool { indexWork == .names || indexWork == .documents }
    var activeProgress: IndexProgress? { isIndexing ? scanProgress : watchProgress }
    var activityBusy: Bool { indexWork != nil || watchState == .starting || watchProgress != nil }
    var relatedExcerptsLabel: String { t("相关原文", "Related Excerpts") }
    var canBuildEmbeddings: Bool {
        canSearch && !scopePending && indexWork == nil && localModelState != .checking && embeddingState != .verifying &&
            gemmaCoverage?.documents_enabled == true && gemmaCoverage?.pending == true && gemmaCoverage?.limited == false
    }

    init(engine: LauncherEngine, defaults: UserDefaults?, locale: String? = nil) {
        self.engine = engine
        self.defaults = defaults
        scopePending = engine.hasPendingScope
        language = locale ?? defaults?.string(forKey: "language") ?? "system"
        scope = IndexScope(roots: IndexScope.storedPaths("roots", in: defaults),
                           allow: IndexScope.storedPaths("allow", in: defaults),
                           deny: IndexScope.storedPaths("deny", in: defaults),
                           documents: defaults?.bool(forKey: "documents") ?? false)
    }

    func start() {
        inspectLocalResources()
        if engine.hasDatabase {
            _ = engine.run(["status", "--include-scope"]) { [weak self] response in
                guard let self, !self.closed else { return }
                if let report = self.report(from: response) {
                    self.publish(report)
                    self.acceptCoverage(from: report)
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
        semanticDebounce?.cancel()
        cancelCoverageRead()
        cancelModelCheck()
        clearFileDiagnosis()
        if modelInspection?.isRunning == true { modelInspection?.terminate() }
        engine.close()
        for process in [watcher, writer, textProcess, actionProcess].compactMap({ $0 }) where process.isRunning {
            process.terminate()
        }
    }

    func t(_ chinese: String, _ english: String) -> String { zh ? chinese : english }

    func title(for notice: LauncherNotice) -> String {
        switch notice.problem {
        case .status: return t("无法读取已有索引。你可以重新建立索引。", "The existing index could not be read. You can rebuild it.")
        case .indexing: return t("索引建立失败。请查看详情后重试。", "Indexing failed. Check the details and try again.")
        case .search: return t("搜索引擎暂时无法返回结果。请重试。", "The search engine could not return results. Try again.")
        case .embeddings: return t("本机语义索引生成失败。已保存的片段可在再次开始时继续使用。",
                                   "Local semantic indexing failed. Saved chunks are kept for the next run.")
        case .embeddingNoProgress: return t("本批没有新增或跳过片段，已停止生成。已完成的进度已保存。",
                                           "Indexing stopped after a batch made no progress. Completed work is saved.")
        case .opening: return t("macOS 无法打开这个项目。", "macOS could not open this item.")
        case .scope: return t("索引范围中的路径必须以 / 开头。", "Index scope paths must start with /.")
        case .scopeState: return t("无法保存索引范围更新状态。请检查索引目录权限后重试。", "Could not save the scope update state. Check index directory permissions and try again.")
        case .watch: return canSearch
            ? t("文件监听已停止，仍可搜索已验证的索引。", "File watching stopped. You can still search the verified index.")
            : t("未能核对现有索引的访问权限。", "Lumen could not verify access to the saved index.")
        case .online: return t("此项目仅索引名称和路径，可使用「在 Finder 中显示」。", "Only the name and path were indexed. Use Show in Finder to locate this item.")
        case .stale: return t("此结果已变化或无法访问。请重新搜索。", "This result changed or became unavailable. Search again.")
        }
    }

    func modelDiagnostic(_ issue: LocalModelProblem) -> String {
        switch issue {
        case .unsupported: return t("当前设备或搜索引擎不支持本机 EmbeddingGemma 2。",
                                     "This device or search engine does not support local EmbeddingGemma 2.")
        case .runtime: return t("本机 Gemma 运行环境缺失或无法启动。准备离线资源后可重试。",
                                 "The local Gemma runtime is missing or cannot start. Prepare the offline resources and try again.")
        case .assets: return t("本机 Gemma 模型文件缺失或校验失败。准备离线模型后可重试。",
                                "Local Gemma model files are missing or failed verification. Prepare the offline model and try again.")
        case .verification: return t("本机 Gemma 校验失败。请检查离线模型和运行环境。",
                                     "Local Gemma verification failed. Check the offline model and runtime.")
        }
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        scheduleSearch()
    }

    func retrySearch() { scheduleSearch() }

    func clear() {
        query = ""
        scheduleSearch(clearRows: true)
    }

    private func invalidateSearch(clearRows: Bool = true, keepAction: Bool = false) {
        revision &+= 1
        rejectedPaths.removeAll()
        debounce?.cancel()
        cancelRelatedExcerpts()
        engine.discardQueuedSearch()
        if textProcess?.isRunning == true { textProcess?.terminate() }
        textProcess = nil
        if !keepAction {
            actionIntent &+= 1
            if actionProcess?.isRunning == true { actionProcess?.terminate() }
            actionProcess = nil
        }
        searching = false
        if clearRows {
            presentedQuery = ""
            directHits = []
            publishHits([])
        }
        searchNotice = nil
    }

    private func scheduleSearch(clearRows: Bool = false, keepAction: Bool = false) {
        let shouldSearch = hasQuery && canSearch
        // Keep the result surface intact while a replacement is pending. Old
        // rows are visual only until the current revision has been validated.
        invalidateSearch(clearRows: clearRows || !shouldSearch, keepAction: keepAction && shouldSearch)
        guard shouldSearch else { return }
        searching = true
        let current = revision
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self, self.revision == current else { return }
            self.search(revision: current)
        }
    }

    private func search(revision: UInt64) {
        var names: Result<[SearchHit], SearchFailure>?
        var text: Result<[SearchHit], SearchFailure>?
        var delivery = 0

        let publish = { [weak self] (allowPartial: Bool) in
            guard let self, self.revision == revision, !self.closed, let names, allowPartial || text != nil else { return }
            let complete = text != nil
            let nameHits = (try? names.get()) ?? []
            guard complete || !nameHits.isEmpty else { return }
            delivery += 1
            let snapshot = delivery
            let textHits = (try? text?.get()) ?? []
            let strongNames = nameHits.filter { $0.matched_by != "path" }
            let weakPaths = nameHits.filter { $0.matched_by == "path" }
            var seen = Set<String>()
            let lexical = Array((strongNames + textHits + weakPaths).filter { seen.insert($0.path).inserted }.prefix(60))
            let retained = self.presentedQuery == self.query && self.localModelState == .ready &&
                self.shouldFindRelatedExcerpts(directCount: lexical.count)
                ? self.hits.filter(\.isSemanticCandidate) : []
            self.validatePreviews(lexical + retained, revision: revision) { [weak self] available in
                guard let self, delivery == snapshot else { return }
                self.presentedQuery = self.query
                self.directHits = available.filter { !$0.isSemanticCandidate }
                self.resultsRevision = revision
                self.publishWithRelated(available.filter(\.isSemanticCandidate))
                if complete {
                    self.searching = false
                    if case .failure(let error) = names, case .failure? = text {
                        self.searchNotice = LauncherNotice(.search, error.detail)
                    }
                    self.queueRelatedExcerpts()
                }
            }
        }

        // Only the name lane needs the engine's persistent in-memory name index.
        engine.search(query, mode: "name") { [weak self] result in
            guard self?.revision == revision else { return }
            names = result
            publish(false)
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ignore single characters: the engine's short-text fallback scans all document bodies.
        if term.count < 2 {
            text = .success([])
            publish(false)
            return
        }
        textProcess = engine.run(["query", "--mode", "text", "--limit", "24", "--", query]) { [weak self] response in
            guard let self, self.revision == revision, !self.closed else { return }
            self.textProcess = nil
            if response.succeeded, let hits = try? JSONDecoder().decode([SearchHit].self, from: response.output) {
                text = .success(hits)
            } else {
                text = .failure(SearchFailure(response.diagnostic))
            }
            publish(false)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard self?.revision == revision, text == nil else { return }
            publish(true)
        }
    }

    private func validatePreviews(_ hits: [SearchHit], revision: UInt64, complete: @escaping ([SearchHit]) -> Void) {
        guard hits.contains(where: \.hasPreview) else {
            complete(hits)
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
                complete(available)
            }
        }
    }

    private func publishWithRelated(_ candidates: [SearchHit]) {
        var seen = Set(directHits.map(\.path))
        let related = candidates.filter { seen.insert($0.path).inserted }.prefix(3)
        publishHits(directHits + related)
    }

    private func publishHits(_ hits: [SearchHit]) {
        let visible = rejectedPaths.isEmpty ? hits : hits.filter { !rejectedPaths.contains($0.path) }
        if self.hits != visible { self.hits = visible }
        if !visible.contains(where: { $0.path == selection }), selection != visible.first?.path {
            selection = visible.first?.path
        }
    }

    func moveSelection(_ step: Int) {
        guard !hits.isEmpty else { return }
        guard let index = hits.firstIndex(where: { $0.path == selection }) else {
            selection = (step > 0 ? hits.first : hits.last)?.path
            return
        }
        selection = hits[min(max(index + step, 0), hits.count - 1)].path
    }

    var selectedHit: SearchHit? {
        guard resultsRevision == revision else { return nil }
        return hits.first { $0.path == selection }
    }

    func openingFailed() { searchNotice = LauncherNotice(.opening) }

    func resolve(_ hit: SearchHit, revealInFinder: Bool, complete: @escaping (URL) -> Void) {
        guard canSearch, resultsRevision == revision, hits.contains(hit), actionProcess == nil else { return }
        guard !hit.isSemanticCandidate || localModelState == .ready else { return }
        guard hit.isLocal || (revealInFinder && hit.isCloudReference) else {
            if hit.isCloudReference { searchNotice = LauncherNotice(.online) }
            return
        }
        revalidate(hit, retry: true, complete: complete)
    }

    private func revalidate(_ hit: SearchHit, retry: Bool, complete: @escaping (URL) -> Void) {
        let current = revision
        let intent = actionIntent
        let arguments = hit.isSemanticCandidate ? semanticArguments() :
            ["query", "--mode", hit.matched_by == "text" ? "text" : "name",
             "--limit", hit.matched_by == "text" ? "24" : "60", "--", query]
        let permitsDelivery = { [weak self] in
            guard let self, !self.closed, self.actionIntent == intent, self.canSearch else { return false }
            if self.revision == current { return true }
            // A watcher can refresh unrelated files while an explicit action is in flight.
            // Recheck its original source once after the new index revision.
            self.actionProcess = nil
            if retry, self.hits.contains(hit) {
                self.revalidate(hit, retry: false, complete: complete)
            }
            return false
        }
        actionProcess = engine.run(arguments) { [weak self] response in
            guard let self, permitsDelivery() else { return }
            let fresh = try? JSONDecoder().decode([SearchHit].self, from: response.output)
            guard response.succeeded, fresh?.contains(hit) == true else {
                if hit.isSemanticCandidate { recordModelFailure(response.diagnostic) }
                self.rejectStaleResult(hit)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let stamp = hit.pathStamp()
                DispatchQueue.main.async { [weak self] in
                    guard let self, permitsDelivery() else { return }
                    guard let stamp, !hit.hasPreview || hit.document_stamp == stamp else {
                        self.rejectStaleResult(hit)
                        return
                    }
                    self.actionProcess = nil
                    complete(URL(fileURLWithPath: hit.path))
                }
            }
        }
    }

    private func rejectStaleResult(_ hit: SearchHit) {
        actionProcess = nil
        rejectedPaths.insert(hit.path)
        if hit.isSemanticCandidate {
            cancelRelatedExcerpts()
        } else {
            directHits.removeAll { $0.path == hit.path }
        }
        publishHits(hits.filter { $0.path != hit.path })
        searchNotice = LauncherNotice(.stale)
    }

    private func semanticArguments() -> [String] {
        ["query", "--mode", "semantic", "--gemma", "--limit", "12"] + engine.gemmaOptions + ["--", query]
    }

    private func shouldFindRelatedExcerpts(directCount: Int) -> Bool {
        guard gemmaCoverage?.hasResults == true, !scopePending, directCount < 8 else { return false }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 512, !text.contains("/"), !text.contains("\\"),
              !text.split(whereSeparator: \.isWhitespace).contains(where: {
                  $0.range(of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
              }) else { return false }
        let words = text.split { !$0.isLetter && !$0.isNumber }
        let han = text.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }.count
        return han >= 6 || (words.count >= 2 && text.count >= 10)
    }

    private func queueRelatedExcerpts() {
        guard resultsRevision == revision, relatedRevision != revision,
              shouldFindRelatedExcerpts(directCount: directHits.count) else { return }
        if case .unavailable = localModelState { return }
        semanticBusy = true
        if localModelState == .checking { return }
        let current = revision
        semanticDebounce?.cancel()
        semanticDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, let self, !self.closed, self.revision == current else { return }
            if self.localModelState == .unchecked || self.localModelState == .available {
                self.verifyLocalModel()
            } else if self.localModelState == .ready {
                self.searchRelatedExcerpts(revision: current)
            } else if self.localModelState != .checking {
                self.semanticBusy = false
            }
        }
    }

    private func cancelRelatedExcerpts() {
        semanticDebounce?.cancel()
        semanticDebounce = nil
        engine.discardQueuedSemantic()
        semanticBusy = false
        relatedRevision = nil
    }

    private func searchRelatedExcerpts(revision: UInt64) {
        guard gemmaCoverage?.hasResults == true else {
            semanticBusy = false
            return
        }
        relatedRevision = revision
        semanticBusy = true
        engine.searchSemantic(query) { [weak self] reply in
            self?.receiveRelated(reply, revision: revision)
        }
    }

    private func receiveRelated(_ reply: Result<[SearchHit], SearchFailure>, revision: UInt64) {
        guard !closed, self.revision == revision, relatedRevision == revision else { return }
        switch reply {
        case .success(let hits):
            validatePreviews(hits.filter(\.isSemanticCandidate), revision: revision) { [weak self] available in
                guard let self, self.relatedRevision == revision else { return }
                self.publishWithRelated(available)
                self.semanticBusy = false
            }
        case .failure(let error):
            recordModelFailure(error.detail)
            publishWithRelated([])
            semanticBusy = false
            refreshCoverage()
        }
    }

    private func inspectLocalResources() {
        modelInspection = engine.run(["model-status", "--gemma"] + engine.gemmaOptions) { [weak self] response in
            guard let self, !self.closed, self.localModelState == .unchecked else { return }
            let status = try? JSONDecoder().decode(LocalModelStatus.self, from: response.output)
            self.localModelState = response.succeeded && status?.available == true
                ? .available : .unavailable(LocalModelProblem.classify(status?.diagnostic ?? response.diagnostic) ?? .verification)
            if self.localModelState == .available { self.queueRelatedExcerpts() }
            else { self.semanticBusy = false }
        }
    }

    func verifyLocalModel(then complete: ((Bool) -> Void)? = nil) {
        guard localModelState != .checking else { return }
        modelCheckGeneration &+= 1
        let current = modelCheckGeneration
        localModelState = .checking
        modelCheck = engine.run(["model-status", "--gemma", "--verify"] + engine.gemmaOptions) { [weak self] response in
            guard let self, !self.closed, self.modelCheckGeneration == current else { return }
            self.modelCheck = nil
            let status = try? JSONDecoder().decode(LocalModelStatus.self, from: response.output)
            if response.succeeded, let status, status.available, status.verified {
                self.localModelState = .ready
                complete?(true)
                self.queueRelatedExcerpts()
            } else {
                let issue = LocalModelProblem.classify(status?.diagnostic ?? response.diagnostic) ?? .verification
                self.localModelState = .unavailable(issue)
                self.cancelRelatedExcerpts()
                if self.hits.contains(where: \.isSemanticCandidate) { self.publishWithRelated([]) }
                complete?(false)
            }
        }
    }

    private func cancelModelCheck() {
        modelCheckGeneration &+= 1
        if modelCheck?.isRunning == true { modelCheck?.terminate() }
        modelCheck = nil
    }

    private func recordModelFailure(_ diagnostic: String) {
        if let issue = LocalModelProblem.classify(diagnostic) {
            engine.closeSemantic()
            cancelModelCheck()
            localModelState = .unavailable(issue)
            if embeddingState == .verifying { finishEmbeddings(.idle) }
        }
    }

    func diagnoseFile(_ file: URL) {
        guard !closed, !scopePending, file.isFileURL else { return }
        clearFileDiagnosis()
        let generation = diagnosisGeneration
        let name = file.lastPathComponent
        fileDiagnosis = .checking(name)
        diagnosisProcess = engine.run(["diagnose", "--", file.path]) { [weak self] response in
            guard let self, !self.closed, !self.scopePending, self.diagnosisGeneration == generation else { return }
            self.diagnosisProcess = nil
            if response.succeeded, let report = try? JSONDecoder().decode(FileDiagnosis.self, from: response.output) {
                self.fileDiagnosis = .result(name, report)
            } else {
                self.fileDiagnosis = .failed(name)
            }
        }
    }

    func clearFileDiagnosis() {
        diagnosisGeneration &+= 1
        if diagnosisProcess?.isRunning == true { diagnosisProcess?.terminate() }
        diagnosisProcess = nil
        if case .idle = fileDiagnosis { return }
        fileDiagnosis = .idle
    }

    func applyScope(_ requested: IndexScope) {
        guard canApplyScope else { return }
        scope = requested
        buildIndex()
    }

    func rebuildSavedIndex() {
        guard let savedScope, indexPhase == .ready, !scopePending else { return }
        applyScope(savedScope)
    }

    func buildIndex() {
        pauseEmbeddings()
        guard canApplyScope else { return }
        let requested = scope
        scopeTrustedForLookup = false
        firstNamesReady = false
        scopePending = true
        clearFileDiagnosis()
        cancelCoverageRead()
        gemmaCoverage = nil
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
                self.savedScope = scope
            } catch {
                self.indexNotice = LauncherNotice(.scopeState, error.localizedDescription)
            }
            self.firstNamesReady = false
            self.scopeTrustedForLookup = !self.scopePending
            self.indexWork = nil
            self.publish(report)
            self.startWatcherIfReady()
            self.refreshCoverage()
        }
    }

    func buildEmbeddings() {
        guard canBuildEmbeddings else { return }
        defaults?.set(true, forKey: "gemmaIndexingEnabled")
        defaults?.set(false, forKey: "gemmaIndexingPaused")
        automaticBuildAttempted = true
        prepareEmbeddings()
    }

    private func prepareEmbeddings() {
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

    func pauseEmbeddings(userInitiated: Bool = false) {
        if userInitiated { defaults?.set(true, forKey: "gemmaIndexingPaused") }
        switch embeddingState {
        case .verifying:
            cancelModelCheck()
            localModelState = .available
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
        embedNextBatch()
    }

    private func embedNextBatch() {
        let arguments = ["embed", "--gemma", "--max", "32"] + engine.gemmaOptions
        writer = engine.run(arguments) { [weak self] response in
            guard let self, !self.closed else { return }
            self.writer = nil
            guard response.succeeded, let batch = try? JSONDecoder().decode(EmbeddingBatch.self, from: response.output) else {
                self.recordModelFailure(response.diagnostic)
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
                if self.gemmaCoverage?.hasResults != true { self.refreshCoverage() }
                self.embedNextBatch()
            } else {
                self.finishEmbeddings(.paused)
            }
        }
    }

    private func finishEmbeddings(_ state: EmbeddingState) {
        indexWork = nil
        embeddingState = state
        refreshCoverage()
    }

    private func acceptCoverage(from report: IndexReport) {
        guard !scopePending else { return }
        if savedScope != report.scope { savedScope = report.scope }
        if indexReport != report { indexReport = report }
        let previous = gemmaCoverage
        if previous != report.gemma {
            gemmaCoverage = report.gemma
            if report.gemma?.hasResults != true, previous?.hasResults == true {
                cancelRelatedExcerpts()
                engine.closeSemantic()
                if hits.contains(where: \.isSemanticCandidate) { publishWithRelated([]) }
            } else if report.gemma?.hasResults == true, previous?.hasResults != true {
                queueRelatedExcerpts()
            }
        }
        // Existing BGE vectors are evidence an older user explicitly started semantic indexing.
        // The saved scope in the database decides whether documents are eligible.
        if !automaticBuildAttempted, embeddingState == .idle, canBuildEmbeddings,
           defaults?.bool(forKey: "gemmaIndexingPaused") != true,
           (report.embedded_chunks ?? 0) > 0 || defaults?.bool(forKey: "gemmaIndexingEnabled") == true {
            automaticBuildAttempted = true
            prepareEmbeddings()
        }
    }

    private func refreshCoverage(after delay: Duration = .zero) {
        guard !scopePending, !closed, coverageUpdate == nil else { return }
        coverageUpdate = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.coverageUpdate = nil
            if self.coverageRead?.isRunning == true {
                self.refreshCoverage(after: .milliseconds(250))
                return
            }
            self.coverageGeneration &+= 1
            let generation = self.coverageGeneration
            self.coverageRead = self.engine.run(["status", "--include-scope"]) { [weak self] response in
                guard let self, self.coverageGeneration == generation, !self.closed else { return }
                self.coverageRead = nil
                if let report = self.report(from: response) { self.acceptCoverage(from: report) }
            }
        }
    }

    private func cancelCoverageRead() {
        coverageUpdate?.cancel()
        coverageUpdate = nil
        coverageGeneration &+= 1
        if coverageRead?.isRunning == true { coverageRead?.terminate() }
        coverageRead = nil
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
        let arguments = ["watch", "--bundled-pdf-helper"] + (watchReportsProgress ? ["--progress"] : [])
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
        if notice.event == .ready {
            scopeTrustedForLookup = true
            watchState = .running
        }
        watchProgress = nil
        refreshCoverage(after: .milliseconds(400))
        scheduleSearch(keepAction: true)
        let current = revision
        // Discard previews invalidated by the watch event even if a new query is still in flight.
        let previous = hits
        validatePreviews(previous, revision: current) { [weak self] available in
            guard let self, self.resultsRevision != current, available != previous else { return }
            self.publishHits(available)
        }
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
