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
    var isPlaceholder: Bool { availability == "placeholder" }
    var isResident: Bool { availability == "local" || availability == "provider_metadata_only" }
    var isLocal: Bool { isResident }
    var isCloudReference: Bool { availability == "placeholder" || availability == "provider_metadata_only" }
    var isImageMatch: Bool { matched_by == "image_embedding" }
    var isSemanticCandidate: Bool { matched_by == "semantic_candidate" }
    var hasPreview: Bool { isResident && snippet != nil }

    func pathStamp() -> String? {
        Self.pathStamp(at: path, kind: kind, permitsDatalessLeaf: isCloudReference)
    }

    static func pathStamp(at path: String, kind: String, permitsDatalessLeaf: Bool = false) -> String? {
        pathAttributes(at: path, kind: kind, permitsDatalessLeaf: permitsDatalessLeaf).map(filesystemStamp)
    }

    static func existsOnDisk(at path: String, kind: String, permitsDatalessLeaf: Bool = false) -> Bool {
        statOnDisk(at: path, kind: kind, permitsDatalessLeaf: permitsDatalessLeaf) != nil
    }

    static func statOnDisk(at path: String, kind: String, permitsDatalessLeaf: Bool = false) -> stat? {
        guard path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            return nil
        }
        defer { _ = setiopolicy_np(policy, scope, prior) }

        let expected: mode_t = kind == "directory" ? S_IFDIR : S_IFREG
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        let mode = info.st_mode & S_IFMT
        if mode == S_IFLNK {
            var target = Darwin.stat()
            guard fstatat(AT_FDCWD, path, &target, 0) == 0,
                  target.st_mode & S_IFMT == expected,
                  permitsDatalessLeaf || (info.st_flags & UInt32(SF_DATALESS) == 0 && target.st_flags & UInt32(SF_DATALESS) == 0)
            else { return nil }
            return target
        }
        guard mode == expected,
              permitsDatalessLeaf || info.st_flags & UInt32(SF_DATALESS) == 0
        else { return nil }
        return info
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
        return "\(device):\(stat.st_ino):\(size):\(modified.tv_sec):\(modified.tv_nsec)"
    }

    static func stampsMatch(_ stored: String, _ live: String) -> Bool {
        let left = stored.split(separator: ":", omittingEmptySubsequences: false)
        let right = live.split(separator: ":", omittingEmptySubsequences: false)
        guard left.count >= 5, right.count >= 5 else { return stored == live }
        return left.prefix(5).elementsEqual(right.prefix(5))
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
    let skipped: Int?

    init(processed: Int, indexed: Int, pending: Int, skipped: Int? = nil) {
        self.processed = processed
        self.indexed = indexed
        self.pending = pending
        self.skipped = skipped
    }
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
    // Coordinator: flip to true after merging rust-pipelines (--stream on embed / image-index).
    private static let streamIndexingEnabled = true

    let executable: URL
    let database: URL
    let usesCoreLibrary: Bool
    let supportsStreamingBatches: Bool
    private let root: URL?
    let core: CoreSearchConnection?
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
        // Subprocess servers accept access checking only at startup; keep the in-process core open.
        closeSubprocesses()
    }

    init(executable: URL, database: URL, syntheticRoot: URL? = nil, gemmaHome: URL? = nil,
         requestTimeout: Duration = .seconds(20), supportsStreamingBatches: Bool? = nil) {
        self.executable = executable
        self.database = database
        self.root = syntheticRoot
        self.gemmaHome = gemmaHome
        self.requestTimeout = requestTimeout
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        let bundled = resources.appendingPathComponent("lumen")
        let isBundled = executable.standardizedFileURL.path == bundled.standardizedFileURL.path
        self.usesCoreLibrary = isBundled
        self.supportsStreamingBatches = supportsStreamingBatches ?? (isBundled && Self.streamIndexingEnabled)
        self.core = isBundled ? CoreSearchConnection(database: database, root: syntheticRoot) : nil
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

    var nameSearchBusy: Bool { core?.isNameBusy == true || connection?.isBusy == true }

    @discardableResult
    func status(includeScope: Bool, complete: @escaping @MainActor (EngineResponse) -> Void) -> Process? {
        if let core {
            nextID &+= 1
            core.status(SearchRequest(id: nextID, op: "status", include_scope: includeScope), complete: complete)
            return nil
        }
        let command = includeScope ? ["status", "--include-scope"] : ["status"]
        return run(command, complete: complete)
    }

    func warmNameSearch() {
        if let core { core.warm() }
        else { _ = try? connect(\.connection, command: ["serve"]) }
    }

    func search(_ query: String, mode: String, complete: @escaping (Result<[SearchHit], SearchFailure>) -> Void) {
        submit(query, mode: mode, limit: mode == "text" ? 24 : 60, to: \.connection, command: ["serve"], complete: complete)
    }

    // nil means the server explicitly rejected the validation operation as unsupported.
    func validate(_ hits: [SearchHit], explicit: Bool = false,
                  complete: @escaping (Result<[Bool]?, SearchFailure>) -> Void) {
        if let core {
            nextID &+= 1
            core.enqueue(SearchRequest(id: nextID, op: "validate", hits: hits.map(ValidationHit.init)),
                         explicit: explicit) { result in
                complete(result.flatMap { reply in
                    guard let flags = reply.valid, flags.count == hits.count else {
                        return .failure(SearchFailure("Invalid validation response from lumen core"))
                    }
                    return .success(flags)
                })
            }
            return
        }
        guard !legacyValidation else { complete(.success(nil)); return }
        do {
            let batches = try validationBatches(hits)
            let server = try connect(\.connection, command: ["serve"])
            validate(batches[...], on: server, explicit: explicit, valid: [], complete: complete)
        } catch let failure as SearchFailure {
            complete(.failure(failure))
        } catch {
            complete(.failure(SearchFailure(error.localizedDescription)))
        }
    }

    private func validationBatches(_ hits: [SearchHit]) throws -> [[ValidationHit]] {
        // Count the encoded JSON, not path characters. Reserve a full-width ID and newline.
        let budget = 12 * 1024
        let encoder = JSONEncoder()
        let overhead = try encoder.encode(SearchRequest(id: .max, op: "validate", hits: [])).count + 1
        var batches: [[ValidationHit]] = []
        var batch: [ValidationHit] = []
        var size = overhead
        for hit in hits {
            let entry = ValidationHit(hit)
            let bytes = try encoder.encode(entry).count
            guard overhead + bytes <= budget else { throw SearchFailure("Validation hit exceeds lumen serve frame budget") }
            if size + bytes + (batch.isEmpty ? 0 : 1) > budget {
                batches.append(batch)
                batch = []
                size = overhead
            }
            size += bytes + (batch.isEmpty ? 0 : 1)
            batch.append(entry)
        }
        batches.append(batch)
        return batches
    }

    private func validate(_ batches: ArraySlice<[ValidationHit]>, on server: SearchConnection, explicit: Bool,
                          valid: [Bool], complete: @escaping (Result<[Bool]?, SearchFailure>) -> Void) {
        guard let batch = batches.first else { complete(.success(valid)); return }
        guard server.isRunning else { complete(.failure(SearchFailure("lumen serve stopped during validation"))); return }
        nextID &+= 1
        let request = SearchRequest(id: nextID, op: "validate", hits: batch)
        // A reply clears the active request before calling us. Send continuations
        // ahead of unrelated queued work so only the first chunk can migrate on timeout.
        server.enqueue(request, explicit: explicit, aheadOfQueue: !valid.isEmpty) { [weak self] result in
            switch result {
            case .success(let reply):
                guard let flags = reply.valid, flags.count == batch.count else {
                    complete(.failure(SearchFailure("Invalid validation response from lumen serve")))
                    return
                }
                let remaining = batches.dropFirst()
                guard !remaining.isEmpty else { complete(.success(valid + flags)); return }
                // A queued request can be migrated before it runs if the previous
                // request times out. Continue on the connection that just replied.
                guard let self, let responder = self.connection else { return }
                self.validate(remaining, on: responder, explicit: explicit, valid: valid + flags, complete: complete)
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
                reply.hits.map { .success($0) } ?? .failure(SearchFailure("Invalid search response from lumen"))
            })
        }
    }

    private func submit(_ request: SearchRequest, to lane: ReferenceWritableKeyPath<LauncherEngine, SearchConnection?>,
                        command: [String], idleTimeout: Duration?, explicit: Bool = false,
                        complete: @escaping ServeCompletion) {
        if let core, command.first == "serve", request.mode == "name" || request.mode == "text" {
            core.enqueue(request, explicit: explicit, complete: complete)
            return
        }
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

    func discardQueuedSearch() {
        core?.discardQueued()
        connection?.discardQueued()
    }
    func discardQueuedSemantic() { semanticConnection?.discardQueued() }

    func closeSemantic() {
        semanticConnection?.stop()
        semanticConnection = nil
    }

    private func closeSubprocesses() {
        connection?.stop()
        connection = nil
        closeSemantic()
        closeImages()
    }

    func close() {
        core?.close()
        closeSubprocesses()
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

typealias ServeCompletion = (Result<SearchReply, SearchFailure>) -> Void

struct SearchRequest: Encodable {
    let id: UInt64
    var query: String? = nil
    var mode: String? = nil
    var limit: Int? = nil
    var check_access: Bool? = nil
    var op: String? = nil
    var hits: [ValidationHit]? = nil
    var include_scope: Bool? = nil
}

struct ValidationHit: Encodable {
    let path: String
    let kind: String
    let availability: String
    let document_stamp: String?
    let matched_by: String

    init(_ hit: SearchHit) {
        path = hit.path
        kind = hit.kind
        availability = hit.availability
        document_stamp = hit.document_stamp
        matched_by = hit.matched_by
    }
}

struct SearchReply: Decodable {
    let id: UInt64?
    let hits: [SearchHit]?
    let valid: [Bool]?
    let error: String?
}

// The handle is confined to this serial queue until the worker's last reference
// is released. The main actor only schedules requests and delivers replies.
final class CoreSearchWorker: @unchecked Sendable {
    let queue: DispatchQueue
    private let database: URL
    private let root: URL?
    private var handle: OpaquePointer?

    init(label: String, database: URL, root: URL?) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.database = database
        self.root = root
    }

    deinit {
        // Queued work retains the worker, so no call can still be using the handle.
        lumen_session_close(handle)
    }

    func open() -> OpaquePointer? {
        if let handle { return handle }
        handle = database.path.withCString { db in
            if let root { return root.path.withCString { lumen_session_open(db, $0) } }
            return lumen_session_open(db, nil)
        }
        return handle
    }

    func close() {
        lumen_session_close(handle)
        handle = nil
    }

    func request(_ request: SearchRequest) throws -> SearchReply {
        guard let handle = open() else { throw SearchFailure("no usable index; run lumen index first") }
        var bytes = try JSONEncoder().encode(request)
        bytes.append(0)
        let output = bytes.withUnsafeBytes { buffer in
            let json = buffer.bindMemory(to: CChar.self).baseAddress
            return request.op == "validate" ? lumen_session_validate_json(handle, json)
                                            : lumen_session_search_json(handle, json)
        }
        guard let output else { throw SearchFailure("Missing response from lumen core") }
        defer { lumen_string_free(output) }
        let data = Data(bytesNoCopy: output, count: strlen(output), deallocator: .none)
        let reply = try JSONDecoder().decode(SearchReply.self, from: data)
        guard reply.id == request.id || reply.id == nil && reply.error != nil else {
            throw SearchFailure("Invalid response from lumen core")
        }
        if let error = reply.error { throw SearchFailure(error) }
        return reply
    }

    func requestStatus(_ request: SearchRequest) throws -> Data {
        guard let handle = open() else { throw SearchFailure("no usable index; run lumen index first") }
        var bytes = try JSONEncoder().encode(request)
        bytes.append(0)
        let output = bytes.withUnsafeBytes { buffer in
            lumen_session_status_json(handle, buffer.bindMemory(to: CChar.self).baseAddress)
        }
        guard let output else { throw SearchFailure("Missing response from lumen core") }
        defer { lumen_string_free(output) }
        let data = Data(bytesNoCopy: output, count: strlen(output), deallocator: .none)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchFailure("Invalid response from lumen core")
        }
        if let id = object["id"] as? NSNumber {
            guard id.uint64Value == request.id else { throw SearchFailure("Invalid response from lumen core") }
        } else if object["error"] == nil {
            throw SearchFailure("Invalid response from lumen core")
        }
        if let error = object["error"] as? String { throw SearchFailure(error) }
        guard let statusObject = object["status"] else { throw SearchFailure("Missing status from lumen core") }
        return try JSONSerialization.data(withJSONObject: statusObject)
    }
}

@MainActor
final class CoreSearchLane {
    private static let cancelledStatus = EngineResponse(
        exitStatus: -1,
        output: Data(),
        errors: Data("lumen core session closed".utf8)
    )

    private enum Job {
        case rpc(SearchRequest, ServeCompletion)
        case status(SearchRequest, [@MainActor (EngineResponse) -> Void])
    }

    private struct Pending {
        let job: Job
        let explicit: Bool
        let discardable: Bool

        var mode: String? {
            if case .rpc(let request, _) = job { return request.mode }
            return nil
        }
    }

    let worker: CoreSearchWorker
    private var generation: UInt64 = 0
    private var active: Pending?
    private var queued: [Pending] = []
    var isBusy: Bool { active != nil }

    init(label: String, database: URL, root: URL?) {
        worker = CoreSearchWorker(label: label, database: database, root: root)
    }

    func warm() { worker.queue.async { [worker] in _ = worker.open() } }

    func enqueue(_ request: SearchRequest, explicit: Bool = false, complete: @escaping ServeCompletion) {
        let pending = Pending(job: .rpc(request, complete), explicit: explicit, discardable: !explicit)
        if explicit { queued.insert(pending, at: 0) }
        else {
            if let mode = request.mode { queued.removeAll { $0.mode == mode } }
            queued.append(pending)
        }
        sendNext()
    }

    func enqueueStatus(_ request: SearchRequest, complete: @escaping @MainActor (EngineResponse) -> Void) {
        if let index = queued.firstIndex(where: {
            if case .status(let existing, _) = $0.job { return existing.include_scope == request.include_scope }
            return false
        }), case .status(_, let callbacks) = queued[index].job {
            queued[index] = Pending(job: .status(request, callbacks + [complete]), explicit: false, discardable: false)
        } else {
            queued.append(Pending(job: .status(request, [complete]), explicit: false, discardable: false))
        }
        sendNext()
    }

    func discardQueued() { queued.removeAll { $0.discardable } }

    func close() {
        var settledStatusCallbacks: [@MainActor (EngineResponse) -> Void] = []
        if case .status(_, let callbacks) = active?.job {
            settledStatusCallbacks.append(contentsOf: callbacks)
        }
        for pending in queued {
            if case .status(_, let callbacks) = pending.job {
                settledStatusCallbacks.append(contentsOf: callbacks)
            }
        }
        generation &+= 1
        active = nil
        queued.removeAll()
        worker.queue.async { [worker] in worker.close() }
        if !settledStatusCallbacks.isEmpty {
            let cancelled = Self.cancelledStatus
            DispatchQueue.main.async {
                for callback in settledStatusCallbacks { callback(cancelled) }
            }
        }
    }

    private func sendNext() {
        guard !isBusy, !queued.isEmpty else { return }
        let next = queued.removeFirst(), generation = generation
        active = next
        worker.queue.async { [weak self, worker] in
            switch next.job {
            case .rpc(let request, let complete):
                let result = Result { try worker.request(request) }.mapError {
                    $0 as? SearchFailure ?? SearchFailure($0.localizedDescription)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.active = nil
                    complete(result)
                    self.sendNext()
                }
            case .status(let request, let callbacks):
                let response: EngineResponse
                do {
                    let payload = try worker.requestStatus(request)
                    response = EngineResponse(exitStatus: 0, output: payload, errors: Data())
                } catch {
                    let message = (error as? SearchFailure)?.detail ?? error.localizedDescription
                    response = EngineResponse(exitStatus: 1, output: Data(), errors: Data(message.utf8))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.active = nil
                    for complete in callbacks { complete(response) }
                    self.sendNext()
                }
            }
        }
    }
}

@MainActor
final class CoreSearchConnection {
    let nameLane: CoreSearchLane
    let textLane: CoreSearchLane

    var isNameBusy: Bool { nameLane.isBusy }
    var isBusy: Bool { nameLane.isBusy || textLane.isBusy }

    init(database: URL, root: URL?) {
        nameLane = CoreSearchLane(label: "lumen.core.name", database: database, root: root)
        textLane = CoreSearchLane(label: "lumen.core.text", database: database, root: root)
    }

    func warm() { nameLane.warm() }

    func enqueue(_ request: SearchRequest, explicit: Bool = false, complete: @escaping ServeCompletion) {
        let target = request.mode == "name" ? nameLane : textLane
        target.enqueue(request, explicit: explicit, complete: complete)
    }

    func status(_ request: SearchRequest, complete: @escaping @MainActor (EngineResponse) -> Void) {
        textLane.enqueueStatus(request, complete: complete)
    }

    func discardQueued() {
        nameLane.discardQueued()
        textLane.discardQueued()
    }

    func close() {
        nameLane.close()
        textLane.close()
    }
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

    func enqueue(_ request: SearchRequest, explicit: Bool, aheadOfQueue: Bool = false,
                 complete: @escaping ServeCompletion) {
        let pending = Pending(request: request, explicit: explicit, complete: complete)
        if explicit || aheadOfQueue { queued.insert(pending, at: 0) }
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
