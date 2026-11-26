import CryptoKit
import Darwin
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

struct ClipboardItem: Identifiable, Equatable {
    let id: Int64
    let text: String?    // nil for images; image bytes are read only when needed
    let capturedAt: Date
    let sourceBundleID: String?
    let sourceAppName: String?
    let pinned: Bool

    private static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private var searchableFields: [String] { [text, sourceAppName, sourceBundleID].compactMap { $0 } }

    func containsSubstring(_ query: String) -> Bool {
        searchableFields.contains { $0.range(of: query, options: Self.searchOptions) != nil }
    }

    func matches(_ query: String) -> Bool {
        if query.isEmpty || containsSubstring(query) { return true }
        let needle = query.folding(options: Self.searchOptions, locale: nil)
        guard !needle.isEmpty else { return false }
        return searchableFields.contains { field in
            var remaining = needle[...]
            for character in field.folding(options: Self.searchOptions, locale: nil) where character == remaining.first {
                remaining.removeFirst()
                if remaining.isEmpty { return true }
            }
            return false
        }
    }
}

@MainActor
final class ClipboardStore {
    nonisolated static let maximumTextBytes = 32 * 1024
    nonisolated static let maximumImageBytes = 2 * 1024 * 1024
    nonisolated static let defaultLimit = 200
    private nonisolated static let maximumLimit = 500
    nonisolated static let defaultDirectory = canonicalStorageAnchor(FileManager.default.homeDirectoryForCurrentUser)
        .appendingPathComponent("Library/Application Support/Lumen/Clipboard", isDirectory: true)

    // Resolve only the trusted starting point, never the private path below it.
    // Foundation may abbreviate /private/var to the system symlink /var.
    nonisolated static func canonicalStorageAnchor(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    private static let databaseName = ".history.sqlite"

    let directory: URL
    private var connection: OpaquePointer?
    private var limit: Int

    init(directory: URL = ClipboardStore.defaultDirectory, limit: Int = ClipboardStore.defaultLimit) {
        self.directory = directory
        self.limit = Self.boundedLimit(limit)
    }

    deinit { sqlite3_close(connection) }

    nonisolated static func boundedLimit(_ limit: Int) -> Int { min(max(1, limit), maximumLimit) }

    func contains(_ url: URL) -> Bool {
        let root = directory.path
        func isPrivate(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        return isPrivate(url.path) || isPrivate(url.resolvingSymlinksInPath().path)
    }

    // Keep recency order within each tier. The command model then drops nonmatches.
    static func rank(_ items: [ClipboardItem], for query: String) -> [ClipboardItem] {
        guard !query.isEmpty else { return items }
        var substrings: [ClipboardItem] = []
        var others: [ClipboardItem] = []
        for item in items {
            if item.containsSubstring(query) { substrings.append(item) }
            else { others.append(item) }
        }
        return substrings + others
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
            let existing = try statement(db, """
                SELECT id, recency = (SELECT MAX(recency) FROM clips)
                FROM clips WHERE digest = ? ORDER BY recency DESC LIMIT 1
                """) { row -> (id: Int64, newest: Bool)? in
                try bind(digest, to: row, at: 1)
                guard try next(row) else { return nil }
                return (sqlite3_column_int64(row, 0), sqlite3_column_int(row, 1) != 0)
            }
            if let existing {
                guard !existing.newest else { return false }
                try statement(db, """
                    UPDATE clips SET captured = ?1, bundle_id = ?2, app_name = ?3,
                        recency = (SELECT MAX(recency) + 1 FROM clips) WHERE id = ?4
                    """) { row in
                    try requireOK(sqlite3_bind_double(row, 1, capturedAt.timeIntervalSince1970))
                    try bind(bundleID, to: row, at: 2)
                    try bind(appName, to: row, at: 3)
                    try requireOK(sqlite3_bind_int64(row, 4, existing.id))
                    _ = try next(row)
                }
                return true
            }
            try statement(db, """
                INSERT INTO clips (text, image, thumbnail, captured, bundle_id, app_name, digest, recency)
                SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, COALESCE(MAX(recency), 0) + 1 FROM clips
                HAVING (SELECT COUNT(*) FROM clips WHERE pinned = 1) < ?8
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

    func image(id: Int64) throws -> Data? {
        guard let bytes = try imageBytes("image", id: id),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              Self.isDecodablePNG(bytes, source: source) else { return nil }
        return bytes
    }

    func thumbnail(id: Int64) throws -> Data? { try imageBytes("thumbnail", id: id) }

    private func imageBytes(_ column: String, id: Int64) throws -> Data? {
        guard let db = try database() else { return nil }
        return try statement(db, "SELECT \(column) FROM clips WHERE id = ?1 AND typeof(\(column)) = 'blob' AND length(\(column)) BETWEEN 1 AND ?2") { row in
            try requireOK(sqlite3_bind_int64(row, 1, id))
            try requireOK(sqlite3_bind_int(row, 2, Int32(Self.maximumImageBytes)))
            guard try next(row) else { return nil }
            return data(row, 0)
        }
    }

    nonisolated static func isDecodablePNG(_ bytes: Data, source: CGImageSource) -> Bool {
        bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) &&
            CGImageSourceGetType(source) == UTType.png.identifier as CFString &&
            CGImageSourceGetStatus(source) == .statusComplete &&
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete &&
            CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
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

    private func openDirectory(_ url: URL, create: Bool) throws -> Int32? {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        let fd = open(url.path, flags)
        if fd >= 0 { return fd }
        guard errno == ENOENT else { throw StoreError.unavailable }
        guard create else { return nil }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, let parentFD = try openDirectory(parent, create: true) else { throw StoreError.unavailable }
        defer { close(parentFD) }
        let name = url.lastPathComponent
        guard mkdirat(parentFD, name, 0o700) == 0 || errno == EEXIST else { throw StoreError.unavailable }
        let child = openat(parentFD, name, flags)
        guard child >= 0 else { throw StoreError.unavailable }
        return child
    }

    private func regularFileExists(_ name: String, in directoryFD: Int32) throws -> Bool {
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw StoreError.unavailable }
            return true
        }
        guard errno == ENOENT else { throw StoreError.unavailable }
        return false
    }

    private func database(create: Bool = false) throws -> OpaquePointer? {
        guard let directoryFD = try openDirectory(directory, create: create) else { return nil }
        defer { close(directoryFD) }
        // All payloads are SQLite BLOBs, not separate files. Check the hidden
        // database and all sidecar paths before letting SQLite use them.
        let name = Self.databaseName
        let exists = try regularFileExists(name, in: directoryFD)
        for suffix in ["-wal", "-shm", "-journal"] { _ = try regularFileExists(name + suffix, in: directoryFD) }
        if let connection {
            guard exists else { throw StoreError.unavailable }
            return connection
        }
        guard exists || create else { return nil }
        guard fchmod(directoryFD, 0o700) == 0 else { throw StoreError.unavailable }
        var localDirectory = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try localDirectory.setResourceValues(resources)
        try prepareFile(name, in: directoryFD, create: !exists)
        var handle: OpaquePointer?
        do {
            let path = directory.appendingPathComponent(name).path
            try requireOK(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil))
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

    // Close the permission-setting descriptor before SQLite takes POSIX locks.
    private func prepareFile(_ name: String, in directoryFD: Int32, create: Bool) throws {
        let createFlags = create ? O_CREAT | O_EXCL : 0
        let fd = openat(directoryFD, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | createFlags, 0o600)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else {
            throw StoreError.unavailable
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
