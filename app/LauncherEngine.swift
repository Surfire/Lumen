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
    var id: String { path }
    var isLocal: Bool { availability == "local" }
    var isCloudReference: Bool { availability == "placeholder" || availability == "provider_metadata_only" }
    var isSemanticCandidate: Bool { matched_by == "semantic_candidate" }
    var hasPreview: Bool { isLocal && snippet != nil }

    func pathStamp() -> String? {
        guard path.hasPrefix("/") else { return nil }
        let kind = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(kind, scope)
        guard prior >= 0, setiopolicy_np(kind, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            return nil
        }
        defer { _ = setiopolicy_np(kind, scope, prior) }

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
              stat.st_mode & S_IFMT == (self.kind == "directory" ? S_IFDIR : S_IFREG),
              isCloudReference || stat.st_flags & UInt32(SF_DATALESS) == 0
        else { return nil }
        // Match the Rust document_state stamp, including the unsigned Unix device conversion.
        let device = UInt64(bitPattern: Int64(stat.st_dev))
        let size = UInt64(bitPattern: Int64(stat.st_size))
        let modified = stat.st_mtimespec
        let changed = stat.st_ctimespec
        return "\(device):\(stat.st_ino):\(size):\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)"
    }
}

struct IndexReport: Decodable {
    let items: Int
    let entries_unreadable: Int?
    let placeholders: Int?
    let documents: Int?
    let documents_not_read: Int?
}

struct IndexScope: Equatable {
    var allow = ""
    var deny = ""
    var documents = false

    private func paths(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var hasAbsolutePaths: Bool { (paths(allow) + paths(deny)).allSatisfy { $0.hasPrefix("/") } }

    func arguments(pdfHelper: String) -> [String] {
        paths(allow).flatMap { ["--allow", $0] }
            + paths(deny).flatMap { ["--deny", $0] }
            + (documents ? ["--documents", "--pdf-helper", pdfHelper] : [])
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
    private var nextID: UInt64 = 0

    init(executable: URL, database: URL, syntheticRoot: URL? = nil) {
        self.executable = executable
        self.database = database
        self.root = syntheticRoot
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
        ["--db", database.path] + command
    }

    func indexArguments(scope: IndexScope) -> [String] {
        ["index"] + (root.map { ["--root", $0.path] } ?? [])
            + scope.arguments(pdfHelper: helper("LumenPdfExtractor"))
    }

    func helper(_ name: String) -> String {
        executable.deletingLastPathComponent().appendingPathComponent(name).path
    }

    func run(
        _ command: [String], onLine: ((Data) -> Void)? = nil,
        complete: @escaping (EngineResponse) -> Void
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
            complete(EngineResponse(exitStatus: -1, output: Data(), errors: Data(error.localizedDescription.utf8)))
            return nil
        }

        // Both pipes are drained while the child is running, including for long-lived watch.
        let errors = Task.detached(priority: .utility) {
            var recent = Data()
            while case let bytes = stderr.fileHandleForReading.availableData, !bytes.isEmpty {
                recent.append(bytes)
                if recent.count > 65_536 { recent.removeFirst(recent.count - 65_536) }
            }
            return recent
        }
        DispatchQueue.global(qos: .utility).async {
            let output: Data
            if let onLine {
                Self.readLines(stdout.fileHandleForReading) { data in
                    DispatchQueue.main.async { onLine(data) }
                }
                output = Data()
            } else {
                output = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            }
            process.waitUntilExit()
            Task { @MainActor in
                let recent = await errors.value
                complete(EngineResponse(exitStatus: process.terminationStatus, output: output, errors: recent))
            }
        }
        return process
    }

    func search(_ query: String, mode: String, complete: @escaping (Result<[SearchHit], SearchFailure>) -> Void) {
        nextID &+= 1
        if connection?.isRunning != true {
            do {
                let new = SearchConnection(executable: executable, arguments: arguments(["serve"]))
                try new.start()
                connection = new
            } catch {
                complete(.failure(SearchFailure(error.localizedDescription)))
                return
            }
        }
        connection?.enqueue(SearchRequest(id: nextID, query: query, mode: mode), complete: complete)
    }

    func discardQueuedSearch() { connection?.discardQueued() }

    func close() {
        connection?.stop()
        connection = nil
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

private struct SearchRequest: Encodable {
    let id: UInt64
    let query: String
    let mode: String
    let limit = 60
}

private struct SearchReply: Decodable {
    let id: UInt64?
    let hits: [SearchHit]?
    let error: String?
}

@MainActor
private final class SearchConnection {
    private struct Pending {
        let request: SearchRequest
        let complete: (Result<[SearchHit], SearchFailure>) -> Void
    }

    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private var active: Pending?
    private var queued: Pending?

    var isRunning: Bool { process.isRunning }

    init(executable: URL, arguments: [String]) {
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
        let diagnostic = Task.detached(priority: .utility) {
            (try? errors.readToEnd()) ?? Data()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            LauncherEngine.readLines(output) { bytes in
                DispatchQueue.main.async { [weak self] in self?.reply(bytes) }
            }
            process.waitUntilExit()
            Task { @MainActor [weak self] in
                let errors = await diagnostic.value
                self?.fail(SearchFailure(String(decoding: errors, as: UTF8.self)))
            }
        }
    }

    func enqueue(_ request: SearchRequest, complete: @escaping (Result<[SearchHit], SearchFailure>) -> Void) {
        queued = Pending(request: request, complete: complete)
        sendNext()
    }

    func discardQueued() { queued = nil }

    func stop() {
        active = nil
        queued = nil
        if process.isRunning { process.terminate() }
        try? stdin.fileHandleForWriting.close()
    }

    private func sendNext() {
        guard active == nil, let next = queued else { return }
        queued = nil
        active = next
        let input = stdin.fileHandleForWriting
        let request = next.request
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
        if let hits = reply.hits { active.complete(.success(hits)) }
        else { active.complete(.failure(SearchFailure(reply.error ?? ""))) }
        sendNext()
    }

    private func fail(_ error: SearchFailure) {
        let latest = queued ?? active
        stop()
        latest?.complete(.failure(error))
    }
}
