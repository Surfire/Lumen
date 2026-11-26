import CryptoKit
import Foundation
import SQLite3

struct ClipboardItem: Identifiable, Equatable {
    let id: Int64
    let text: String?    // nil for images; image bytes are read only when needed
    let capturedAt: Date
    let sourceBundleID: String?
    let sourceAppName: String?
    let pinned: Bool

    func matches(_ query: String) -> Bool {
        query.isEmpty || [text, sourceAppName, sourceBundleID].contains {
            $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

@MainActor
final class ClipboardStore {
    nonisolated static let maximumTextBytes = 32 * 1024
    nonisolated static let maximumImageBytes = 2 * 1024 * 1024
    nonisolated static let defaultLimit = 200
    private nonisolated static let maximumLimit = 500
    nonisolated static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lumen/Clipboard", isDirectory: true)

    let directory: URL
    private let file: URL
    private var connection: OpaquePointer?
    private var limit: Int

    init(directory: URL = ClipboardStore.defaultDirectory, limit: Int = ClipboardStore.defaultLimit) {
        self.directory = directory
        // The index skips hidden paths. Keep all payloads and SQLite sidecars here, never in index.sqlite.
        file = directory.appendingPathComponent(".history.sqlite")
        self.limit = Self.boundedLimit(limit)
    }

    deinit { sqlite3_close(connection) }

    nonisolated static func boundedLimit(_ limit: Int) -> Int { min(max(1, limit), maximumLimit) }

    func contains(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let root = directory.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    func items() throws -> [ClipboardItem] {
        guard let db = try database() else { return [] }
        return try statement(db, """
            SELECT id, text, captured, bundle_id, app_name, pinned FROM clips ORDER BY recency DESC
            """) { row in
            var items: [ClipboardItem] = []
            while try next(row) {
                items.append(ClipboardItem(id: sqlite3_column_int64(row, 0), text: text(row, 1),
                                           capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                                           sourceBundleID: text(row, 3), sourceAppName: text(row, 4),
                                           pinned: sqlite3_column_int(row, 5) != 0))
            }
            return items
        }
    }

    func addText(_ value: String, capturedAt: Date, bundleID: String?, appName: String?) throws -> Bool {
        let utf8 = value.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: Self.maximumTextBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
        // Back up at most three bytes to avoid truncating a UTF-8 scalar.
        while end != utf8.endIndex, utf8[end] & 0xc0 == 0x80 { utf8.formIndex(before: &end) }
        let bounded = String(decoding: utf8[..<end], as: UTF8.self)
        guard !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return try insert(text: bounded, image: nil, thumbnail: nil, bytes: Data(bounded.utf8),
                   capturedAt: capturedAt, bundleID: bundleID, appName: appName)
    }

    func addImage(_ png: Data, thumbnail: Data, capturedAt: Date, bundleID: String?, appName: String?) throws -> Bool {
        guard !png.isEmpty, png.count <= Self.maximumImageBytes,
              !thumbnail.isEmpty, thumbnail.count <= Self.maximumImageBytes else { return false }
        return try insert(text: nil, image: png, thumbnail: thumbnail, bytes: png,
                   capturedAt: capturedAt, bundleID: bundleID, appName: appName)
    }

    private func insert(text: String?, image: Data?, thumbnail: Data?, bytes: Data,
                        capturedAt: Date, bundleID: String?, appName: String?) throws -> Bool {
        guard let db = try database(create: true) else { throw StoreError.unavailable }
        // Distinguish text and images even if their bytes match. At capacity with only
        // pins, don't write a new entry that would immediately be evicted.
        var digest = Data([image == nil ? 0 : 1])
        digest.append(contentsOf: SHA256.hash(data: bytes))
        return try transaction(db) {
            try statement(db, """
                INSERT INTO clips (text, image, thumbnail, captured, bundle_id, app_name, digest, recency)
                SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, COALESCE(MAX(recency), 0) + 1 FROM clips
                HAVING ?7 IS NOT (SELECT digest FROM clips ORDER BY recency DESC LIMIT 1)
                   AND (SELECT COUNT(*) FROM clips WHERE pinned = 1) < ?8
                """) { row in
                try bind(text, to: row, at: 1)
                try bind(image, to: row, at: 2)
                try bind(thumbnail, to: row, at: 3)
                try requireOK(sqlite3_bind_double(row, 4, capturedAt.timeIntervalSince1970))
                try bind(bundleID, to: row, at: 5)
                try bind(appName, to: row, at: 6)
                try bind(digest, to: row, at: 7)
                try requireOK(sqlite3_bind_int64(row, 8, Int64(limit)))
                _ = try next(row)
            }
            guard sqlite3_changes(db) != 0 else { return false }
            try prune(db, limit: limit)
            return true
        }
    }

    func image(id: Int64) throws -> Data? { try imageBytes("image", id: id) }
    func thumbnail(id: Int64) throws -> Data? { try imageBytes("thumbnail", id: id) }

    private func imageBytes(_ column: String, id: Int64) throws -> Data? {
        guard let db = try database() else { return nil }
        return try statement(db, "SELECT \(column) FROM clips WHERE id = ?") { row in
            try requireOK(sqlite3_bind_int64(row, 1, id))
            guard try next(row) else { return nil }
            return data(row, 0)
        }
    }

    func noteUsed(id: Int64) throws {
        try update(id, "UPDATE clips SET recency = (SELECT MAX(recency) + 1 FROM clips) WHERE id = ?")
    }

    func togglePin(id: Int64) throws {
        guard let db = try database() else { return }
        try transaction(db) {
            try update(id, "UPDATE clips SET pinned = 1 - pinned WHERE id = ?")
            try prune(db, limit: limit)
        }
    }

    func remove(id: Int64) throws { try update(id, "DELETE FROM clips WHERE id = ?") }
    func clearUnpinned() throws { if let db = try database() { try execute(db, "DELETE FROM clips WHERE pinned = 0") } }
    func clearAll() throws { if let db = try database() { try execute(db, "DELETE FROM clips") } }

    func setLimit(_ value: Int) throws {
        let value = Self.boundedLimit(value)
        if let db = try database() { try prune(db, limit: value) }
        limit = value
    }

    private func prune(_ db: OpaquePointer, limit: Int) throws {
        try statement(db, """
            DELETE FROM clips WHERE id IN (
                SELECT id FROM clips WHERE pinned = 0 ORDER BY recency DESC LIMIT -1
                OFFSET MAX(0, ? - (SELECT COUNT(*) FROM clips WHERE pinned = 1))
            )
            """) { row in
            try requireOK(sqlite3_bind_int64(row, 1, Int64(limit)))
            _ = try next(row)
        }
    }

    private func update(_ id: Int64, _ sql: String) throws {
        guard let db = try database() else { return }
        try statement(db, sql) { row in
            try requireOK(sqlite3_bind_int64(row, 1, id))
            _ = try next(row)
        }
    }

    private enum StoreError: Error { case unavailable }

    private func database(create: Bool = false) throws -> OpaquePointer? {
        if let connection { return connection }
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: file.path)
        guard exists || create else { return nil }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var localDirectory = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try localDirectory.setResourceValues(resources)
        guard exists || fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.unavailable
        }
        if exists { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        var handle: OpaquePointer?
        do {
            try requireOK(sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE, nil))
            guard let db = handle else { throw StoreError.unavailable }
            // DELETE journals inherit the database mode. Don't leave freed payloads in
            // SQLite pages or send any part of this store to the index engine or diagnostics.
            try execute(db, """
                PRAGMA journal_mode = DELETE;
                PRAGMA temp_store = MEMORY;
                PRAGMA auto_vacuum = FULL;
                PRAGMA secure_delete = ON;
                CREATE TABLE IF NOT EXISTS clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT, image BLOB, thumbnail BLOB,
                    captured REAL NOT NULL, bundle_id TEXT, app_name TEXT,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    digest BLOB NOT NULL, recency INTEGER NOT NULL UNIQUE
                );
                """)
            connection = db
            return db
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    private func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute(db, "COMMIT")
            return result
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try requireOK(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        defer { sqlite3_finalize(handle) }
        try requireOK(sqlite3_prepare_v2(db, sql, -1, &handle, nil))
        guard let handle else { throw StoreError.unavailable }
        return try body(handle)
    }

    private func next(_ row: OpaquePointer) throws -> Bool {
        switch sqlite3_step(row) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StoreError.unavailable
        }
    }

    private func requireOK(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw StoreError.unavailable }
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: Data?, to row: OpaquePointer, at index: Int32) throws {
        try requireOK(value?.withUnsafeBytes {
            sqlite3_bind_blob(row, index, $0.baseAddress, Int32($0.count), transient)
        } ?? sqlite3_bind_null(row, index))
    }

    private func bind(_ value: String?, to row: OpaquePointer, at index: Int32) throws {
        guard let value else { try requireOK(sqlite3_bind_null(row, index)); return }
        let size = Int32(value.utf8.count)
        try requireOK(value.withCString { sqlite3_bind_text(row, index, $0, size, transient) })
    }

    private func data(_ row: OpaquePointer, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(row, index) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, index)))
    }

    private func text(_ row: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(row, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(row, index))), as: UTF8.self)
    }
}
