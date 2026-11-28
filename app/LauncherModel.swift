import AppKit
import Combine
import Darwin

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

struct LocalModelStatus: Decodable, Equatable {
    let available: Bool
    let verified: Bool
    let signature: String?
    let dimensions: Int?
    let diagnostic: String?
}

struct EmbeddingBatch: Decodable, Equatable {
    let new_embeddings: Int
    let skipped_chunks: Int
    let has_more: Bool
}

private struct WatchEvent: Decodable {
    enum Kind: String, Decodable { case cached, ready, updated }
    let event: Kind
}

struct FileDiagnosis: Decodable, Equatable {
    let name: String
    let text: String
    let semantic: String
}

enum FileDiagnosisState: Equatable {
    case idle, checking(String), result(String, FileDiagnosis), failed(String)
}

enum LauncherProblem: Equatable {
    case status, indexing, search, embeddings, embeddingNoProgress, opening, scope, scopeState, watch, online, stale, preview, copiedName, copiedPath
}

struct LauncherNotice: Equatable {
    let problem: LauncherProblem
    let detail: String
    init(_ problem: LauncherProblem, _ detail: String = "") {
        self.problem = problem
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension HotKeyIssue: Equatable {
    static func == (lhs: HotKeyIssue, rhs: HotKeyIssue) -> Bool {
        switch (lhs, rhs) {
        case (.invalid, .invalid), (.system, .system), (.app, .app), (.occupied, .occupied): return true
        case (.registration(let a), .registration(let b)): return a == b
        default: return false
        }
    }
}

@MainActor
final class IndexStatusState: ObservableObject {
    @Published var indexPhase = IndexPhase.checking
    @Published var indexWork: IndexWork?
    @Published var indexReport: IndexReport?
    @Published var scanProgress: IndexProgress?
    @Published var watchState = WatchState.checking
    @Published var watchProgress: IndexProgress?
    @Published var watchNotice: LauncherNotice?
    @Published var scopePending: Bool
    @Published var savedScope: IndexScope?
    @Published var scope: IndexScope {
        didSet {
            guard scope != oldValue else { return }
            onScopeChanged?(scope)
        }
    }
    @Published var indexNotice: LauncherNotice?
    @Published var contentCoverage: ContentCoverage?
    @Published var contentPaused = false
    @Published var contentRunning = false
    @Published var contentFailed = false
    @Published var localModelState = LocalModelState.unchecked
    @Published var gemmaCoverage: GemmaCoverage?
    @Published var imageCoverage: ImageCoverage?
    @Published var embeddingState = EmbeddingState.idle
    @Published var embeddingBatch: EmbeddingBatch?
    @Published var embeddingNotice: LauncherNotice?
    @Published var fileDiagnosis = FileDiagnosisState.idle

    var onScopeChanged: ((IndexScope) -> Void)?

    init(scopePending: Bool, scope: IndexScope, contentPaused: Bool) {
        self.scopePending = scopePending
        self.scope = scope
        self.contentPaused = contentPaused
    }

    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<IndexStatusState, Value>, to value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum FileDefaultAction: String, CaseIterable {
    case open
    case revealInFinder
}

@MainActor
final class Launcher: ObservableObject {
    private static let trailingExtensionRegex = try! NSRegularExpression(pattern: #"\.[A-Za-z0-9]{1,8}$"#)

    let indexStatus: IndexStatusState
    @Published private(set) var query = ""
    private var imageProjector: URL?
    @Published private(set) var isImageSearch = false
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var visibleResults: [LauncherResult] = []
    @Published private(set) var launchMatches: [ActionMatch] = []
    private var executableMatches: [ActionMatch] = []
    @Published private(set) var calculation: CalculationResult?
    let shortcuts: ShortcutLibrary
    private var shortcutChanges: AnyCancellable?
    @Published var selectedID: String?
    var selection: String? {
        get { selectedID }
        set { set(\.selectedID, to: newValue) }
    }
    @Published private(set) var searching = false
    @Published private(set) var semanticBusy = false
    @Published private(set) var searchNotice: LauncherNotice?
    @Published private(set) var canSearchFlag = false
    @Published var hotKey: HotKey?
    @Published var hotKeyIssue: HotKeyIssue?
    @Published var language: String {
        didSet {
            guard language != oldValue else { return }
            defaults?.set(language, forKey: "language")
        }
    }

    @Published var appearanceMode: AppearanceMode
    @Published var fileDefaultAction: FileDefaultAction
    @Published var textEmbeddingBackend: TextEmbeddingBackendConfig

    func setAppearanceMode(_ mode: AppearanceMode) {
        guard appearanceMode != mode else { return }
        appearanceMode = mode
        defaults?.set(mode.rawValue, forKey: "appearance")
    }

    func setFileDefaultAction(_ action: FileDefaultAction) {
        guard fileDefaultAction != action else { return }
        fileDefaultAction = action
        defaults?.set(action.rawValue, forKey: "fileDefaultAction")
    }

    func usesRevealDefault(for hit: SearchHit) -> Bool {
        fileDefaultAction == .revealInFinder && hit.kind == "file" && !hit.path.lowercased().hasSuffix(".app")
    }

    func primaryFileAction(for hit: SearchHit) -> FileAction {
        usesRevealDefault(for: hit) ? .reveal : .open
    }

    func secondaryFileAction(for hit: SearchHit) -> FileAction {
        usesRevealDefault(for: hit) ? .open : .reveal
    }

    var localModelState: LocalModelState { indexStatus.localModelState }
    var gemmaCoverage: GemmaCoverage? { indexStatus.gemmaCoverage }
    var imageCoverage: ImageCoverage? { indexStatus.imageCoverage }
    var onCoverageAccepted: ((IndexReport) -> Void)?
    var isImageIndexingActive: (() -> Bool)?
    var canBootstrapImages: (() -> Bool)?
    var shouldDeferEmbeddingsToImages: (() -> Bool)?
    var maxEmbeddingBatchesPerTurn: (() -> Int?)?
    var onEmbeddingsTurnCompleted: (() -> Void)?
    var isEmbeddingIndexingPaused: Bool { defaults?.bool(forKey: "gemmaIndexingPaused") == true }
    var indexPhase: IndexPhase { indexStatus.indexPhase }
    var indexWork: IndexWork? { indexStatus.indexWork }
    var indexReport: IndexReport? { indexStatus.indexReport }
    var savedScope: IndexScope? { indexStatus.savedScope }
    var indexNotice: LauncherNotice? { indexStatus.indexNotice }
    var scanProgress: IndexProgress? { indexStatus.scanProgress }
    var watchProgress: IndexProgress? { indexStatus.watchProgress }
    var scopePending: Bool { indexStatus.scopePending }
    var contentCoverage: ContentCoverage? { indexStatus.contentCoverage }
    var contentPaused: Bool { indexStatus.contentPaused }
    var contentRunning: Bool { indexStatus.contentRunning }
    var contentFailed: Bool { indexStatus.contentFailed }
    var embeddingState: EmbeddingState { indexStatus.embeddingState }
    var embeddingBatch: EmbeddingBatch? { indexStatus.embeddingBatch }
    var embeddingNotice: LauncherNotice? { indexStatus.embeddingNotice }
    var watchState: WatchState { indexStatus.watchState }
    var watchNotice: LauncherNotice? { indexStatus.watchNotice }
    var fileDiagnosis: FileDiagnosisState { indexStatus.fileDiagnosis }
    var scope: IndexScope {
        get { indexStatus.scope }
        set { indexStatus.set(\.scope, to: newValue) }
    }

    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Launcher, Value>, to value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private var contentWriter: Process?
    private let engine: LauncherEngine
    private let defaults: UserDefaults?
    private var watchSupported: Bool?
    private var watchReportsProgress = false
    private var watchSupportsCachedStart = false
    private var scanGeneration: UInt64 = 0
    private var revision: UInt64 = 0
    private var resultsRevision: UInt64?
    private var rejectedPaths = Set<String>()
    private var presentedQuery = ""
    private var directHits: [SearchHit] = []
    private var coverageUpdate: Task<Void, Never>?
    private var coverageRead: Process?
    private var coverageInFlight = false
    private var coverageGeneration: UInt64 = 0
    private var automaticBuildAttempted = false
    private var modelInspection: Process?
    private var diagnosisProcess: Process?
    private var diagnosisGeneration: UInt64 = 0
    private var textDebounce: Task<Void, Never>?
    private var semanticDebounce: Task<Void, Never>?
    private var firstNamesReady = false { didSet { syncCanSearch() } }
    // An existing index may contain paths hidden by permission changes while Lumen was closed.
    private var scopeTrustedForLookup = false { didSet { syncCanSearch() } }
    private var watchGeneration: UInt64 = 0
    private var watchRetryTask: Task<Void, Never>?
    private var watchLeaseRetryCount = 0
    private static let watchLeaseRetryDelays: [Duration] = [
        .milliseconds(400), .milliseconds(800), .seconds(1), .seconds(2), .seconds(3),
    ]
    private var watcher: Process?
    private var afterWatcherStops: (() -> Void)?
    private var stoppingWatcher = false
    private var writer: Process?
    private var embeddingStreamGeneration: UInt64 = 0
    private var relatedRevision: UInt64?
    private var relatedSearchInFlightKind: RelatedSearchKind?
    private var modelCheck: Process?
    private var modelCheckGeneration: UInt64 = 0
    private(set) var isSearchPresented = false
    private(set) var isSettingsPresented = false
    private var silentRefreshTask: Task<Void, Never>?
    private var silentRefreshRunning = false
    private var silentRefreshPending = false
    private var silentRefreshGeneration: UInt64 = 0
    private var lastSettingsCoverageRefresh: ContinuousClock.Instant?
    private var actionIntent: UInt64 = 0
    private var actionValidating = false
    private var closed = false
    private let builtInActions: [LaunchAction]
    private let frecency: LauncherFrecency
    private var applicationOpens: AnyCancellable?
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

    private func computeVisibleResults() -> [LauncherResult] {
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
        let executables = executableMatches.map { (LauncherResult.action($0.action), $0.score) }
        let commands = native + saved + executables
        let result = calculation.map { [LauncherResult.calculation($0)] } ?? []
        guard !commands.isEmpty else { return result + hits.map(LauncherResult.file) }
        let files: [(LauncherResult, Int)] = hits.map { hit in
            // Keep lexical order on ties. Regular use can move a direct file above a partial command match.
            let direct = hit.matched_by != "path" && !hit.isRelatedHit
            let rank = direct ? 79 + frecency.boost(LauncherFrecency.fileID(hit.path), query: query) : 78
            return (.file(hit), rank)
        }
        return result + (commands + files).sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func rebuildVisibleResults() {
        set(\.visibleResults, to: computeVisibleResults())
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSearch: Bool { canSearchFlag }

    private func syncCanSearch() {
        let ready = indexStatus.indexPhase == .ready &&
            (firstNamesReady || (!indexStatus.scopePending && scopeTrustedForLookup))
        set(\.canSearchFlag, to: ready)
    }

    var isIndexing: Bool { indexWork == .names || indexWork == .documents }
    var activeProgress: IndexProgress? { isIndexing ? scanProgress : watchProgress }
    var activityBusy: Bool { contentRunning || indexWork != nil || watchState == .starting || watchProgress != nil }
    var relatedExcerptsLabel: String { t("相关原文", "Related Excerpts") }
    var canBuildEmbeddings: Bool {
        canSearch && !scopePending && !contentRunning && indexWork == nil && localModelState != .checking && embeddingState != .verifying &&
            (textEmbeddingBackend.mode == .builtin || textEmbeddingBackend.isValidLocalOpenAI) &&
            gemmaCoverage?.documents_enabled == true && gemmaCoverage?.pending == true && gemmaCoverage?.limited == false
    }

    init(engine: LauncherEngine, defaults: UserDefaults?, locale: String? = nil) {
        self.engine = engine
        self.defaults = defaults
        let loadedBackend = TextEmbeddingBackendConfig.load(from: defaults)
        self.textEmbeddingBackend = loadedBackend
        engine.setTextEmbeddingBackend(loadedBackend)
        let frecency = LauncherFrecency(defaults: defaults)
        self.frecency = frecency
        shortcuts = ShortcutLibrary(defaults: defaults)
        builtInActions = LaunchCatalog.systemActions()
        let content = defaults?.stringArray(forKey: "contentRootPaths") ?? []
        let initialScope = IndexScope(roots: IndexScope.storedPaths("roots", in: defaults),
                                      allow: IndexScope.storedPaths("allow", in: defaults),
                                      deny: IndexScope.storedPaths("deny", in: defaults),
                                      documents: !content.isEmpty, content_roots: content)
        indexStatus = IndexStatusState(scopePending: engine.hasPendingScope,
                                       scope: initialScope,
                                       contentPaused: defaults?.bool(forKey: "contentIndexingPaused") ?? false)
        language = locale ?? defaults?.string(forKey: "language") ?? "system"
        appearanceMode = defaults?.string(forKey: "appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        fileDefaultAction = defaults?.string(forKey: "fileDefaultAction").flatMap(FileDefaultAction.init(rawValue:)) ?? .open
        indexStatus.onScopeChanged = { [weak self] nextScope in
            guard let self else { return }
            self.pauseEmbeddings()
            self.defaults?.set(nextScope.roots, forKey: "rootsPaths")
            self.defaults?.set(nextScope.allow, forKey: "allowPaths")
            self.defaults?.set(nextScope.deny, forKey: "denyPaths")
            self.defaults?.set(nextScope.documents, forKey: "documents")
            self.defaults?.set(nextScope.content_roots, forKey: "contentRootPaths")
        }
        rebuildVisibleResults()
        shortcutChanges = shortcuts.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rebuildVisibleResults()
                self.reconcileSelection()
            }
        }
        applicationOpens = LaunchDispatcher.didOpenApplication.sink { [weak self] action in
            guard let self, !self.closed, self.appActions.contains(action) else { return }
            self.frecency.noteOpened(action.id, query: self.query)
            self.updateLaunchMatches()
            self.rebuildVisibleResults()
            self.reconcileSelection()
        }
    }

    func start(automaticallyIndex: Bool = true) {
        inspectLocalResources()
        if engine.hasDatabase {
            engine.status(includeScope: true, includeLocalOpenAI: false) { [weak self] response in
                guard let self, !self.closed else { return }
                if let report = self.report(from: response) {
                    self.publish(report)
                    self.acceptCoverage(from: report, includeGemma: self.textEmbeddingBackend.mode == .builtin)
                    if self.textEmbeddingBackend.isValidLocalOpenAI {
                        self.refreshCoverage()
                    }
                } else {
                    self.indexStatus.set(\.indexPhase, to: .unreadable)
                    self.syncCanSearch()
                    self.indexStatus.set(\.indexNotice, to: LauncherNotice(.status, response.diagnostic))
                }
                self.startWatcherIfReady()
            }
        } else {
            indexStatus.set(\.indexPhase, to: .needsIndex)
            syncCanSearch()
            if automaticallyIndex, !scopePending {
                // First launch builds names only; document indexing still requires opt-in.
                var names = scope
                names.documents = false
                names.content_roots = []
                applyScope(names)
            }
        }
        if engine.usesCoreLibrary {
            watchSupported = true
            watchReportsProgress = true
            watchSupportsCachedStart = true
            indexStatus.set(\.watchState, to: scopePending ? .paused : .needsSetup)
            startWatcherIfReady()
        } else {
            _ = engine.run(["watch", "--help"]) { [weak self] response in
                guard let self, !self.closed else { return }
                self.watchSupported = response.succeeded
                let help = String(decoding: response.output, as: UTF8.self)
                self.watchReportsProgress = response.succeeded && help.contains("--progress")
                self.watchSupportsCachedStart = response.succeeded && help.contains("--cached-start")
                self.indexStatus.set(\.watchState, to: response.succeeded ? (self.scopePending ? .paused : .needsSetup) : .unavailable)
                self.startWatcherIfReady()
            }
        }
    }

    func setSearchPresented(_ presented: Bool) {
        guard isSearchPresented != presented else { return }
        isSearchPresented = presented
        if !presented { cancelSilentRefresh() }
    }

    func setSettingsPresented(_ presented: Bool) {
        guard isSettingsPresented != presented else { return }
        isSettingsPresented = presented
        if presented, canSearch, !scopePending {
            lastSettingsCoverageRefresh = .now
            refreshCoverage()
        }
    }

    func close() {
        closed = true
        embeddingStreamGeneration &+= 1
        cancelSilentRefresh()
        cancelWatchRetry()
        textDebounce?.cancel()
        semanticDebounce?.cancel()
        cancelCoverageRead()
        cancelModelCheck()
        clearFileDiagnosis()
        if modelInspection?.isRunning == true { modelInspection?.terminate() }
        engine.close()
        let active = [watcher, writer, contentWriter].compactMap({ $0 }).filter(\.isRunning)
        for process in active {
            process.terminate()
        }
        // Give terminating watch/writers a short window to release their SQLite/flock leases before app relaunch.
        let deadline = ContinuousClock.now + .milliseconds(400)
        while ContinuousClock.now < deadline && active.contains(where: \.isRunning) {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func cancelWatchRetry() {
        watchRetryTask?.cancel()
        watchRetryTask = nil
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
        case .preview: return t("无法快速查看此文件。", "Could not preview the file.")
        case .copiedName: return t("已复制名称", "Name copied")
        case .copiedPath: return t("已复制路径", "Path copied")
        case .opening: return t("macOS 无法打开这个项目。", "macOS could not open this item.")
        case .scope: return t("索引范围中的路径必须以 / 开头。", "Index scope paths must start with /.")
        case .scopeState: return t("无法保存索引范围更新状态。请检查索引目录权限后重试。", "Could not save the scope update state. Check index directory permissions and try again.")
        case .watch:
            if notice.detail.contains("cannot acquire index writer lease") {
                return t("另一个索引或文件监听进程正在占用写锁，暂无法启动监听。",
                         "Another index or file watcher is holding the index lock.")
            }
            return canSearch
                ? t("文件监听已停止，仍可搜索已验证的索引。", "File watching stopped. You can still search the verified index.")
                : t("未能核对现有索引的访问权限。", "Lumen could not verify access to the saved index.")
        case .online: return t("此项目仅索引名称和路径，可使用「在 Finder 中显示」。", "Only the name and path were indexed. Use Show in Finder to locate this item.")
        case .stale: return t("此结果已变化或无法访问。请重新搜索。", "This result changed or became unavailable. Search again.")
        }
    }

    func modelDiagnostic(_ issue: LocalModelProblem) -> String {
        if textEmbeddingBackend.mode == .localOpenAI {
            return t("无法连接本机嵌入服务，请检查服务是否启动以及地址和模型配置。",
                     "Could not reach the local embedding endpoint. Check that the server is running and the URL/model are valid.")
        }
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
                self.rebuildVisibleResults()
                self.reconcileSelection()
            }
        }
    }

    func setQuery(_ text: String) {
        let leavingImages = isImageSearch
        if leavingImages {
            imageProjector = nil
            set(\.isImageSearch, to: false)
            engine.closeImages()
        }
        guard text != query || leavingImages else { return }
        set(\.query, to: text)
        set(\.calculation, to: CalculationResult.evaluate(text))
        updateLaunchMatches()
        scheduleSearch(clearRows: leavingImages)
        rebuildVisibleResults()
        if let first = visibleResults.first {
            switch first {
            case .file: break
            case .action(let action):
                if isPrimaryAction(action) { set(\.selectedID, to: first.id) }
            case .shortcut, .calculation: set(\.selectedID, to: first.id)
            }
        }
        reconcileSelection()
    }

    func setExecutableMatches(_ matches: [ActionMatch], resetSelection: Bool = false) {
        if executableMatches != matches {
            executableMatches = matches
            rebuildVisibleResults()
        }
        if resetSelection, let first = visibleResults.first,
           case .action(let action) = first, isPrimaryAction(action) {
            set(\.selectedID, to: first.id)
        }
        reconcileSelection()
    }

    private func isPrimaryAction(_ action: LaunchAction) -> Bool {
        launchMatches.first(where: { $0.action.id == action.id })?.primary == true
            || executableMatches.first(where: { $0.action.id == action.id })?.primary == true
    }

    func setImageQuery(_ text: String, projector: URL) {
        guard text != query || projector != imageProjector else { return }
        if projector != imageProjector { engine.closeImages() }
        imageProjector = projector
        set(\.isImageSearch, to: true)
        set(\.query, to: text)
        set(\.launchMatches, to: [])
        executableMatches = []
        set(\.calculation, to: nil)
        scheduleSearch(clearRows: true)
    }

    private func updateLaunchMatches() {
        guard !isImageSearch else { return }
        let now = Date.now
        let current = LauncherFileQuery(query).isFiltered ? [] :
            LaunchCatalog.matches(query, actions: builtInActions + appActions) { frecency.boost($0, query: query, now: now) }
        set(\.launchMatches, to: current)
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
        if isImageSearch {
            imageProjector = nil
            set(\.isImageSearch, to: false)
            engine.closeImages()
        }
        set(\.query, to: "")
        set(\.calculation, to: nil)
        set(\.launchMatches, to: [])
        executableMatches = []
        scheduleSearch(clearRows: true)
    }

    private func invalidateSearch(clearRows: Bool = true, keepAction: Bool = false) {
        revision &+= 1
        cancelSilentRefresh()
        rejectedPaths.removeAll()
        textDebounce?.cancel()
        cancelRelatedExcerpts()
        engine.discardQueuedSearch()
        engine.discardQueuedImages()
        if !keepAction {
            actionIntent &+= 1
            actionValidating = false
        }
        set(\.searching, to: false)
        if clearRows {
            presentedQuery = ""
            directHits = []
            publishHits([])
        }
        set(\.searchNotice, to: nil)
    }

    private func scheduleSearch(clearRows: Bool = false, keepAction: Bool = false) {
        let shouldSearch = hasQuery && canSearch && (!isImageSearch || !scopePending)
        // Keep the result surface intact while a replacement is pending. Old
        // rows are visual only until the current revision has been validated.
        invalidateSearch(clearRows: clearRows || !shouldSearch, keepAction: keepAction && shouldSearch)
        guard shouldSearch else { return }
        set(\.searching, to: true)
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
        let keepImageRelated = textEmbeddingBackend.mode == .localOpenAI
        let oldRelated = presentedQuery == term
            ? hits.filter { $0.isRelatedHit && (localModelState == .ready || (keepImageRelated && $0.isImageMatch)) }
            : []
        let fileQuery = LauncherFileQuery(term)
        // Short text falls back to a document scan. A one-character edit is a name lookup.
        let searchesText = fileQuery.kind != "folder" && fileQuery.words.count >= 2 &&
            gemmaCoverage?.documents_enabled != false
        if !searchesText { text = .success([]) }

        let publish = { [weak self] in
            guard let self, self.revision == revision, !self.closed else { return }
            let complete = names != nil && text != nil
            guard names != nil else { return }
            // Keep the same query's preview rows in place during a watch refresh.
            // They remain nonactionable until refreshed, and watch independently drops a stale stamp.
            guard complete || !keepStablePreviewRows else { return }
            let nameHits = (try? names?.get()) ?? []
            let strongNames = nameHits.filter { $0.matched_by != "path" }
            let bodyHits = (try? text?.get()) ?? []
            // Keep provisional path filler below body hits and out of the first result update.
            let weakPaths = complete ? nameHits.filter { $0.matched_by == "path" } : []
            var seen = Set<String>()
            let ranked = [strongNames, bodyHits, weakPaths].flatMap { self.frecency.rankFiles($0, query: term) }
            let lexical = Array(ranked.filter { seen.insert($0.path).inserted }.prefix(60))
            guard complete || !lexical.isEmpty else { return }
            self.presentedQuery = term
            self.directHits = lexical
            self.resultsRevision = revision
            self.publishWithRelated(self.shouldFindRelatedExcerpts(directCount: lexical.count) ? related : [])
            if complete {
                self.set(\.searching, to: false)
                if case .failure(let error) = names, bodyHits.isEmpty {
                    self.set(\.searchNotice, to: LauncherNotice(.search, error.detail))
                } else if case .failure(let error) = text, lexical.isEmpty {
                    self.set(\.searchNotice, to: LauncherNotice(.search, error.detail))
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
        engine.search(fileQuery.engineQuery, mode: "name") { [weak self] result in
            guard let self, self.revision == revision, !self.closed else { return }
            // Name replies have no snippets to inspect on disk.
            names = result.map { $0.filter { !$0.hasPreview } }
            publish()
        }
        guard searchesText else { return }
        textDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            self.engine.search(fileQuery.engineQuery, mode: "text") { [weak self] response in
                guard let self, self.revision == revision, !self.closed else { return }
                switch response {
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

    private func searchImages(_ query: String, projector: URL, revision: UInt64) {
        textDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            self.engine.searchImages(query, projector: projector) { [weak self] response in
                guard let self, self.revision == revision, self.isImageSearch, !self.closed else { return }
                switch response {
                case .failure:
                    self.set(\.searching, to: false)
                    self.set(\.searchNotice, to: LauncherNotice(.search))
                case .success(let results):
                    self.validateImageHits(results, query: query, revision: revision)
                }
            }
        }
    }

    private func validateImageHits(_ results: [SearchHit], query: String, revision: UInt64) {
        let candidates = results.prefix(5).filter { $0.isImageMatch && $0.isResident }
        validatePreviews(candidates, revision: revision) { [weak self] available in
            guard let self, !self.closed, self.revision == revision, !self.scopePending else { return }
            self.set(\.searching, to: false)
            self.presentedQuery = query
            self.resultsRevision = revision
            self.directHits = available
            self.publishHits(available)
        }
    }

    private func filterExistingPreviews(_ hits: [SearchHit], complete: @escaping ([SearchHit]) -> Void) {
        let requiresDiskCheck: (SearchHit) -> Bool = { $0.hasPreview || $0.isImageMatch }
        let candidates = hits.filter(requiresDiskCheck)
        guard !candidates.isEmpty else { complete(hits); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let valid = Set(candidates.compactMap { hit in
                SearchHit.existsOnDisk(at: hit.path, kind: hit.kind, permitsDatalessLeaf: false) ? hit.path : nil
            })
            DispatchQueue.main.async {
                complete(hits.filter { !requiresDiskCheck($0) || valid.contains($0.path) })
            }
        }
    }

    private func validatePreviews(_ hits: [SearchHit], revision: UInt64, complete: @escaping ([SearchHit]) -> Void) {
        filterExistingPreviews(hits) { [weak self] available in
            guard let self, !self.closed, self.revision == revision else { return }
            complete(available)
        }
    }

    private func publishWithRelated(_ candidates: [SearchHit]) {
        var seen = Set(directHits.map(\.path))
        let unique = candidates.filter { seen.insert($0.path).inserted }
        let textRelated = Array(unique.filter(\.isSemanticCandidate).prefix(3))
        let imageRelated = Array(unique.filter(\.isImageMatch).prefix(2))
        if imageRelated.isEmpty || directHits.count <= 6 {
            publishHits(directHits + textRelated + imageRelated)
            return
        }
        let selectedDirectIdx = selectedID.flatMap { id in directHits.firstIndex(where: { $0.id == id }) } ?? 0
        let insertAt = min(directHits.count, max(6, selectedDirectIdx + 1))
        var merged = Array(directHits.prefix(insertAt))
        merged.append(contentsOf: imageRelated)
        merged.append(contentsOf: directHits.dropFirst(insertAt))
        merged.append(contentsOf: textRelated)
        publishHits(merged)
    }

    private func publishHits(_ hits: [SearchHit]) {
        let visible = rejectedPaths.isEmpty ? hits : hits.filter { !rejectedPaths.contains($0.path) }
        set(\.hits, to: visible)
        rebuildVisibleResults()
        reconcileSelection()
    }

    private func reconcileSelection() {
        let rows = visibleResults
        if !rows.contains(where: { $0.id == selectedID }) {
            set(\.selectedID, to: rows.first?.id)
        }
    }

    func moveSelection(_ step: Int) {
        let rows = visibleResults
        guard !rows.isEmpty else { return }
        guard let index = rows.firstIndex(where: { $0.id == selectedID }) else {
            set(\.selectedID, to: (step > 0 ? rows.first : rows.last)?.id)
            return
        }
        set(\.selectedID, to: rows[min(max(index + step, 0), rows.count - 1)].id)
    }

    var selectedResult: LauncherResult? {
        guard let row = visibleResults.first(where: { $0.id == selectedID }) else { return nil }
        if case .file = row { return selectedHit.map(LauncherResult.file) }
        return row
    }

    var selectedHit: SearchHit? {
        guard resultsRevision == revision || presentedQuery == query else { return nil }
        return hits.first { $0.path == selectedID }
    }

    func openingFailed() { set(\.searchNotice, to: LauncherNotice(.opening)) }

    func noteActionPerformed(_ action: LaunchAction) {
        if case .application = action.destination { return } // App launches are recorded by the dispatcher.
        frecency.noteOpened(action.id, query: query)
        updateLaunchMatches()
        rebuildVisibleResults()
        reconcileSelection()
    }

    func noteFileOpened(_ hit: SearchHit) {
        frecency.noteOpened(LauncherFrecency.fileID(hit.path), query: query)
        rebuildVisibleResults()
        reconcileSelection()
    }

    func previewFailed() { set(\.searchNotice, to: LauncherNotice(.preview)) }

    func copied(_ action: FileAction) {
        set(\.searchNotice, to: LauncherNotice(action == .copyName ? .copiedName : .copiedPath))
    }

    func containsCurrentFile(_ hit: SearchHit) -> Bool {
        !closed && canSearch && (resultsRevision == revision || presentedQuery == query) && hits.contains(hit)
    }

    func resolve(_ hit: SearchHit, action: FileAction, complete: @escaping (URL) -> Void) {
        guard containsCurrentFile(hit) else { return }
        guard !hit.isRelatedHit || isImageSearch || localModelState == .ready ||
            (textEmbeddingBackend.mode == .localOpenAI && hit.isImageMatch) else { return }
        if action == .preview && hit.kind != "file" { return }
        if action == .copyName || action == .copyPath {
            complete(URL(fileURLWithPath: hit.path))
            return
        }
        guard !actionValidating else { return }
        let intent = actionIntent
        actionValidating = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let exists = SearchHit.existsOnDisk(at: hit.path, kind: hit.kind, permitsDatalessLeaf: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.actionIntent == intent, self.canSearch else { return }
                self.actionValidating = false
                guard exists else {
                    self.removeMissingResult(hit)
                    return
                }
                complete(URL(fileURLWithPath: hit.path))
            }
        }
    }

    private func removeMissingResult(_ hit: SearchHit) {
        actionValidating = false
        rejectedPaths.insert(hit.path)
        if hit.isRelatedHit && !isImageSearch {
            cancelRelatedExcerpts()
        } else {
            directHits.removeAll { $0.path == hit.path }
        }
        publishHits(hits.filter { $0.path != hit.path })
        set(\.searchNotice, to: LauncherNotice(.stale))
    }

    private enum RelatedSearchKind { case semantic, imageOnly }

    private static func semanticQueryShape(_ query: String) -> (han: Int, words: Int, length: Int)? {
        guard !LauncherFileQuery(query).isFiltered else { return nil }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 512, !text.contains("/"), !text.contains("\\"),
              !text.split(whereSeparator: \.isWhitespace).contains(where: { word in
                  let token = String(word)
                  return Self.trailingExtensionRegex.firstMatch(in: token, range: NSRange(location: 0, length: token.utf16.count)) != nil
              }) else { return nil }
        let words = text.split { !$0.isLetter && !$0.isNumber }.count
        let han = text.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }.count
        return (han, words, text.count)
    }

    static func qualifiesForRelatedExcerpts(_ query: String, directCount: Int) -> Bool {
        guard directCount < 8, let shape = semanticQueryShape(query) else { return false }
        return shape.han >= 2 || (shape.words >= 2 && shape.length >= 6)
    }

    static func qualifiesForImageRecall(_ query: String) -> Bool {
        guard let shape = semanticQueryShape(query) else { return false }
        return shape.han >= 1 || (shape.words >= 1 && shape.length >= 3)
    }

    private var installedImageProjector: URL? {
        if let customPath = defaults?.string(forKey: "launcher.imageProjector.v1"),
           !customPath.isEmpty,
           SearchHit.existsOnDisk(at: customPath, kind: "file", permitsDatalessLeaf: false) {
            return URL(fileURLWithPath: customPath)
        }
        if let home = engine.installedGemmaHome {
            return GemmaAssetManager.installedProjector(home: home)
        }
        return GemmaAssetManager.defaultHome.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
    }

    private var hasInstalledImageProjector: Bool {
        if let customPath = defaults?.string(forKey: "launcher.imageProjector.v1"),
           !customPath.isEmpty,
           SearchHit.existsOnDisk(at: customPath, kind: "file", permitsDatalessLeaf: false) {
            return true
        }
        guard let home = engine.installedGemmaHome else { return true }
        return GemmaAssetManager.installedProjector(home: home) != nil
    }

    private var canUseLocalTextModel: Bool {
        localModelState == .available || localModelState == .ready
    }

    private func requiresTextModel(for kind: RelatedSearchKind) -> Bool {
        kind == .semantic || textEmbeddingBackend.mode == .builtin
    }

    private func relatedSearchKind(directCount: Int) -> RelatedSearchKind? {
        guard !scopePending else { return nil }
        let textBackendConfigured = textEmbeddingBackend.mode == .builtin || textEmbeddingBackend.isValidLocalOpenAI
        let textReady = textEmbeddingBackend.mode == .builtin || canUseLocalTextModel
        if textBackendConfigured && textReady && gemmaCoverage?.hasResults == true &&
            Self.qualifiesForRelatedExcerpts(query, directCount: directCount) {
            return .semantic
        }
        if imageCoverage?.hasResults == true && hasInstalledImageProjector && Self.qualifiesForImageRecall(query) {
            return .imageOnly
        }
        return nil
    }

    private func shouldFindRelatedExcerpts(directCount: Int) -> Bool {
        relatedSearchKind(directCount: directCount) != nil
    }

    private func queueRelatedExcerpts() {
        guard resultsRevision == revision, relatedRevision != revision,
              let kind = relatedSearchKind(directCount: directHits.count) else { return }
        if requiresTextModel(for: kind) && !canUseLocalTextModel { return }
        set(\.semanticBusy, to: true)
        let current = revision
        semanticDebounce?.cancel()
        let delay: Duration = kind == .semantic ? .milliseconds(120) : .milliseconds(180)
        semanticDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.closed, self.revision == current else { return }
            if !self.requiresTextModel(for: kind) || self.canUseLocalTextModel {
                self.searchRelatedExcerpts(revision: current, kind: kind)
            } else if self.localModelState != .checking {
                self.set(\.semanticBusy, to: false)
            }
        }
    }

    private func cancelRelatedExcerpts() {
        semanticDebounce?.cancel()
        semanticDebounce = nil
        engine.discardQueuedSemantic()
        if !isImageSearch { engine.discardQueuedImages() }
        set(\.semanticBusy, to: false)
        relatedRevision = nil
        relatedSearchInFlightKind = nil
    }

    private func searchRelatedExcerpts(revision: UInt64, kind: RelatedSearchKind) {
        let complete: (Result<[SearchHit], SearchFailure>) -> Void = { [weak self] reply in
            self?.receiveRelated(reply, revision: revision, kind: kind)
        }
        switch kind {
        case .semantic:
            guard gemmaCoverage?.hasResults == true else {
                set(\.semanticBusy, to: false)
                return
            }
            relatedRevision = revision
            relatedSearchInFlightKind = kind
            set(\.semanticBusy, to: true)
            engine.searchSemantic(query, complete: complete)
        case .imageOnly:
            guard imageCoverage?.hasResults == true else {
                set(\.semanticBusy, to: false)
                return
            }
            if textEmbeddingBackend.mode == .localOpenAI {
                guard let projector = installedImageProjector else {
                    set(\.semanticBusy, to: false)
                    return
                }
                relatedRevision = revision
                relatedSearchInFlightKind = kind
                set(\.semanticBusy, to: true)
                engine.searchImages(query, projector: projector, limit: 3, complete: complete)
            } else {
                relatedRevision = revision
                relatedSearchInFlightKind = kind
                set(\.semanticBusy, to: true)
                engine.searchSemanticImages(query, complete: complete)
            }
        }
    }

    private func receiveRelated(_ reply: Result<[SearchHit], SearchFailure>, revision: UInt64, kind: RelatedSearchKind) {
        guard !closed, self.revision == revision, relatedRevision == revision else { return }
        relatedSearchInFlightKind = nil
        let tracksTextModel = requiresTextModel(for: kind)
        switch reply {
        case .success(let hits):
            if tracksTextModel && localModelState != .ready { indexStatus.set(\.localModelState, to: .ready) }
            validatePreviews(hits.filter(\.isRelatedHit), revision: revision) { [weak self] available in
                guard let self, self.relatedRevision == revision else { return }
                self.publishWithRelated(available)
                self.set(\.semanticBusy, to: false)
            }
        case .failure(let error):
            if tracksTextModel {
                recordModelFailure(error.detail)
                if localModelState == .available {
                    indexStatus.set(\.localModelState, to: .unavailable(.verification))
                }
            }
            publishWithRelated([])
            set(\.semanticBusy, to: false)
            refreshCoverage()
        }
    }

    func applyTextEmbeddingBackend(_ config: TextEmbeddingBackendConfig) {
        var normalized = config
        normalized.baseURL = config.trimmedBaseURL
        normalized.model = config.trimmedModel
        if normalized.mode == .builtin {
            normalized.dimensions = nil
            normalized.signature = nil
        }
        pauseEmbeddings(userInitiated: false)
        cancelModelCheck()
        if modelInspection?.isRunning == true {
            modelInspection?.terminate()
            modelInspection = nil
        }
        textEmbeddingBackend = normalized
        normalized.save(to: defaults)
        engine.setTextEmbeddingBackend(normalized)
        indexStatus.set(\.localModelState, to: .unchecked)
        indexStatus.set(\.embeddingState, to: .idle)
        indexStatus.set(\.embeddingBatch, to: nil)
        indexStatus.set(\.embeddingNotice, to: nil)
        automaticBuildAttempted = false
        if !isImageSearch && hits.contains(where: \.isRelatedHit) {
            publishWithRelated([])
        }
        verifyLocalModel()
        refreshCoverage()
    }

    func fetchOpenAIEmbeddingModels(url: String) async -> Result<[String], SearchFailure> {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoopbackEndpointURL(trimmedURL) else {
            return .failure(SearchFailure(t("仅支持本机回环地址。", "Only loopback addresses are supported.")))
        }
        struct ModelsReply: Decodable { let models: [String] }
        return await withCheckedContinuation { continuation in
            _ = engine.run(["openai-models", "--url", trimmedURL], priority: .userInitiated) { [weak self] response in
                if response.succeeded, let decoded = try? JSONDecoder().decode(ModelsReply.self, from: response.output) {
                    continuation.resume(returning: .success(decoded.models))
                } else {
                    let detail = response.diagnostic.isEmpty
                        ? (self?.t("无法从本机服务获取模型列表。", "Could not fetch models from the local server.") ?? "Could not fetch models.")
                        : response.diagnostic
                    continuation.resume(returning: .failure(SearchFailure(detail)))
                }
            }
        }
    }

    func verifyOpenAIEmbeddingEndpoint(url: String, model modelID: String) async -> Result<LocalModelStatus, SearchFailure> {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let probeConfig = TextEmbeddingBackendConfig(mode: .localOpenAI, baseURL: trimmedURL, model: trimmedModel)
        guard probeConfig.isValidLocalOpenAI else {
            return .failure(SearchFailure(t("请填写有效的本机回环地址和模型 ID。", "Enter a valid loopback endpoint URL and model ID.")))
        }
        return await withCheckedContinuation { continuation in
            _ = engine.run(["model-status"] + probeConfig.openAICliArguments + ["--verify"], priority: .userInitiated) { [weak self] response in
                if let status = try? JSONDecoder().decode(LocalModelStatus.self, from: response.output) {
                    continuation.resume(returning: .success(status))
                } else {
                    let detail = response.diagnostic.isEmpty
                        ? (self?.t("连接验证失败。", "Connection verification failed.") ?? "Verification failed.")
                        : response.diagnostic
                    continuation.resume(returning: .failure(SearchFailure(detail)))
                }
            }
        }
    }

    private func inspectLocalResources() {
        if textEmbeddingBackend.mode == .localOpenAI && !textEmbeddingBackend.isValidLocalOpenAI {
            indexStatus.set(\.localModelState, to: .unavailable(.verification))
            if relatedSearchInFlightKind != .imageOnly {
                set(\.semanticBusy, to: false)
            }
            return
        }
        modelInspection = engine.run(engine.modelStatusArguments(verify: false)) { [weak self] response in
            guard let self, !self.closed, self.localModelState == .unchecked else { return }
            let status = try? JSONDecoder().decode(LocalModelStatus.self, from: response.output)
            let nextState: LocalModelState = response.succeeded && status?.available == true
                ? .available : .unavailable(LocalModelProblem.classify(status?.diagnostic ?? response.diagnostic) ?? .verification)
            self.indexStatus.set(\.localModelState, to: nextState)
            if self.localModelState == .available { self.queueRelatedExcerpts() }
            else if self.textEmbeddingBackend.mode == .builtin || self.relatedSearchInFlightKind != .imageOnly {
                self.set(\.semanticBusy, to: false)
            }
        }
    }

    func verifyLocalModel(then complete: ((Bool) -> Void)? = nil) {
        guard localModelState != .checking else { return }
        if textEmbeddingBackend.mode == .localOpenAI && !textEmbeddingBackend.isValidLocalOpenAI {
            indexStatus.set(\.localModelState, to: .unavailable(.verification))
            handleTextModelVerificationFailure()
            complete?(false)
            return
        }
        modelCheckGeneration &+= 1
        let current = modelCheckGeneration
        indexStatus.set(\.localModelState, to: .checking)
        modelCheck = engine.run(engine.modelStatusArguments(verify: true)) { [weak self] response in
            guard let self, !self.closed, self.modelCheckGeneration == current else { return }
            self.modelCheck = nil
            let status = try? JSONDecoder().decode(LocalModelStatus.self, from: response.output)
            if response.succeeded, let status, status.available, status.verified {
                if self.textEmbeddingBackend.mode == .localOpenAI &&
                    (status.dimensions != self.textEmbeddingBackend.dimensions ||
                     status.signature != self.textEmbeddingBackend.signature) {
                    var updated = self.textEmbeddingBackend
                    updated.dimensions = status.dimensions ?? updated.dimensions
                    updated.signature = status.signature ?? updated.signature
                    self.textEmbeddingBackend = updated
                    updated.save(to: self.defaults)
                    self.engine.setTextEmbeddingBackend(updated)
                    self.refreshCoverage()
                }
                if self.embeddingNotice?.problem == .embeddings {
                    self.indexStatus.set(\.embeddingNotice, to: nil)
                }
                self.indexStatus.set(\.localModelState, to: .ready)
                complete?(true)
                self.queueRelatedExcerpts()
            } else {
                let issue = LocalModelProblem.classify(status?.diagnostic ?? response.diagnostic) ?? .verification
                self.indexStatus.set(\.localModelState, to: .unavailable(issue))
                self.handleTextModelVerificationFailure()
                complete?(false)
            }
        }
    }

    private func handleTextModelVerificationFailure() {
        if textEmbeddingBackend.mode == .localOpenAI {
            if relatedSearchInFlightKind != .imageOnly {
                semanticDebounce?.cancel()
                semanticDebounce = nil
                engine.discardQueuedSemantic()
                relatedRevision = nil
                relatedSearchInFlightKind = nil
                set(\.semanticBusy, to: false)
            }
            if hits.contains(where: \.isSemanticCandidate) {
                publishWithRelated(hits.filter(\.isImageMatch))
            }
            if relatedSearchInFlightKind != .imageOnly,
               relatedSearchKind(directCount: directHits.count) == .imageOnly {
                queueRelatedExcerpts()
            }
        } else {
            cancelRelatedExcerpts()
            if !isImageSearch && hits.contains(where: \.isRelatedHit) { publishWithRelated([]) }
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
            indexStatus.set(\.localModelState, to: .unavailable(issue))
            if embeddingState == .verifying { finishEmbeddings(.idle) }
        }
    }

    func diagnoseFile(_ file: URL) {
        guard !closed, !scopePending, file.isFileURL else { return }
        clearFileDiagnosis()
        let generation = diagnosisGeneration
        let name = file.lastPathComponent
        indexStatus.set(\.fileDiagnosis, to: .checking(name))
        diagnosisProcess = engine.run(engine.diagnoseArguments(path: file.path)) { [weak self] response in
            guard let self, !self.closed, !self.scopePending, self.diagnosisGeneration == generation else { return }
            self.diagnosisProcess = nil
            if response.succeeded, let report = try? JSONDecoder().decode(FileDiagnosis.self, from: response.output) {
                self.indexStatus.set(\.fileDiagnosis, to: .result(name, report))
            } else {
                self.indexStatus.set(\.fileDiagnosis, to: .failed(name))
            }
        }
    }

    func clearFileDiagnosis() {
        diagnosisGeneration &+= 1
        if diagnosisProcess?.isRunning == true { diagnosisProcess?.terminate() }
        diagnosisProcess = nil
        indexStatus.set(\.fileDiagnosis, to: .idle)
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
        indexStatus.set(\.contentFailed, to: false)
        scopeTrustedForLookup = false
        firstNamesReady = false
        indexStatus.set(\.scopePending, to: true)
        syncCanSearch()
        clearFileDiagnosis()
        cancelCoverageRead()
        indexStatus.set(\.gemmaCoverage, to: nil)
        indexStatus.set(\.imageCoverage, to: nil)
        invalidateSearch()
        engine.close()
        indexStatus.set(\.indexNotice, to: nil)
        do {
            try engine.beginScopeUpdate()
        } catch {
            indexStatus.set(\.indexNotice, to: LauncherNotice(.scopeState, error.localizedDescription))
            withWatcherStopped {}
            return
        }
        guard requested.hasAbsolutePaths else {
            indexStatus.set(\.indexNotice, to: LauncherNotice(.scope))
            withWatcherStopped {}
            return
        }
        indexStatus.set(\.embeddingState, to: .idle)
        indexStatus.set(\.embeddingBatch, to: nil)
        indexStatus.set(\.embeddingNotice, to: nil)
        automaticBuildAttempted = false
        let shouldStageDocuments = indexPhase != .ready && requested.documents
        var first = requested
        if shouldStageDocuments { first.documents = false; if first.content_roots != nil { first.content_roots = [] } }
        indexStatus.set(\.indexWork, to: first.documents ? .documents : .names)
        withWatcherStopped { [weak self] in
            self?.scan(first, then: shouldStageDocuments ? requested : nil, contentOnly: contentOnly)
        }
    }

    private func scan(_ scope: IndexScope, then next: IndexScope?, contentOnly: Bool = false) {
        scanGeneration &+= 1
        let generation = scanGeneration
        indexStatus.set(\.scanProgress, to: nil)
        let progressOption = contentOnly ? [] : ["--progress"]
        let arguments = contentOnly ? scope.contentArguments : engine.indexArguments(scope: scope)
        writer = engine.run(arguments + progressOption, onProgress: { [weak self] progress in
            guard let self, !self.closed, self.scanGeneration == generation else { return }
            self.indexStatus.set(\.scanProgress, to: progress)
        }) { [weak self] response in
            guard let self, !self.closed, self.scanGeneration == generation else { return }
            self.scanGeneration &+= 1
            self.writer = nil
            self.indexStatus.set(\.scanProgress, to: nil)
            guard let report = self.report(from: response) else {
                self.firstNamesReady = false
                self.invalidateSearch()
                self.indexStatus.set(\.indexNotice, to: LauncherNotice(.indexing, response.diagnostic))
                self.indexStatus.set(\.indexWork, to: nil)
                return
            }
            if let next {
                // The metadata pass has committed the requested path scope.
                self.firstNamesReady = true
                self.publish(report)
                self.indexStatus.set(\.indexWork, to: .documents)
                self.scan(next, then: nil, contentOnly: next.content_roots != nil)
                return
            }
            do {
                try self.engine.finishScopeUpdate()
                self.indexStatus.set(\.scopePending, to: false)
                self.indexStatus.set(\.savedScope, to: scope)
            } catch {
                self.indexStatus.set(\.indexNotice, to: LauncherNotice(.scopeState, error.localizedDescription))
            }
            self.firstNamesReady = false
            self.scopeTrustedForLookup = !self.scopePending
            self.syncCanSearch()
            self.indexStatus.set(\.indexWork, to: nil)
            self.publish(report)
            self.startWatcherIfReady()
            self.refreshCoverage()
        }
    }

    @discardableResult
    func previewContentScope(roots: [String], filter: ContentFilter?,
                             complete: @escaping @MainActor (ContentScopePreview?) -> Void) -> Process? {
        engine.previewContentScope(roots: roots, filter: filter, complete: complete)
    }

    func setContentPaused(_ paused: Bool) {
        defaults?.set(paused, forKey: "contentIndexingPaused")
        indexStatus.set(\.contentPaused, to: paused)
        if !paused {
            indexStatus.set(\.contentFailed, to: false)
            startContentIfReady()
        }
    }

    private var contentNeedsBatch: Bool {
        !contentPaused && !contentFailed && (contentCoverage?.pending ?? 0) > 0
    }

    private func startContentIfReady() {
        guard canSearch, !scopePending, !closed, indexWork == nil, !contentRunning,
              embeddingState != .verifying, contentNeedsBatch else { return }
        indexStatus.set(\.contentRunning, to: true)
        contentWriter = engine.run(["content", "--max", "8"], priority: .background) { [weak self] response in
            guard let self, !self.closed else { return }
            self.contentWriter = nil
            self.indexStatus.set(\.contentRunning, to: false)
            guard response.succeeded, let batch = try? JSONDecoder().decode(ContentBatch.self, from: response.output) else {
                self.indexStatus.set(\.contentFailed, to: true)
                self.refreshCoverage()
                return
            }
            self.applyContentBatch(batch)
        }
    }

    func applyContentBatch(_ batch: ContentBatch) {
        if batch.indexed > 0 && isSearchPresented && hasQuery {
            scheduleSilentRefresh()
        }
        if batch.processed == 0 && (batch.skipped ?? 0) == 0 && batch.pending > 0 {
            indexStatus.set(\.contentFailed, to: true)
        }
        refreshCoverage(after: .milliseconds(100))
    }

    func setEmbeddingIndexingPaused(_ paused: Bool) {
        defaults?.set(paused, forKey: "gemmaIndexingPaused")
    }

    func refreshCoverageAfterImageBuild() {
        refreshCoverage()
    }

    func buildEmbeddings() {
        guard canBuildEmbeddings else { return }
        defaults?.set(true, forKey: "gemmaIndexingEnabled")
        setEmbeddingIndexingPaused(false)
        automaticBuildAttempted = true
        prepareEmbeddings()
    }

    private func prepareEmbeddings() {
        indexStatus.set(\.embeddingNotice, to: nil)
        if embeddingState != .paused { indexStatus.set(\.embeddingBatch, to: nil) }
        if localModelState == .ready {
            startEmbeddings()
        } else {
            indexStatus.set(\.embeddingState, to: .verifying)
            verifyLocalModel { [weak self] verified in
                guard let self, self.embeddingState == .verifying else { return }
                self.indexStatus.set(\.embeddingState, to: .idle)
                if verified, self.canBuildEmbeddings { self.startEmbeddings() }
                else { self.startContentIfReady() }
            }
        }
    }

    func pauseEmbeddings(userInitiated: Bool = false) {
        if userInitiated { setEmbeddingIndexingPaused(true) }
        switch embeddingState {
        case .verifying:
            cancelModelCheck()
            indexStatus.set(\.localModelState, to: .available)
            indexStatus.set(\.embeddingState, to: .paused)
            refreshCoverage()
        case .running:
            indexStatus.set(\.embeddingState, to: .pausing)
            if engine.supportsStreamingBatches, writer?.isRunning == true {
                writer?.terminate()
            }
        case .idle, .pausing, .paused, .finished:
            break
        }
    }

    private func startEmbeddings() {
        indexStatus.set(\.embeddingState, to: .running)
        indexStatus.set(\.indexWork, to: .embeddings)
        embedNextBatch()
    }

    private func embedNextBatch(batchesSeen: Int = 0, maxBatches: Int? = nil) {
        if engine.supportsStreamingBatches {
            streamEmbeddings()
            return
        }
        let maxBatches = batchesSeen == 0 ? (maxBatches ?? maxEmbeddingBatchesPerTurn?()) : maxBatches
        let arguments = engine.embedArguments(stream: false, max: 32)
        writer = engine.run(arguments, priority: .background) { [weak self] response in
            guard let self, !self.closed else { return }
            self.writer = nil
            guard response.succeeded, let batch = try? JSONDecoder().decode(EmbeddingBatch.self, from: response.output) else {
                self.recordModelFailure(response.diagnostic)
                self.indexStatus.set(\.embeddingNotice, to: LauncherNotice(.embeddings))
                self.finishEmbeddings(.idle)
                return
            }
            let batchesSeen = batchesSeen + 1
            self.indexStatus.set(\.embeddingBatch, to: batch)
            if !batch.has_more {
                self.finishEmbeddings(.finished)
            } else if batch.new_embeddings == 0 && batch.skipped_chunks == 0 {
                self.indexStatus.set(\.embeddingNotice, to: LauncherNotice(.embeddingNoProgress))
                self.finishEmbeddings(.paused)
            } else if self.embeddingState == .running {
                if self.contentNeedsBatch {
                    // Yield one writer turn, then recheck both queues from fresh coverage.
                    self.automaticBuildAttempted = false
                    self.finishEmbeddings(.idle)
                    self.startContentIfReady()
                } else if let maxBatches, batchesSeen >= maxBatches, batch.has_more {
                    self.embeddingStreamGeneration &+= 1
                    self.writer = nil
                    self.automaticBuildAttempted = false
                    self.finishEmbeddings(.idle)
                    self.onEmbeddingsTurnCompleted?()
                } else {
                    let needsSettingsRefresh = self.isSettingsPresented &&
                        (self.lastSettingsCoverageRefresh.map { $0.duration(to: .now) >= .seconds(2) } ?? true)
                    if self.gemmaCoverage?.hasResults != true || needsSettingsRefresh {
                        if self.isSettingsPresented { self.lastSettingsCoverageRefresh = .now }
                        self.refreshCoverage()
                    }
                    self.embedNextBatch(batchesSeen: batchesSeen, maxBatches: maxBatches)
                }
            } else {
                self.finishEmbeddings(.paused)
            }
        }
        // The engine's QoS controls pipe draining; lower the child itself too.
        if let writer { _ = setpriority(PRIO_PROCESS, UInt32(writer.processIdentifier), 10) }
    }

    private func streamEmbeddings() {
        embeddingStreamGeneration &+= 1
        let generation = embeddingStreamGeneration
        let maxBatches = maxEmbeddingBatchesPerTurn?()
        let arguments = engine.embedArguments(stream: true, max: 32)
        var lastBatch: EmbeddingBatch?
        var batchesSeen = 0
        var noProgress = false
        writer = engine.run(arguments, onLine: { [weak self] line in
            guard let self, !self.closed, self.embeddingStreamGeneration == generation,
                  let batch = try? JSONDecoder().decode(EmbeddingBatch.self, from: line) else { return }
            lastBatch = batch
            batchesSeen += 1
            self.indexStatus.set(\.embeddingBatch, to: batch)
            if !batch.has_more { return }
            if batch.new_embeddings == 0 && batch.skipped_chunks == 0 {
                noProgress = true
                self.indexStatus.set(\.embeddingNotice, to: LauncherNotice(.embeddingNoProgress))
                self.writer?.terminate()
                return
            }
            if self.embeddingState == .running {
                if let maxBatches, batchesSeen >= maxBatches, batch.has_more {
                    self.embeddingStreamGeneration &+= 1
                    self.writer?.terminate()
                    self.writer = nil
                    self.automaticBuildAttempted = false
                    self.finishEmbeddings(.idle)
                    self.onEmbeddingsTurnCompleted?()
                    return
                }
                let needsSettingsRefresh = self.isSettingsPresented &&
                    (self.lastSettingsCoverageRefresh.map { $0.duration(to: .now) >= .seconds(2) } ?? true)
                if self.gemmaCoverage?.hasResults != true || needsSettingsRefresh {
                    if self.isSettingsPresented { self.lastSettingsCoverageRefresh = .now }
                    self.refreshCoverage()
                }
            } else if self.writer?.isRunning == true {
                self.writer?.terminate()
            }
        }, priority: .background) { [weak self] response in
            guard let self, !self.closed, self.embeddingStreamGeneration == generation else { return }
            self.writer = nil
            if noProgress || self.embeddingState == .pausing {
                self.finishEmbeddings(.paused)
            } else if let lastBatch, !lastBatch.has_more, response.succeeded {
                self.finishEmbeddings(.finished)
            } else if !response.succeeded || lastBatch == nil {
                self.recordModelFailure(response.diagnostic)
                self.indexStatus.set(\.embeddingNotice, to: LauncherNotice(.embeddings))
                self.finishEmbeddings(.idle)
            } else {
                self.finishEmbeddings(.paused)
            }
        }
        // The engine's QoS controls pipe draining; lower the child itself too.
        if let writer { _ = setpriority(PRIO_PROCESS, UInt32(writer.processIdentifier), 10) }
    }

    private func finishEmbeddings(_ state: EmbeddingState) {
        indexStatus.set(\.indexWork, to: nil)
        indexStatus.set(\.embeddingState, to: state)
        refreshCoverage()
    }

    private func acceptCoverage(from report: IndexReport, includeGemma: Bool = true) {
        guard !scopePending else { return }
        indexStatus.set(\.savedScope, to: report.scope)
        indexStatus.set(\.indexReport, to: report)
        indexStatus.set(\.contentCoverage, to: report.content)
        if includeGemma {
            let previous = gemmaCoverage
            if previous != report.gemma {
                indexStatus.set(\.gemmaCoverage, to: report.gemma)
                if report.gemma?.hasResults != true, previous?.hasResults == true {
                    if report.images?.hasResults != true {
                        cancelRelatedExcerpts()
                        engine.closeSemantic()
                    }
                    if !isImageSearch && hits.contains(where: \.isRelatedHit) {
                        publishWithRelated(report.images?.hasResults == true ? hits.filter(\.isImageMatch) : [])
                    }
                } else if report.gemma?.hasResults == true, previous?.hasResults != true {
                    queueRelatedExcerpts()
                }
            }
        }
        let previousImages = imageCoverage
        if previousImages != report.images {
            indexStatus.set(\.imageCoverage, to: report.images)
            if report.images?.hasResults != true, previousImages?.hasResults == true {
                if gemmaCoverage?.hasResults != true {
                    cancelRelatedExcerpts()
                    engine.closeSemantic()
                }
                if !isImageSearch && hits.contains(where: \.isImageMatch) {
                    publishWithRelated(gemmaCoverage?.hasResults == true ? hits.filter(\.isSemanticCandidate) : [])
                }
            } else if report.images?.hasResults == true, previousImages?.hasResults != true {
                queueRelatedExcerpts()
            }
        }
        if includeGemma, embeddingState == .finished, report.gemma?.pending == true {
            indexStatus.set(\.embeddingState, to: .idle)
            automaticBuildAttempted = false
        }
        // The saved scope in the database decides whether documents are eligible.
        let needsImageBootstrap = (report.images?.enabled == true
            && report.images?.vectors == 0
            && report.images?.pending == true
            && report.images?.limited == false
            && canBootstrapImages?() == true)
            || shouldDeferEmbeddingsToImages?() == true
        if includeGemma, !needsImageBootstrap,
           !automaticBuildAttempted, embeddingState == .idle, canBuildEmbeddings,
           !isEmbeddingIndexingPaused, isImageIndexingActive?() != true,
           defaults?.bool(forKey: "gemmaIndexingEnabled") == true {
            automaticBuildAttempted = true
            prepareEmbeddings()
        }
        startContentIfReady()
        onCoverageAccepted?(report)
    }

    private func refreshCoverage(after delay: Duration = .zero) {
        guard !scopePending, !closed, coverageUpdate == nil else { return }
        coverageUpdate = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.coverageUpdate = nil
            if self.coverageInFlight || self.coverageRead?.isRunning == true {
                self.refreshCoverage(after: .milliseconds(250))
                return
            }
            self.coverageGeneration &+= 1
            let generation = self.coverageGeneration
            self.coverageInFlight = true
            self.coverageRead = self.engine.status(includeScope: true, includeLocalOpenAI: true) { [weak self] response in
                guard let self, self.coverageGeneration == generation, !self.closed else { return }
                self.coverageInFlight = false
                self.coverageRead = nil
                if let report = self.report(from: response) {
                    self.acceptCoverage(from: report)
                } else if self.textEmbeddingBackend.mode == .localOpenAI {
                    if self.localModelState != .checking {
                        let issue = LocalModelProblem.classify(response.diagnostic) ?? .verification
                        self.indexStatus.set(\.localModelState, to: .unavailable(issue))
                    }
                    self.indexStatus.set(\.embeddingNotice, to: LauncherNotice(.embeddings, response.diagnostic))
                }
            }
        }
    }

    private func cancelCoverageRead() {
        coverageUpdate?.cancel()
        coverageUpdate = nil
        coverageInFlight = false
        coverageGeneration &+= 1
        if coverageRead?.isRunning == true { coverageRead?.terminate() }
        coverageRead = nil
    }

    private func report(from response: EngineResponse) -> IndexReport? {
        guard response.succeeded else { return nil }
        return try? JSONDecoder().decode(IndexReport.self, from: response.output)
    }

    private func publish(_ report: IndexReport) {
        indexStatus.set(\.indexPhase, to: .ready)
        indexStatus.set(\.indexReport, to: report)
        syncCanSearch()
        scheduleSearch()
    }

    func restartWatcher() {
        guard !closed, watchSupported == true, !scopePending, indexWork == nil, watcher == nil else { return }
        cancelWatchRetry()
        watchLeaseRetryCount = 0
        startWatcherIfReady()
    }

    private func startWatcherIfReady() {
        guard watchSupported == true, indexPhase == .ready, !scopePending,
              watcher == nil, !closed else { return }
        cancelWatchRetry()
        indexStatus.set(\.watchState, to: .starting)
        indexStatus.set(\.watchNotice, to: nil)
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
            self.indexStatus.set(\.watchProgress, to: active)
        }) { [weak self] response in
            guard let self, !self.closed, self.watchGeneration == generation else { return }
            self.watchGeneration &+= 1
            self.watcher = nil
            self.indexStatus.set(\.watchProgress, to: nil)
            if self.stoppingWatcher {
                self.stoppingWatcher = false
                let next = self.afterWatcherStops
                self.afterWatcherStops = nil
                next?()
            } else if response.diagnostic.contains("predates saved scope settings") ||
                        response.diagnostic.contains("no saved scope;") {
                self.indexStatus.set(\.watchState, to: .needsSetup)
            } else if response.diagnostic.contains("cannot acquire index writer lease"),
                      self.watchLeaseRetryCount < Self.watchLeaseRetryDelays.count {
                let delay = Self.watchLeaseRetryDelays[self.watchLeaseRetryCount]
                self.watchLeaseRetryCount += 1
                let retryGeneration = self.watchGeneration
                self.indexStatus.set(\.watchState, to: .starting)
                self.indexStatus.set(\.watchNotice, to: nil)
                self.watchRetryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self, !self.closed,
                          self.watchGeneration == retryGeneration else { return }
                    self.watchRetryTask = nil
                    self.startWatcherIfReady()
                }
            } else {
                self.indexStatus.set(\.watchState, to: .failed)
                self.indexStatus.set(\.watchNotice, to: LauncherNotice(.watch, response.diagnostic))
            }
        }
    }

    private func watchEvent(_ line: Data) {
        guard !stoppingWatcher, !scopePending,
              let notice = try? JSONDecoder().decode(WatchEvent.self, from: line) else { return }
        if notice.event == .cached {
            guard watchSupportsCachedStart else { return }
            watchLeaseRetryCount = 0
            engine.setCachedHitAccess(true)
            scopeTrustedForLookup = true
            indexStatus.set(\.indexPhase, to: .ready)
            syncCanSearch()
            if hasQuery { scheduleSearch(keepAction: true) }
            return
        }
        let accessPhaseChanged = notice.event == .ready && engine.checksCachedHitAccess
        let becameReady = notice.event == .ready && !canSearch
        if notice.event == .ready {
            watchLeaseRetryCount = 0
            engine.setCachedHitAccess(false)
            scopeTrustedForLookup = true
            indexStatus.set(\.indexPhase, to: .ready)
            syncCanSearch()
            indexStatus.set(\.watchState, to: .running)
        }
        indexStatus.set(\.watchProgress, to: nil)
        let setupIncomplete = indexReport == nil || savedScope == nil ||
            (contentCoverage?.pending ?? 0) > 0 ||
            (gemmaCoverage?.documents_enabled == true && gemmaCoverage?.pending == true) ||
            (imageCoverage?.enabled == true && imageCoverage?.pending == true && imageCoverage?.limited == false)
        if isSettingsPresented || setupIncomplete || notice.event == .ready {
            refreshCoverage(after: .milliseconds(400))
        }
        if becameReady {
            if hasQuery { scheduleSearch(keepAction: !accessPhaseChanged) }
            return
        }
        guard isSearchPresented, hasQuery else { return }
        scheduleSilentRefresh(delay: accessPhaseChanged ? .zero : .milliseconds(1200))
    }

    private func cancelSilentRefresh() {
        silentRefreshTask?.cancel()
        silentRefreshTask = nil
        silentRefreshRunning = false
        silentRefreshPending = false
        silentRefreshGeneration &+= 1
    }

    private func scheduleSilentRefresh(delay: Duration = .milliseconds(1200)) {
        guard !closed, isSearchPresented, hasQuery, canSearch, !scopePending, !isImageSearch else { return }
        if silentRefreshRunning {
            silentRefreshPending = true
            return
        }
        guard silentRefreshTask == nil else { return }
        let generation = silentRefreshGeneration
        silentRefreshTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, !self.closed, self.silentRefreshGeneration == generation else { return }
            self.silentRefreshTask = nil
            self.performSilentRefresh()
        }
    }

    private func performSilentRefresh() {
        guard !closed, isSearchPresented, hasQuery, canSearch, !scopePending, !isImageSearch else { return }
        silentRefreshRunning = true
        silentRefreshPending = false
        silentRefreshGeneration &+= 1
        let generation = silentRefreshGeneration
        let currentRevision = revision
        let term = query
        let fileQuery = LauncherFileQuery(term)
        let searchesText = fileQuery.kind != "folder" && fileQuery.words.count >= 2 &&
            gemmaCoverage?.documents_enabled != false
        var names: Result<[SearchHit], SearchFailure>?
        var text: Result<[SearchHit], SearchFailure>? = searchesText ? nil : .success([])

        let finish = { [weak self] in
            guard let self, !self.closed, self.silentRefreshGeneration == generation,
                  self.revision == currentRevision, self.isSearchPresented, self.query == term else { return }
            guard names != nil && text != nil else { return }
            self.silentRefreshRunning = false
            if case .failure = names, (try? text?.get())?.isEmpty != false {
                if self.silentRefreshPending { self.scheduleSilentRefresh() }
                return
            }
            let nameHits = (try? names?.get()) ?? []
            let strongNames = nameHits.filter { $0.matched_by != "path" }
            let bodyHits = (try? text?.get()) ?? []
            let weakPaths = nameHits.filter { $0.matched_by == "path" }
            var seen = Set<String>()
            let ranked = [strongNames, bodyHits, weakPaths].flatMap { self.frecency.rankFiles($0, query: term) }
            let lexical = Array(ranked.filter { seen.insert($0.path).inserted }.prefix(60))
            let candidateKind = self.relatedSearchKind(directCount: lexical.count)
            let relatedKind: RelatedSearchKind? = candidateKind.flatMap { kind in
                (!self.requiresTextModel(for: kind) || self.localModelState == .ready) ? kind : nil
            }
            let existingRelated = relatedKind.map { kind in
                kind == .imageOnly ? self.hits.filter(\.isImageMatch) : self.hits.filter(\.isRelatedHit)
            } ?? []
            self.presentedQuery = term
            self.directHits = lexical
            self.resultsRevision = currentRevision
            self.publishWithRelated(existingRelated)
            if let relatedKind {
                let replyHandler: (Result<[SearchHit], SearchFailure>) -> Void = { [weak self] reply in
                    guard let self, !self.closed, self.silentRefreshGeneration == generation,
                          self.revision == currentRevision, self.isSearchPresented, self.query == term else { return }
                    guard case .success(let related) = reply else { return }
                    self.filterExistingPreviews(related.filter(\.isRelatedHit)) { [weak self] available in
                        guard let self, !self.closed, self.silentRefreshGeneration == generation,
                              self.revision == currentRevision, self.isSearchPresented, self.query == term else { return }
                        self.publishWithRelated(available)
                    }
                }
                switch relatedKind {
                case .semantic:
                    self.engine.searchSemantic(term, complete: replyHandler)
                case .imageOnly:
                    if self.textEmbeddingBackend.mode == .localOpenAI {
                        if let projector = self.installedImageProjector {
                            self.engine.searchImages(term, projector: projector, limit: 3, complete: replyHandler)
                        }
                    } else {
                        self.engine.searchSemanticImages(term, complete: replyHandler)
                    }
                }
            }
            if self.silentRefreshPending { self.scheduleSilentRefresh() }
        }

        engine.search(fileQuery.engineQuery, mode: "name") { [weak self] result in
            guard let self, !self.closed, self.silentRefreshGeneration == generation,
                  self.revision == currentRevision, self.isSearchPresented, self.query == term else { return }
            names = result.map { $0.filter { !$0.hasPreview } }
            finish()
        }
        guard searchesText else { return }
        engine.search(fileQuery.engineQuery, mode: "text") { [weak self] response in
            guard let self, !self.closed, self.silentRefreshGeneration == generation,
                  self.revision == currentRevision, self.isSearchPresented, self.query == term else { return }
            switch response {
            case .success(let hits):
                self.filterExistingPreviews(hits) { [weak self] available in
                    guard let self, !self.closed, self.silentRefreshGeneration == generation,
                          self.revision == currentRevision, self.isSearchPresented, self.query == term else { return }
                    text = .success(available)
                    finish()
                }
            case .failure(let failure):
                text = .failure(failure)
                finish()
            }
        }
    }

    private func withWatcherStopped(_ next: @escaping () -> Void) {
        cancelWatchRetry()
        watchLeaseRetryCount = 0
        if watchSupported == true { indexStatus.set(\.watchState, to: .paused) }
        indexStatus.set(\.watchProgress, to: nil)
        engine.setCachedHitAccess(false)
        guard let watcher else { next(); return }
        stoppingWatcher = true
        afterWatcherStops = next
        if watcher.isRunning { watcher.terminate() }
    }
}
