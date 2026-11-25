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

private struct HitValidation: Decodable {
    let valid: Bool
}

private struct WatchEvent: Decodable {
    enum Kind: String, Decodable { case cached, ready, updated }
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
    case status, indexing, search, embeddings, embeddingNoProgress, opening, scope, scopeState, watch, online, stale, preview, copiedName, copiedPath
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
    private var imageProjector: URL?
    var isImageSearch: Bool { imageProjector != nil }
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var launchMatches: [ActionMatch] = []
    @Published private(set) var calculation: CalculationResult?
    let shortcuts: ShortcutLibrary
    private var shortcutChanges: AnyCancellable?
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
    @Published private(set) var contentCoverage: ContentCoverage?
    @Published private(set) var contentPaused = false
    @Published private(set) var contentRunning = false
    @Published private(set) var contentFailed = false
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
            defaults?.set(scope.content_roots, forKey: "contentRootPaths")
        }
    }

    private var contentWriter: Process?
    private let engine: LauncherEngine
    private let defaults: UserDefaults?
    private var watchSupported: Bool?
    private var watchReportsProgress = false
    private var watchSupportsCachedStart = false
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
    private var textDebounce: Task<Void, Never>?
    private var nameBypassDelay: Task<Void, Never>?
    private var nameBypassProcess: Process?
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
    private var supportsTargetedValidation = true
    private var closed = false
    private let builtInActions: [LaunchAction]
    private var appActions: [LaunchAction] = []
    private var loadingApplications = false
    private var applicationsLoadedAt: ContinuousClock.Instant?

    var zh: Bool {
        language == "zh" || (language == "system" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    }

    var settingsScope: IndexScope { (!scopePending ? savedScope : nil) ?? scope }
    var canApplyScope: Bool { !closed && !contentRunning && indexWork == nil && indexPhase != .checking }
    var needsScopeSetup: Bool {
        scopePending || indexPhase == .needsIndex || indexPhase == .unreadable || watchState == .needsSetup
    }

    var showsResults: Bool { hasQuery ? (canSearch || !visibleResults.isEmpty) : !shortcuts.home.isEmpty }

    var installedActions: [LaunchAction] {
        appActions.sorted { $0.title(chinese: zh).localizedStandardCompare($1.title(chinese: zh)) == .orderedAscending }
    }

    func application(for shortcut: SavedShortcut) -> LaunchAction? {
        guard case .application(let id) = shortcut.target else { return nil }
        return appActions.first { $0.id == id }
    }

    var visibleResults: [LauncherResult] {
        guard hasQuery else { return shortcuts.home.map(LauncherResult.shortcut) }
        if isImageSearch { return hits.map(LauncherResult.file) }
        let nativeScores = Dictionary(uniqueKeysWithValues: launchMatches.map { ($0.action.id, $0.score) })
        let shortcuts = shortcuts.matches(query).filter { match in
            guard case .application(let id) = match.record.target else { return true }
            return match.score >= (nativeScores[id] ?? 0)
        }
        let linkedApps = Set(shortcuts.compactMap { match -> String? in
            if case .application(let id) = match.record.target { return id }
            return nil
        })
        let native = launchMatches.filter { !linkedApps.contains($0.action.id) }.map {
            (LauncherResult.action($0.action), $0.score)
        }
        let saved = shortcuts.map { (LauncherResult.shortcut($0.record), $0.score) }
        let commands = (native + saved).sorted { $0.1 > $1.1 }
        let files = resultsRevision == revision || commands.isEmpty ? hits.map(LauncherResult.file) : []
        let result = calculation.map { [LauncherResult.calculation($0)] } ?? []
        return result + commands.filter { $0.1 >= 80 }.map(\.0) + files + commands.filter { $0.1 < 80 }.map(\.0)
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSearch: Bool { indexPhase == .ready && (firstNamesReady || (!scopePending && scopeTrustedForLookup)) }
    var isIndexing: Bool { indexWork == .names || indexWork == .documents }
    var activeProgress: IndexProgress? { isIndexing ? scanProgress : watchProgress }
    var activityBusy: Bool { contentRunning || indexWork != nil || watchState == .starting || watchProgress != nil }
    var relatedExcerptsLabel: String { t("相关原文", "Related Excerpts") }
    var canBuildEmbeddings: Bool {
        canSearch && !scopePending && !contentRunning && indexWork == nil && localModelState != .checking && embeddingState != .verifying &&
            gemmaCoverage?.documents_enabled == true && gemmaCoverage?.pending == true && gemmaCoverage?.limited == false
    }

    init(engine: LauncherEngine, defaults: UserDefaults?, locale: String? = nil) {
        self.engine = engine
        self.defaults = defaults
        shortcuts = ShortcutLibrary(defaults: defaults)
        builtInActions = LaunchCatalog.systemActions()
        scopePending = engine.hasPendingScope
        language = locale ?? defaults?.string(forKey: "language") ?? "system"
        let content = defaults?.stringArray(forKey: "contentRootPaths") ?? []
        contentPaused = defaults?.bool(forKey: "contentIndexingPaused") ?? false
        scope = IndexScope(roots: IndexScope.storedPaths("roots", in: defaults),
                           allow: IndexScope.storedPaths("allow", in: defaults),
                           deny: IndexScope.storedPaths("deny", in: defaults),
                           documents: !content.isEmpty, content_roots: content)
        shortcutChanges = shortcuts.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
                self?.reconcileSelection()
            }
        }
    }

    func start() {
        inspectLocalResources()
        if engine.hasDatabase {
            _ = engine.run(["status", "--include-scope"]) { [weak self] response in
                guard let self, !self.closed else { return }
                if let report = self.report(from: response) {
                    self.publish(report)
                    self.acceptCoverage(from: report)
                } else if !self.scopeTrustedForLookup {
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
            let help = String(decoding: response.output, as: UTF8.self)
            self.watchReportsProgress = response.succeeded && help.contains("--progress")
            self.watchSupportsCachedStart = response.succeeded && help.contains("--cached-start")
            self.engine.checksCachedHitAccess = self.watchSupportsCachedStart
            self.watchState = response.succeeded ? (self.scopePending ? .paused : .needsSetup) : .unavailable
            self.startWatcherIfReady()
        }
    }

    func close() {
        closed = true
        textDebounce?.cancel()
        cancelNameBypass()
        semanticDebounce?.cancel()
        cancelCoverageRead()
        cancelModelCheck()
        clearFileDiagnosis()
        if modelInspection?.isRunning == true { modelInspection?.terminate() }
        engine.close()
        for process in [watcher, writer, contentWriter, textProcess, actionProcess].compactMap({ $0 }) where process.isRunning {
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
        case .preview: return t("无法快速查看此文件。可预览的本机文件上限为 128 MB。", "Could not preview the file. The limit for local previews is 128 MB.")
        case .copiedName: return t("已复制名称", "Name copied")
        case .copiedPath: return t("已复制路径", "Path copied")
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

    func loadApplications(roots: [URL], extraApps: [URL]) {
        guard !closed, !loadingApplications,
              applicationsLoadedAt.map({ $0.duration(to: .now) >= .seconds(20) }) ?? true else { return }
        loadingApplications = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let registered = LaunchCatalog.discoverApplications(roots: roots, extraApps: extraApps)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.loadingApplications = false
                self.applicationsLoadedAt = .now
                self.appActions = registered
                self.updateLaunchMatches()
                self.reconcileSelection()
            }
        }
    }

    func setQuery(_ text: String) {
        let leavingImages = isImageSearch
        if leavingImages {
            imageProjector = nil
            engine.closeImages()
        }
        guard text != query || leavingImages else { return }
        query = text
        calculation = CalculationResult.evaluate(text)
        updateLaunchMatches()
        scheduleSearch(clearRows: leavingImages)
        if let first = visibleResults.first {
            switch first {
            case .file: break
            case .action(let action):
                if launchMatches.first(where: { $0.action.id == action.id })?.primary == true { selection = first.id }
            case .shortcut, .calculation: selection = first.id
            }
        }
        reconcileSelection()
    }

    func setImageQuery(_ text: String, projector: URL) {
        guard text != query || projector != imageProjector else { return }
        if projector != imageProjector { engine.closeImages() }
        imageProjector = projector
        query = text
        launchMatches = []
        calculation = nil
        scheduleSearch(clearRows: true)
    }

    private func updateLaunchMatches() {
        guard !isImageSearch else { return }
        let current = LaunchCatalog.matches(query, actions: builtInActions + appActions)
        if launchMatches != current { launchMatches = current }
    }

    func containsCurrentAction(_ action: LaunchAction) -> Bool {
        !closed && launchMatches.contains(where: { $0.action == action })
    }

    func retrySearch() { scheduleSearch() }

    func externalVolumesChanged() {
        guard hasQuery, canSearch, !closed else { return }
        let isLocal: (SearchHit) -> Bool = { !$0.path.lowercased().hasPrefix("/volumes/") }
        directHits = directHits.filter(isLocal)
        publishHits(hits.filter(isLocal))
        scheduleSearch()
    }

    func warmNameSearch() {
        if canSearch && !closed { engine.warmNameSearch() }
    }

    func clear() {
        if isImageSearch { imageProjector = nil; engine.closeImages() }
        query = ""
        calculation = nil
        launchMatches = []
        scheduleSearch(clearRows: true)
    }

    private func invalidateSearch(clearRows: Bool = true, keepAction: Bool = false) {
        revision &+= 1
        rejectedPaths.removeAll()
        textDebounce?.cancel()
        cancelNameBypass()
        cancelRelatedExcerpts()
        engine.discardQueuedSearch()
        engine.discardQueuedImages()
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
        let shouldSearch = hasQuery && canSearch && (!isImageSearch || !scopePending)
        // Keep the result surface intact while a replacement is pending. Old
        // rows are visual only until the current revision has been validated.
        invalidateSearch(clearRows: clearRows || !shouldSearch, keepAction: keepAction && shouldSearch)
        guard shouldSearch else { return }
        searching = true
        let current = revision
        search(revision: current, watchRefresh: keepAction)
    }

    private func search(revision: UInt64, watchRefresh: Bool) {
        let term = query
        if let imageProjector {
            searchImages(term, projector: imageProjector, revision: revision)
            return
        }
        let keepStablePreviewRows = watchRefresh && presentedQuery == term && hits.contains(where: \.hasPreview)
        var names: Result<[SearchHit], SearchFailure>?
        var text: Result<[SearchHit], SearchFailure>?
        var related: [SearchHit] = []
        let oldRelated = presentedQuery == term && localModelState == .ready
            ? hits.filter(\.isSemanticCandidate) : []
        // Short text falls back to a document scan. A one-character edit is a name lookup.
        let searchesText = term.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 &&
            gemmaCoverage?.documents_enabled != false
        if !searchesText { text = .success([]) }

        let publish = { [weak self] in
            guard let self, self.revision == revision, !self.closed else { return }
            let complete = names != nil && text != nil
            // Keep the same query's preview rows in place during a watch refresh.
            // They remain nonactionable until refreshed, and watch independently drops a stale stamp.
            guard complete || !keepStablePreviewRows else { return }
            let nameHits = (try? names?.get()) ?? []
            let strongNames = nameHits.filter { $0.matched_by != "path" }
            let bodyHits = (try? text?.get()) ?? []
            // Keep provisional path filler below body hits and out of the first result update.
            let weakPaths = complete ? nameHits.filter { $0.matched_by == "path" } : []
            var seen = Set<String>()
            let lexical = Array((strongNames + bodyHits + weakPaths).filter { seen.insert($0.path).inserted }.prefix(60))
            guard complete || !lexical.isEmpty else { return }
            self.presentedQuery = term
            self.directHits = lexical
            self.resultsRevision = revision
            self.publishWithRelated(self.shouldFindRelatedExcerpts(directCount: lexical.count) ? related : [])
            if complete {
                self.searching = false
                if case .failure(let error) = names, case .failure? = text {
                    self.searchNotice = LauncherNotice(.search, error.detail)
                }
                self.queueRelatedExcerpts()
            }
        }

        if !oldRelated.isEmpty {
            validatePreviews(oldRelated, revision: revision) { [weak self] available in
                guard let self, self.relatedRevision != revision else { return }
                related = available
                publish()
            }
        }
        // A previous one-character or unindexed query may still be running on the warm server.
        // Two Han characters have a bounded disk fast path in the engine.
        let scalars = term.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        let canBypass = engine.nameSearchBusy && scalars.count == 2 &&
            scalars.allSatisfy { (0x3400...0x9fff).contains($0.value) }
        var warmFinished = false
        var bypassFinished = !canBypass
        let acceptNames = { [weak self] (result: Result<[SearchHit], SearchFailure>, fromWarm: Bool) in
            guard let self, self.revision == revision, !self.closed, names == nil else { return }
            if fromWarm { warmFinished = true } else { bypassFinished = true }
            switch result {
            case .success(let hits):
                // Name replies have no snippets to inspect on disk.
                names = .success(hits.filter { !$0.hasPreview })
                if fromWarm { self.cancelNameBypass() } else { self.engine.discardQueuedSearch() }
            case .failure where warmFinished && bypassFinished:
                names = result
            case .failure:
                return
            }
            publish()
        }
        engine.search(term, mode: "name") { acceptNames($0, true) }
        if canBypass {
            nameBypassDelay = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, let self, self.revision == revision, names == nil else { return }
                self.nameBypassProcess = self.engine.run(["query", "--mode", "name", "--limit", "60", "--", term]) { [weak self] response in
                    guard let self, self.revision == revision else { return }
                    self.nameBypassProcess = nil
                    acceptNames(self.searchResult(from: response), false)
                }
            }
        }
        guard searchesText else { return }
        textDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(55))
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            self.textProcess = self.engine.run(["query", "--mode", "text", "--limit", "24", "--", term]) { [weak self] response in
                guard let self, self.revision == revision, !self.closed else { return }
                self.textProcess = nil
                switch self.searchResult(from: response) {
                case .success(let hits):
                    self.validatePreviews(hits, revision: revision) { available in
                        text = .success(available)
                        publish()
                    }
                case .failure(let failure):
                    text = .failure(failure)
                    publish()
                }
            }
        }
    }

    private func cancelNameBypass() {
        nameBypassDelay?.cancel()
        nameBypassDelay = nil
        if nameBypassProcess?.isRunning == true { nameBypassProcess?.terminate() }
        nameBypassProcess = nil
    }

    private func searchResult(from response: EngineResponse) -> Result<[SearchHit], SearchFailure> {
        if response.succeeded, let hits = try? JSONDecoder().decode([SearchHit].self, from: response.output) {
            return .success(hits)
        }
        return .failure(SearchFailure(response.diagnostic))
    }

    private func searchImages(_ query: String, projector: URL, revision: UInt64) {
        textDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            self.engine.searchImages(query, projector: projector) { [weak self] response in
                guard let self, self.revision == revision, self.isImageSearch, !self.closed else { return }
                switch response {
                case .failure:
                    self.searching = false
                    self.searchNotice = LauncherNotice(.search)
                case .success(let results):
                    let candidates = results.prefix(5).filter { $0.isImageMatch && $0.isLocal && $0.document_stamp != nil }
                    let group = DispatchGroup()
                    var confirmed = Set<String>()
                    for hit in candidates {
                        guard let stamp = hit.document_stamp else { continue }
                        group.enter()
                        _ = self.engine.run(["validate-hit", "--kind", hit.kind, "--availability", hit.availability,
                                             "--document-stamp", stamp, "--", hit.path]) { result in
                            defer { group.leave() }
                            if result.succeeded, (try? JSONDecoder().decode(HitValidation.self, from: result.output))?.valid == true {
                                confirmed.insert(hit.path)
                            }
                        }
                    }
                    group.notify(queue: .main) { [weak self] in
                        guard let self, self.revision == revision, self.isImageSearch, !self.scopePending else { return }
                        self.searching = false
                        self.presentedQuery = query
                        self.resultsRevision = revision
                        self.directHits = candidates.filter { confirmed.contains($0.path) }
                        self.publishHits(self.directHits)
                    }
                }
            }
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
        reconcileSelection()
    }

    private func reconcileSelection() {
        let rows = visibleResults
        if !rows.contains(where: { $0.id == selection }), selection != rows.first?.id {
            selection = rows.first?.id
        }
    }

    func moveSelection(_ step: Int) {
        let rows = visibleResults
        guard !rows.isEmpty else { return }
        guard let index = rows.firstIndex(where: { $0.id == selection }) else {
            selection = (step > 0 ? rows.first : rows.last)?.id
            return
        }
        selection = rows[min(max(index + step, 0), rows.count - 1)].id
    }

    var selectedResult: LauncherResult? {
        guard let row = visibleResults.first(where: { $0.id == selection }) else { return nil }
        if case .file = row { return selectedHit.map(LauncherResult.file) }
        return row
    }

    var selectedHit: SearchHit? {
        guard resultsRevision == revision else { return nil }
        return hits.first { $0.path == selection }
    }

    func openingFailed() { searchNotice = LauncherNotice(.opening) }

    func previewFailed() { searchNotice = LauncherNotice(.preview) }

    func copied(_ action: FileAction) {
        searchNotice = LauncherNotice(action == .copyName ? .copiedName : .copiedPath)
    }

    func containsCurrentFile(_ hit: SearchHit) -> Bool {
        !closed && canSearch && resultsRevision == revision && hits.contains(hit)
    }

    func resolve(_ hit: SearchHit, action: FileAction, complete: @escaping (URL) -> Void) {
        guard containsCurrentFile(hit), actionProcess == nil else { return }
        guard !hit.isSemanticCandidate || localModelState == .ready else { return }
        if action == .preview && hit.kind != "file" { return }
        guard hit.isLocal || (action.allowsCloudReference && hit.isCloudReference) else {
            if hit.isCloudReference { searchNotice = LauncherNotice(.online) }
            return
        }
        revalidate(hit, retry: true, complete: complete)
    }

    private func revalidate(_ hit: SearchHit, retry: Bool, complete: @escaping (URL) -> Void) {
        let current = revision
        let intent = actionIntent
        let text = hit.matched_by == "text"
        let mode = text ? "text" : "name"
        let targeted = hit.isImageMatch || !hit.isSemanticCandidate && supportsTargetedValidation
        let arguments: [String]
        if targeted {
            var validation = ["validate-hit", "--kind", hit.kind, "--availability", hit.availability]
            if text || hit.hasPreview || hit.isImageMatch {
                guard let stamp = hit.document_stamp else {
                    rejectStaleResult(hit)
                    return
                }
                validation += ["--document-stamp", stamp]
            }
            arguments = validation + ["--", hit.path]
        } else if hit.isSemanticCandidate {
            arguments = semanticArguments()
        } else {
            arguments = ["query", "--mode", mode, "--limit", text ? "24" : "60", "--", query]
        }
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
        actionProcess = engine.run(arguments, priority: .userInitiated) { [weak self] response in
            guard let self, permitsDelivery() else { return }
            if targeted, !hit.isImageMatch, !response.succeeded, response.diagnostic.contains("unrecognized subcommand 'validate-hit'") {
                self.supportsTargetedValidation = false
                self.revalidate(hit, retry: retry, complete: complete)
                return
            }
            let decoder = JSONDecoder()
            let confirmed = targeted
                ? (try? decoder.decode(HitValidation.self, from: response.output))?.valid == true
                : (try? decoder.decode([SearchHit].self, from: response.output))?.contains(hit) == true
            guard response.succeeded, confirmed else {
                if hit.isSemanticCandidate { recordModelFailure(response.diagnostic) }
                self.rejectStaleResult(hit)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let stamp = hit.pathStamp()
                DispatchQueue.main.async { [weak self] in
                    guard let self, permitsDelivery() else { return }
                    guard let stamp, !(hit.hasPreview || hit.isImageMatch) || hit.document_stamp == stamp else {
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
        var requested = requested
        if requested.content_roots == nil, let savedScope, !requested.sharesNameScope(with: savedScope) {
            // Editing the old name scope cannot authorize body indexing in newly visible folders.
            requested.contentFolders = savedScope.previouslyAuthorizedDocumentFolders
        }
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
        let contentOnly = indexPhase == .ready && requested.content_roots != nil
            && savedScope.map { requested.sharesNameScope(with: $0) && requested.content_roots != $0.content_roots } == true
        if !requested.contentFolders.isEmpty { defaults?.set(true, forKey: "gemmaIndexingEnabled") }
        contentFailed = false
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
        if shouldStageDocuments { first.documents = false; if first.content_roots != nil { first.content_roots = [] } }
        indexWork = first.documents ? .documents : .names
        withWatcherStopped { [weak self] in
            self?.scan(first, then: shouldStageDocuments ? requested : nil, contentOnly: contentOnly)
        }
    }

    private func scan(_ scope: IndexScope, then next: IndexScope?, contentOnly: Bool = false) {
        scanGeneration &+= 1
        let generation = scanGeneration
        scanProgress = nil
        let progressOption = !contentOnly && indexReportsProgress ? ["--progress"] : []
        let arguments = contentOnly ? scope.contentArguments : engine.indexArguments(scope: scope)
        writer = engine.run(arguments + progressOption, onProgress: { [weak self] progress in
            guard let self, !self.closed, self.scanGeneration == generation else { return }
            if self.scanProgress != progress { self.scanProgress = progress }
        }) { [weak self] response in
            guard let self, !self.closed, self.scanGeneration == generation else { return }
            self.scanGeneration &+= 1
            self.writer = nil
            let didReport = self.scanProgress != nil
            self.scanProgress = nil
            if !contentOnly, !response.succeeded, !didReport, self.indexReportsProgress,
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
                self.scan(next, then: nil, contentOnly: next.content_roots != nil)
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

    func setContentPaused(_ paused: Bool) {
        defaults?.set(paused, forKey: "contentIndexingPaused")
        contentPaused = paused
        if !paused {
            contentFailed = false
            startContentIfReady()
        }
    }

    private func startContentIfReady() {
        guard canSearch, !scopePending, !closed, indexWork == nil, contentWriter == nil,
              !contentPaused, !contentFailed, contentCoverage?.pending ?? 0 > 0 else { return }
        contentRunning = true
        contentWriter = engine.run(["content", "--max", "8"], priority: .background) { [weak self] response in
            guard let self, !self.closed else { return }
            self.contentWriter = nil
            self.contentRunning = false
            guard response.succeeded, let batch = try? JSONDecoder().decode(ContentBatch.self, from: response.output) else {
                self.contentFailed = true
                return
            }
            if batch.indexed > 0 {
                self.automaticBuildAttempted = false
                if self.embeddingState == .finished { self.embeddingState = .idle }
                self.scheduleSearch(keepAction: true)
            }
            if batch.processed == 0 && batch.pending > 0 { self.contentFailed = true }
            self.refreshCoverage(after: .milliseconds(100))
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
        if contentCoverage != report.content { contentCoverage = report.content }
        startContentIfReady()
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
           contentCoverage?.pending ?? 0 == 0 || contentPaused || contentFailed,
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
        let canPrepareCache = watchSupportsCachedStart && indexPhase == .checking && engine.hasDatabase
        guard watchSupported == true, indexPhase == .ready || canPrepareCache, !scopePending,
              watcher == nil, !closed else { return }
        watchState = .starting
        watchNotice = nil
        watchGeneration &+= 1
        let generation = watchGeneration
        let arguments = ["watch", "--bundled-pdf-helper"] + (watchReportsProgress ? ["--progress"] : [])
            + (watchSupportsCachedStart ? ["--cached-start"] : [])
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
        if notice.event == .cached {
            scopeTrustedForLookup = true
            indexPhase = .ready
            scheduleSearch(keepAction: true)
            return
        }
        if notice.event == .ready {
            scopeTrustedForLookup = true
            indexPhase = .ready
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
