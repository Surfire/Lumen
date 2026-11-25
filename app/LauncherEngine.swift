import Darwin
import Foundation

struct SearchHit: Decodable, Equatable, Identifiable {
    let path: String
    let name: String
    let kind: String
    let availability: String
    let matched_by: String
    let snippet: String?
    let document_stamp: String?
    let pdf_page: Int?
    var id: String { path }
    var isLocal: Bool { availability == "local" }
    var isCloudReference: Bool { availability == "placeholder" || availability == "provider_metadata_only" }
    var isImageMatch: Bool { matched_by == "image_embedding" }
    var isSemanticCandidate: Bool { matched_by == "semantic_candidate" }
    var hasPreview: Bool { isLocal && snippet != nil }

    func pathStamp() -> String? {
        Self.pathStamp(at: path, kind: kind, permitsDatalessLeaf: isCloudReference)
    }

    static func pathStamp(at path: String, kind: String, permitsDatalessLeaf: Bool = false) -> String? {
        pathAttributes(at: path, kind: kind, permitsDatalessLeaf: permitsDatalessLeaf).map(filesystemStamp)
    }

    static func pathAttributes(at path: String, kind: String, permitsDatalessLeaf: Bool = false) -> stat? {
        guard path.hasPrefix("/") else { return nil }
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            return nil
        }
        defer { _ = setiopolicy_np(policy, scope, prior) }

        // Check parents from the root so a replaced symlink or dataless directory cannot redirect the action.
        let components = path.split(separator: "/")
        var ancestor = ""
        for part in components.dropLast() {
            ancestor += "/" + part
            var stat = Darwin.stat()
            guard lstat(ancestor, &stat) == 0, stat.st_mode & S_IFMT == S_IFDIR,
                  stat.st_flags & UInt32(SF_DATALESS) == 0
            else { return nil }
        }
        var stat = Darwin.stat()
        guard lstat(path, &stat) == 0,
              stat.st_mode & S_IFMT == (kind == "directory" ? S_IFDIR : S_IFREG),
              permitsDatalessLeaf || stat.st_flags & UInt32(SF_DATALESS) == 0
        else { return nil }
        return stat
    }

    static func filesystemStamp(_ stat: stat) -> String {
        // Match the Rust document_state stamp, including the unsigned Unix device conversion.
        let device = UInt64(bitPattern: Int64(stat.st_dev))
        let size = UInt64(bitPattern: Int64(stat.st_size))
        let modified = stat.st_mtimespec
        let changed = stat.st_ctimespec
        return "\(device):\(stat.st_ino):\(size):\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)"
    }
}

struct IndexReport: Decodable, Equatable {
    let items: Int
    let entries_unreadable: Int?
    let placeholders: Int?
    let documents: Int?
    let documents_not_read: Int?
    let embedded_chunks: Int?
    let gemma: GemmaCoverage?
    let scope: IndexScope?
    let content: ContentCoverage?
    let unverified: Int?
}

struct ContentCoverage: Decodable, Equatable {
    let pending: Int
    let checked: Int
    let total: Int
}

struct ContentBatch: Decodable {
    let processed: Int
    let indexed: Int
    let pending: Int
}

struct GemmaCoverage: Decodable, Equatable {
    let documents_enabled: Bool
    let embedded_chunks: Int
    let skipped_chunks: Int
    let pending: Bool
    let limited: Bool
    let chunk_limit: Int

    var hasResults: Bool { documents_enabled && embedded_chunks > 0 }
    var complete: Bool { hasResults && !pending }
}

struct IndexProgress: Decodable, Equatable {
    let event: String
    let phase: String
    let entries: Int
    let elapsed_ms: Int
    let estimated_total: Int?
    let eta_seconds: Double?

    var fraction: Double? {
        guard let total = estimated_total, total > 0, total >= entries else { return nil }
        return Double(entries) / Double(total)
    }

    var eta: TimeInterval? {
        guard let seconds = eta_seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

struct IndexScope: Decodable, Equatable {
    var roots: [String] = []
    var allow: [String] = []
    var deny: [String] = []
    var documents = false
    var content_roots: [String]? = nil

    var contentFolders: [String] {
        get { content_roots ?? [] }
        set { content_roots = newValue; documents = !newValue.isEmpty }
    }

    private var effectiveRoots: [String] { roots.isEmpty ? (allow.isEmpty ? ["/"] : allow) : roots }

    func sharesNameScope(with other: IndexScope) -> Bool {
        Set(effectiveRoots) == Set(other.effectiveRoots) && Set(allow) == Set(other.allow) && Set(deny) == Set(other.deny)
    }

    var previouslyAuthorizedDocumentFolders: [String] {
        guard documents else { return [] }
        func contains(_ root: String, _ path: String) -> Bool {
            root == "/" || path == root || path.hasPrefix(root + "/")
        }
        let folders = allow.isEmpty ? effectiveRoots : effectiveRoots.flatMap { root in
            allow.compactMap { allowed in
                if contains(root, allowed) { return allowed }
                return contains(allowed, root) ? root : nil
            }
        }
        return Array(Set(folders.filter { $0.hasPrefix("/") && $0 != "/" })).sorted()
    }

    static func storedPaths(_ key: String, in defaults: UserDefaults?) -> [String] {
        if let paths = defaults?.stringArray(forKey: key + "Paths") { return paths }
        return (defaults?.string(forKey: key) ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func folderPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        // Match the engine's spelling for macOS's two fixed aliases.
        if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") {
            return "/private" + path
        }
        return path
    }

    var hasAbsolutePaths: Bool { (roots + allow + deny + contentFolders).allSatisfy { $0.hasPrefix("/") } }

    var arguments: [String] {
        let name = allow.flatMap { ["--allow", $0] } + deny.flatMap { ["--deny", $0] }
        if let content_roots {
            return name + ["--separate-content"] + content_roots.flatMap { ["--content-root", $0] }
                + (content_roots.isEmpty ? [] : ["--bundled-pdf-helper"])
        }
        return name + (documents ? ["--documents", "--bundled-pdf-helper"] : [])
    }

    var contentArguments: [String] {
        ["content-scope"] + contentFolders.flatMap { ["--content-root", $0] }
            + (contentFolders.isEmpty ? [] : ["--bundled-pdf-helper"])
    }

}

struct EngineResponse {
    let exitStatus: Int32
    let output: Data
    let errors: Data
    var succeeded: Bool { exitStatus == 0 }
    var diagnostic: String {
        String(decoding: errors.isEmpty ? output : errors, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class LauncherEngine {
    let executable: URL
    let database: URL
    private let root: URL?
    private var connection: SearchConnection?
    private var semanticConnection: SearchConnection?
    private var imageConnection: SearchConnection?
    private let gemmaHome: URL?
    private let requestTimeout: Duration
    private var nextID: UInt64 = 0
    private(set) var checksCachedHitAccess = false
    private var legacyValidation = false

    func setCachedHitAccess(_ enabled: Bool) {
        guard checksCachedHitAccess != enabled else { return }
        checksCachedHitAccess = enabled
        // M1 accepts access checking only as a startup flag; don't leave that server running after ready.
        close()
    }

    init(executable: URL, database: URL, syntheticRoot: URL? = nil, gemmaHome: URL? = nil,
         requestTimeout: Duration = .seconds(20)) {
        self.executable = executable
        self.database = database
        self.root = syntheticRoot
        self.gemmaHome = gemmaHome
        self.requestTimeout = requestTimeout
    }

    var hasDatabase: Bool {
        FileManager.default.fileExists(atPath: database.path)
    }

    private var pendingScopeFile: URL {
        database.deletingLastPathComponent().appendingPathComponent(".\(database.lastPathComponent).scope-update-pending")
    }

    var hasPendingScope: Bool { FileManager.default.fileExists(atPath: pendingScopeFile.path) }

    // This marker only blocks resumption. The engine's database owns the scope values.
    func beginScopeUpdate() throws {
        let directory = database.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data().write(to: pendingScopeFile, options: .atomic)
    }

    func finishScopeUpdate() throws {
        try FileManager.default.removeItem(at: pendingScopeFile)
    }

    private func arguments(_ command: [String]) -> [String] {
        let guarded = checksCachedHitAccess && ["query", "serve", "semantic-serve", "image-serve"].contains(command.first ?? "")
        let command = guarded ? Array(command.prefix(1)) + ["--check-access"] + command.dropFirst() : command
        return ["--db", database.path] + command
    }

    func indexArguments(scope: IndexScope) -> [String] {
        let roots = root.map { [$0.path] } ?? scope.roots
        return ["index"] + roots.flatMap { ["--root", $0] } + scope.arguments
    }


    func run(
        _ command: [String], onLine: ((Data) -> Void)? = nil,
        onProgress: ((IndexProgress) -> Void)? = nil, priority: DispatchQoS.QoSClass = .utility,
        complete: @escaping @MainActor (EngineResponse) -> Void
    ) -> Process? {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments(command)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch {
            DispatchQueue.main.async {
                complete(EngineResponse(exitStatus: -1, output: Data(), errors: Data(error.localizedDescription.utf8)))
            }
            return nil
        }

        // Both pipes are drained while the child is running, including for long-lived watch.
        Self.drain(process, priority: priority, readOutput: {
            if let onLine {
                Self.readLines(stdout.fileHandleForReading) { data in
                    DispatchQueue.main.async { onLine(data) }
                }
                return Data()
            }
            return (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        }, readErrors: {
            var recent = Data()
            func remember(_ bytes: Data) {
                recent.append(bytes.suffix(65_536))
                if recent.count > 65_536 { recent.removeFirst(recent.count - 65_536) }
            }
            if let onProgress {
                Self.readLines(stderr.fileHandleForReading) { line in
                    if let progress = try? JSONDecoder().decode(IndexProgress.self, from: line),
                       progress.event == "progress", progress.entries >= 0, progress.elapsed_ms >= 0 {
                        DispatchQueue.main.async { onProgress(progress) }
                    } else {
                        remember(line)
                        remember(Data([10]))
                    }
                }
            } else {
                return Self.readTail(stderr.fileHandleForReading)
            }
            return recent
        }, complete: complete)
        return process
    }

    fileprivate static func drain(_ process: Process, priority: DispatchQoS.QoSClass,
                                  readOutput: @escaping () -> Data, readErrors: @escaping () -> Data,
                                  complete: @escaping @MainActor (EngineResponse) -> Void) {
        // Each child needs independent readers. In particular a long-lived watch/serve
        // cannot block stderr draining for other children or occupy a cooperative thread.
        let readers = DispatchGroup()
        var output = Data(), errors = Data()
        readers.enter()
        DispatchQueue(label: "lumen.pipe.stdout", qos: DispatchQoS(qosClass: priority, relativePriority: 0)).async {
            let data = readOutput()
            process.waitUntilExit()
            DispatchQueue.main.async {
                output = data
                readers.leave()
            }
        }
        readers.enter()
        DispatchQueue(label: "lumen.pipe.stderr", qos: .utility).async {
            let data = readErrors()
            DispatchQueue.main.async {
                errors = data
                readers.leave()
            }
        }
        // Both readers enqueue their final line ahead of completion.
        readers.notify(queue: .main) {
            complete(EngineResponse(exitStatus: process.terminationStatus, output: output, errors: errors))
        }
    }

    nonisolated fileprivate static func readTail(_ file: FileHandle) -> Data {
        var tail = Data()
        while case let chunk = file.availableData, !chunk.isEmpty {
            tail.append(chunk.suffix(65_536))
            if tail.count > 65_536 { tail.removeFirst(tail.count - 65_536) }
        }
        return tail
    }

    var nameSearchBusy: Bool { connection?.isBusy == true }

    func warmNameSearch() {
        _ = try? connect(\.connection, command: ["serve"])
    }

    func search(_ query: String, mode: String, complete: @escaping (Result<[SearchHit], SearchFailure>) -> Void) {
        submit(query, mode: mode, limit: mode == "text" ? 24 : 60, to: \.connection, command: ["serve"], complete: complete)
    }

    // nil means the server explicitly rejected the validation operation as unsupported.
    func validate(_ hits: [SearchHit], explicit: Bool = false,
                  complete: @escaping (Result<[Bool]?, SearchFailure>) -> Void) {
        guard !legacyValidation else { complete(.success(nil)); return }
        nextID &+= 1
        let request = SearchRequest(id: nextID, op: "validate", hits: hits.map(ValidationHit.init))
        submit(request, to: \.connection, command: ["serve"], idleTimeout: nil, explicit: explicit) { [weak self] result in
            switch result {
            case .success(let reply):
                guard let valid = reply.valid, valid.count == hits.count else {
                    complete(.failure(SearchFailure("Invalid validation response from lumen serve")))
                    return
                }
                complete(.success(valid))
            case .failure(let error):
                let detail = error.detail.lowercased()
                if (detail.contains("missing field") && detail.contains("query")) ||
                    detail.contains("unsupported op") || detail.contains("unknown op") {
                    self?.legacyValidation = true
                    complete(.success(nil))
                } else { complete(.failure(error)) }
            }
        }
    }

    func searchSemantic(_ query: String, complete: @escaping (Result<[SearchHit], SearchFailure>) -> Void) {
        submit(query, mode: "semantic", limit: 12, to: \.semanticConnection,
               command: ["semantic-serve"] + gemmaOptions, idleTimeout: .seconds(45), complete: complete)
    }

    func searchImages(_ query: String, projector: URL, complete: @escaping (Result<[SearchHit], SearchFailure>) -> Void) {
        submit(query, mode: "semantic", limit: 5, to: \.imageConnection,
               command: ["image-serve", "--projector", projector.path] + gemmaOptions,
               idleTimeout: .seconds(45), complete: complete)
    }

    func closeImages() {
        imageConnection?.stop()
        imageConnection = nil
    }

    func discardQueuedImages() { imageConnection?.discardQueued() }

    var gemmaOptions: [String] { gemmaHome.map { ["--gemma-home", $0.path] } ?? [] }

    private func submit(_ query: String, mode: String, limit: Int,
                        to lane: ReferenceWritableKeyPath<LauncherEngine, SearchConnection?>,
                        command: [String], idleTimeout: Duration? = nil, complete: @escaping SearchCompletion) {
        nextID &+= 1
        let request = SearchRequest(id: nextID, query: query, mode: mode, limit: limit,
                                    check_access: command.first == "serve" ? checksCachedHitAccess : nil)
        submit(request, to: lane, command: command, idleTimeout: idleTimeout) { result in
            complete(result.flatMap { reply in
                reply.hits.map { .success($0) } ?? .failure(SearchFailure("Invalid search response from lumen serve"))
            })
        }
    }

    private func submit(_ request: SearchRequest, to lane: ReferenceWritableKeyPath<LauncherEngine, SearchConnection?>,
                        command: [String], idleTimeout: Duration?, explicit: Bool = false,
                        complete: @escaping ServeCompletion) {
        do {
            let server = try connect(lane, command: command, idleTimeout: idleTimeout)
            server.enqueue(request, explicit: explicit, complete: complete)
        } catch {
            DispatchQueue.main.async { complete(.failure(SearchFailure(error.localizedDescription))) }
        }
    }

    private func connect(_ lane: ReferenceWritableKeyPath<LauncherEngine, SearchConnection?>, command: [String],
                         idleTimeout: Duration? = nil) throws -> SearchConnection {
        if let connection = self[keyPath: lane], connection.isRunning { return connection }
        let started = SearchConnection(executable: executable, arguments: arguments(command),
                                       requestTimeout: requestTimeout, idleTimeout: idleTimeout) { [weak self] request, explicit, complete in
            self?.submit(request, to: lane, command: command, idleTimeout: idleTimeout,
                         explicit: explicit, complete: complete)
        }
        try started.start()
        self[keyPath: lane] = started
        return started
    }

    func discardQueuedSearch() { connection?.discardQueued() }
    func discardQueuedSemantic() { semanticConnection?.discardQueued() }

    func closeSemantic() {
        semanticConnection?.stop()
        semanticConnection = nil
    }

    func close() {
        connection?.stop()
        connection = nil
        closeSemantic()
        closeImages()
    }

    nonisolated static func readLines(_ file: FileHandle, line: (Data) -> Void) {
        var pending = Data()
        while case let chunk = file.availableData, !chunk.isEmpty {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                line(Data(pending.prefix(upTo: end)))
                pending.removeSubrange(pending.startIndex...end)
            }
        }
        if !pending.isEmpty { line(pending) }
    }
}

struct SearchFailure: Error {
    let detail: String
    init(_ detail: String) { self.detail = detail }
}

private typealias SearchCompletion = (Result<[SearchHit], SearchFailure>) -> Void

private typealias ServeCompletion = (Result<SearchReply, SearchFailure>) -> Void

private struct SearchRequest: Encodable {
    let id: UInt64
    var query: String? = nil
    var mode: String? = nil
    var limit: Int? = nil
    var check_access: Bool? = nil
    var op: String? = nil
    var hits: [ValidationHit]? = nil
}

private struct ValidationHit: Encodable {
    let path: String
    let kind: String
    let availability: String
    let document_stamp: String?

    init(_ hit: SearchHit) {
        path = hit.path
        kind = hit.kind
        availability = hit.availability
        document_stamp = hit.document_stamp
    }
}

private struct SearchReply: Decodable {
    let id: UInt64?
    let hits: [SearchHit]?
    let valid: [Bool]?
    let error: String?
}

@MainActor
private final class SearchConnection {
    private struct Pending {
        let request: SearchRequest
        let explicit: Bool
        let complete: ServeCompletion
    }

    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let inputQueue = DispatchQueue(label: "lumen.pipe.stdin", qos: .userInitiated)
    private var active: Pending?
    private var queued: [Pending] = []
    private let requestTimeout: Duration
    private let idleTimeout: Duration?
    private let restartWith: (SearchRequest, Bool, @escaping ServeCompletion) -> Void
    private var deadline: Task<Void, Never>?
    private var stopped = false

    var isRunning: Bool { !stopped && process.isRunning }
    var isBusy: Bool { active != nil }

    init(executable: URL, arguments: [String], requestTimeout: Duration, idleTimeout: Duration?,
         restartWith: @escaping (SearchRequest, Bool, @escaping ServeCompletion) -> Void) {
        self.requestTimeout = requestTimeout
        self.idleTimeout = idleTimeout
        self.restartWith = restartWith
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        // A child that exits while a request is written must not signal the launcher.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let process = self.process
        let output = stdout.fileHandleForReading
        let errors = stderr.fileHandleForReading
        LauncherEngine.drain(process, priority: .userInitiated, readOutput: { [weak self] in
            LauncherEngine.readLines(output) { bytes in
                DispatchQueue.main.async { [weak self] in self?.reply(bytes) }
            }
            return Data()
        }, readErrors: { LauncherEngine.readTail(errors) }) { [weak self] response in
            self?.fail(SearchFailure(response.diagnostic))
        }
    }

    func enqueue(_ request: SearchRequest, explicit: Bool, complete: @escaping ServeCompletion) {
        let pending = Pending(request: request, explicit: explicit, complete: complete)
        if explicit { queued.insert(pending, at: 0) }
        else {
            if let mode = request.mode { queued.removeAll { $0.request.mode == mode } }
            queued.append(pending)
        }
        sendNext()
    }

    func discardQueued() { queued.removeAll { !$0.explicit } }

    func stop() {
        guard !stopped else { return }
        stopped = true
        deadline?.cancel()
        deadline = nil
        active = nil
        queued.removeAll()
        if process.isRunning { process.terminate() }
        let input = stdin.fileHandleForWriting
        inputQueue.async { try? input.close() }
    }

    private func sendNext() {
        guard active == nil, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        active = next
        armDeadline(requestID: next.request.id)
        let input = stdin.fileHandleForWriting
        let request = next.request
        inputQueue.async { [weak self] in
            do {
                var bytes = try JSONEncoder().encode(request)
                bytes.append(10)
                try input.write(contentsOf: bytes)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active?.request.id == request.id else { return }
                    self.fail(SearchFailure(error.localizedDescription))
                }
            }
        }
    }

    private func reply(_ bytes: Data) {
        guard let active else { return }
        guard let reply = try? JSONDecoder().decode(SearchReply.self, from: bytes),
              reply.id == active.request.id || reply.id == nil && reply.error != nil
        else {
            fail(SearchFailure("Invalid response from lumen serve"))
            return
        }
        self.active = nil
        deadline?.cancel()
        deadline = nil
        if let error = reply.error { active.complete(.failure(SearchFailure(error))) }
        else { active.complete(.success(reply)) }
        if !stopped && self.active == nil && queued.isEmpty { armDeadline() }
        sendNext()
    }

    private func armDeadline(requestID: UInt64? = nil) {
        deadline?.cancel()
        guard let timeout = requestID == nil ? idleTimeout : requestTimeout else { return }
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.active?.request.id == requestID else { return }
            let active = self.active, queued = self.queued
            self.stop()
            guard let active else { return }
            // Install the replacement before notifying a caller that may submit again.
            for item in queued { self.restartWith(item.request, item.explicit, item.complete) }
            active.complete(.failure(SearchFailure("lumen search request timed out")))
        }
    }

    private func fail(_ error: SearchFailure) {
        let pending = [active].compactMap { $0 } + queued
        stop()
        pending.forEach { $0.complete(.failure(error)) }
    }
}
