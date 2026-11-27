import CryptoKit
import Darwin
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

struct ClipboardItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let text: String?    // nil for images; image bytes are read only when needed
    let capturedAt: Date
    let sourceBundleID: String?
    let sourceAppName: String?
    let pinned: Bool
    /// Absolute path of a copied file reference; its bytes are never stored.
    let filePath: String?

    var isFile: Bool { filePath != nil }
    var isImage: Bool { text == nil && filePath == nil }

    private struct SearchField: Equatable, Sendable {
        let bytes: [UInt8]
        let lowMask: UInt64
        let highMask: UInt64
        let nonAsciiMask: UInt64

        init(_ value: String) {
            bytes = Array(ClipboardItem.fold(value).utf8)
            (lowMask, highMask, nonAsciiMask) = Self.presenceMask(bytes)
        }

        static func presenceMask(_ bytes: [UInt8]) -> (UInt64, UInt64, UInt64) {
            var low: UInt64 = 0
            var high: UInt64 = 0
            var nonAscii: UInt64 = 0
            for byte in bytes {
                let bit = UInt64(1) << (byte & 63)
                switch byte {
                case 0..<64: low |= bit
                case 64..<128: high |= bit
                default: nonAscii |= bit
                }
            }
            return (low, high, nonAscii)
        }

        @inline(__always)
        private static func load16(_ ptr: UnsafePointer<UInt8>) -> SIMD16<UInt8> {
            var v = SIMD16<UInt8>()
            _ = withUnsafeMutableBytes(of: &v) { memcpy($0.baseAddress!, ptr, 16) }
            return v
        }

        @inline(__always)
        private static func kmpPure(_ hBase: UnsafePointer<UInt8>, _ n: Int, _ nBase: UnsafePointer<UInt8>,
                                    _ m: Int, _ lps: [Int], start: Int) -> Bool {
            lps.withUnsafeBufferPointer { table in
                let lBase = table.baseAddress!
                var i = start
                var j = 0
                while i < n {
                    let b = hBase[i]
                    while j > 0 && nBase[j] != b { j = lBase[j &- 1] }
                    if nBase[j] == b {
                        j &+= 1
                        if j == m { return true }
                    }
                    i &+= 1
                }
                return false
            }
        }

        private static func containsSubstring(haystack: UnsafeBufferPointer<UInt8>, needle: UnsafeBufferPointer<UInt8>,
                                              allIdenticalBytes: Bool, lps: [Int], startOffset: Int) -> Bool {
            let n = haystack.count
            let m = needle.count
            let lastStart = n - m
            guard startOffset <= lastStart, let hBase = haystack.baseAddress, let nBase = needle.baseAddress else { return false }
            if m == 1 { return memchr(hBase + startOffset, Int32(nBase[0]), n - startOffset) != nil }

            if allIdenticalBytes {
                let byte = nBase[0]
                var pos = startOffset
                while pos <= lastStart {
                    let end = pos + m - 1
                    if hBase[end] != byte {
                        pos = end + 1
                        continue
                    }
                    var runStart = end
                    while runStart > pos && hBase[runStart - 1] == byte { runStart -= 1 }
                    if runStart == pos { return true }
                    var next = end + 1
                    while next - runStart < m && next < n && hBase[next] == byte { next += 1 }
                    if next - runStart == m { return true }
                    // No start through the mismatch at `next` can work. Never revisit these bytes.
                    pos = next + 1
                }
                return false
            }

            let off1 = 1
            let off2 = m >> 1
            let off3 = m - 1
            let v0 = SIMD16<UInt8>(repeating: nBase[0])
            let v1 = SIMD16<UInt8>(repeating: nBase[off1])
            let v2 = SIMD16<UInt8>(repeating: nBase[off2])
            let v3 = SIMD16<UInt8>(repeating: nBase[off3])
            var pos = startOffset
            var verifications = 0
            // Every lane is a valid start, so even the last-byte load stays in bounds.
            while pos <= lastStart - 15 {
                var mask = (load16(hBase + pos) .== v0) .& (load16(hBase + pos + off3) .== v3)
                if any(mask) {
                    mask = mask .& (load16(hBase + pos + off1) .== v1) .& (load16(hBase + pos + off2) .== v2)
                    if any(mask) {
                        for lane in 0..<16 where mask[lane] {
                            let candidate = pos + lane
                            if m <= 4 || memcmp(hBase + candidate, nBase, m) == 0 { return true }
                            verifications &+= 1
                            if verifications >= 32 {
                                // Earlier starts have already been ruled out, including this candidate.
                                return kmpPure(hBase, n, nBase, m, lps, start: candidate + 1)
                            }
                        }
                    }
                }
                pos &+= 16
            }
            while pos <= lastStart {
                if hBase[pos] == nBase[0] && hBase[pos + off3] == nBase[off3] &&
                    hBase[pos + off1] == nBase[off1] && hBase[pos + off2] == nBase[off2] {
                    if m <= 4 || memcmp(hBase + pos, nBase, m) == 0 { return true }
                    verifications &+= 1
                    if verifications >= 32 { return kmpPure(hBase, n, nBase, m, lps, start: pos + 1) }
                }
                pos &+= 1
            }
            return false
        }

        func match(needle: UnsafeBufferPointer<UInt8>, scalarRanges: [Range<Int>],
                   allIdenticalBytes: Bool, lps: [Int], checkFuzzy: Bool) -> SearchMatch? {
            bytes.withUnsafeBufferPointer { field in
                guard field.count >= needle.count, let base = field.baseAddress, let query = needle.baseAddress else { return nil }
                var firstMatchOffset = 0
                if checkFuzzy {
                    var offset = 0
                    for scalar in scalarRanges {
                        let scalarStart = query + scalar.lowerBound
                        let lastStart = field.count - scalar.count
                        // A valid UTF-8 scalar's first byte cannot be a continuation byte.
                        while true {
                            guard offset <= lastStart,
                                  let found = memchr(base + offset, Int32(scalarStart.pointee), lastStart - offset + 1) else { return nil }
                            offset = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
                            if scalar.count == 1 || memcmp(found, scalarStart, scalar.count) == 0 { break }
                            offset += 1
                        }
                        if scalar.lowerBound == 0 { firstMatchOffset = offset }
                        offset += scalar.count
                    }
                    if offset - firstMatchOffset == needle.count { return .substring }
                }

                if Self.containsSubstring(haystack: field, needle: needle, allIdenticalBytes: allIdenticalBytes,
                                          lps: lps, startOffset: firstMatchOffset) {
                    return .substring
                }
                return checkFuzzy ? .fuzzy : nil
            }
        }
    }

    private enum SearchMatch { case substring, fuzzy }
    private let searchableFields: [SearchField]

    init(id: Int64, text: String?, capturedAt: Date, sourceBundleID: String?, sourceAppName: String?, pinned: Bool,
         filePath: String? = nil) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.pinned = pinned
        self.filePath = filePath
        let fileFields = filePath.map { [($0 as NSString).lastPathComponent, $0] } ?? []
        searchableFields = ([text, sourceAppName, sourceBundleID] + fileFields).compactMap { $0.map(SearchField.init) }
    }

    private init(id: Int64, text: String?, capturedAt: Date, sourceBundleID: String?, sourceAppName: String?,
                 pinned: Bool, filePath: String?, searchableFields: [SearchField]) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.pinned = pinned
        self.filePath = filePath
        self.searchableFields = searchableFields
    }

    func withPinned(_ pinned: Bool) -> ClipboardItem {
        ClipboardItem(id: id, text: text, capturedAt: capturedAt, sourceBundleID: sourceBundleID,
                      sourceAppName: sourceAppName, pinned: pinned, filePath: filePath, searchableFields: searchableFields)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    // Visit each item once, keeping recency order within each matching tier.
    static func filtered(_ items: [ClipboardItem], for query: String) -> [ClipboardItem] {
        guard !query.isEmpty else { return items }
        let folded = fold(query)
        guard !folded.isEmpty else { return [] }
        let needleBytes = Array(folded.utf8)
        let (needLow, needHigh, needNonAscii) = SearchField.presenceMask(needleBytes)
        var scalarRanges: [Range<Int>] = []
        var offset = 0
        for scalar in folded.unicodeScalars {
            let end = offset + scalar.utf8.count
            scalarRanges.append(offset..<end)
            offset = end
        }

        let firstByte = needleBytes[0]
        let allIdenticalBytes = needleBytes.allSatisfy { $0 == firstByte }

        var kmpLPS = [Int](repeating: 0, count: needleBytes.count)
        var prefix = 0
        for index in 1..<needleBytes.count {
            while prefix > 0 && needleBytes[index] != needleBytes[prefix] { prefix = kmpLPS[prefix - 1] }
            if needleBytes[index] == needleBytes[prefix] { prefix += 1 }
            kmpLPS[index] = prefix
        }

        return needleBytes.withUnsafeBufferPointer { needle in
            var substrings: [ClipboardItem] = []
            var fuzzy: [ClipboardItem] = []
            for item in items {
                var bestMatch: SearchMatch?
                for field in item.searchableFields {
                    if (field.lowMask & needLow) != needLow || (field.highMask & needHigh) != needHigh ||
                        (field.nonAsciiMask & needNonAscii) != needNonAscii { continue }
                    // After a fuzzy hit, later fields can still promote the item to a substring hit.
                    if let match = field.match(needle: needle, scalarRanges: scalarRanges, allIdenticalBytes: allIdenticalBytes,
                                               lps: kmpLPS, checkFuzzy: bestMatch == nil) {
                        bestMatch = match
                        if match == .substring { break }
                    }
                }
                switch bestMatch {
                case .substring: substrings.append(item)
                case .fuzzy: fuzzy.append(item)
                case nil: break
                }
            }
            return substrings + fuzzy
        }
    }
}

final class ClipboardStore: @unchecked Sendable {
    struct UpsertResult: Sendable {
        let item: ClipboardItem
        let evictedIDs: Set<Int64>
    }

    static let maximumTextBytes = 32 * 1024
    static let maximumImageBytes = 2 * 1024 * 1024
    static let defaultLimit = 200
    private static let maximumLimit = 500
    static let defaultDirectory = canonicalStorageAnchor(FileManager.default.homeDirectoryForCurrentUser)
        .appendingPathComponent("Library/Application Support/Lumen/Clipboard", isDirectory: true)

    // Resolve only the trusted starting point, never the private path below it.
    // Foundation may abbreviate /private/var to the system symlink /var.
    static func canonicalStorageAnchor(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    private static let databaseName = ".history.sqlite"

    let directory: URL
    private let lock = NSLock()
    private var connection: OpaquePointer?
    private var limit: Int

    init(directory: URL = ClipboardStore.defaultDirectory, limit: Int = ClipboardStore.defaultLimit) {
        self.directory = directory
        self.limit = Self.boundedLimit(limit)
    }

    deinit {
        lock.withLock {
            sqlite3_close(connection)
            connection = nil
        }
    }

    static func boundedLimit(_ limit: Int) -> Int { min(max(1, limit), maximumLimit) }

    func contains(_ url: URL) -> Bool {
        let root = directory.path
        func isPrivate(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        return isPrivate(url.path) || isPrivate(url.resolvingSymlinksInPath().path)
    }

    func items() throws -> [ClipboardItem] {
        typealias RawRow = (id: Int64, text: String?, capturedAt: Date, bundleID: String?, appName: String?, pinned: Bool, filePath: String?)
        let rows: [RawRow] = try lock.withLock {
            guard let db = try databaseLocked() else { return [] }
            return try statement(db, """
                SELECT id, text, captured, bundle_id, app_name, pinned, file_path FROM clips ORDER BY recency DESC
                """) { row in
                var records: [RawRow] = []
                while try next(row) {
                    records.append((sqlite3_column_int64(row, 0), text(row, 1),
                                    Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                                    text(row, 3), text(row, 4), sqlite3_column_int(row, 5) != 0, text(row, 6)))
                }
                return records
            }
        }
        return rows.map {
            ClipboardItem(id: $0.id, text: $0.text, capturedAt: $0.capturedAt,
                          sourceBundleID: $0.bundleID, sourceAppName: $0.appName, pinned: $0.pinned,
                          filePath: $0.filePath)
        }
    }

    func addText(_ value: String, capturedAt: Date, bundleID: String?, appName: String?) throws -> Bool {
        try upsertText(value, capturedAt: capturedAt, bundleID: bundleID, appName: appName) != nil
    }

    func upsertText(_ value: String, capturedAt: Date, bundleID: String?, appName: String?) throws -> UpsertResult? {
        let utf8 = value.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: Self.maximumTextBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
        // Back up at most three bytes to avoid truncating a UTF-8 scalar.
        while end != utf8.endIndex, utf8[end] & 0xc0 == 0x80 { utf8.formIndex(before: &end) }
        let bounded = String(decoding: utf8[..<end], as: UTF8.self)
        guard !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try upsert(text: bounded, image: nil, thumbnail: nil, filePath: nil, bytes: Data(bounded.utf8),
                          capturedAt: capturedAt, bundleID: bundleID, appName: appName)
    }

    func addImage(_ png: Data, thumbnail: Data, capturedAt: Date, bundleID: String?, appName: String?) throws -> Bool {
        try upsertImage(png, thumbnail: thumbnail, capturedAt: capturedAt, bundleID: bundleID, appName: appName) != nil
    }

    func upsertImage(_ png: Data, thumbnail: Data, capturedAt: Date, bundleID: String?, appName: String?) throws -> UpsertResult? {
        guard !png.isEmpty, png.count <= Self.maximumImageBytes,
              !thumbnail.isEmpty, thumbnail.count <= Self.maximumImageBytes else { return nil }
        return try upsert(text: nil, image: png, thumbnail: thumbnail, filePath: nil, bytes: png,
                          capturedAt: capturedAt, bundleID: bundleID, appName: appName)
    }

    func addFile(_ path: String, capturedAt: Date, bundleID: String?, appName: String?) throws -> Bool {
        try upsertFile(path, capturedAt: capturedAt, bundleID: bundleID, appName: appName) != nil
    }

    /// Records a reference to a copied file. Only the path is stored; the file is never read here.
    func upsertFile(_ path: String, capturedAt: Date, bundleID: String?, appName: String?) throws -> UpsertResult? {
        guard !path.isEmpty else { return nil }
        return try upsert(text: nil, image: nil, thumbnail: nil, filePath: path, bytes: Data(path.utf8),
                          capturedAt: capturedAt, bundleID: bundleID, appName: appName)
    }

    private func upsert(text: String?, image: Data?, thumbnail: Data?, filePath: String?, bytes: Data,
                        capturedAt: Date, bundleID: String?, appName: String?) throws -> UpsertResult? {
        // Distinguish text, images and files even if their bytes match (domain byte 0 = text,
        // 1 = image, 2 = file). At capacity with only pins, don't write a new entry that would
        // immediately be evicted.
        let persistedTimestamp = capturedAt.timeIntervalSince1970
        let storedCapturedAt = Date(timeIntervalSince1970: persistedTimestamp)
        var digest = Data([filePath != nil ? 2 : (image == nil ? 0 : 1)])
        digest.append(contentsOf: SHA256.hash(data: bytes))
        let committed: (id: Int64, pinned: Bool, evicted: Set<Int64>)? = try lock.withLock {
            guard let db = try databaseLocked(create: true) else { throw StoreError.unavailable }
            return try transaction(db) {
                let existing = try statement(db, """
                    SELECT id, pinned, recency = (SELECT MAX(recency) FROM clips)
                    FROM clips WHERE digest = ? ORDER BY recency DESC LIMIT 1
                    """) { row -> (id: Int64, pinned: Bool, newest: Bool)? in
                    try bind(digest, to: row, at: 1)
                    guard try next(row) else { return nil }
                    return (sqlite3_column_int64(row, 0), sqlite3_column_int(row, 1) != 0, sqlite3_column_int(row, 2) != 0)
                }
                if let existing {
                    guard !existing.newest else { return nil }
                    try statement(db, """
                        UPDATE clips SET captured = ?1, bundle_id = ?2, app_name = ?3,
                            recency = (SELECT MAX(recency) + 1 FROM clips) WHERE id = ?4
                        """) { row in
                        try requireOK(sqlite3_bind_double(row, 1, persistedTimestamp))
                        try bind(bundleID, to: row, at: 2)
                        try bind(appName, to: row, at: 3)
                        try requireOK(sqlite3_bind_int64(row, 4, existing.id))
                        _ = try next(row)
                    }
                    return (existing.id, existing.pinned, [])
                }
                try statement(db, """
                    INSERT INTO clips (text, image, thumbnail, captured, bundle_id, app_name, digest, file_path, recency)
                    SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?9, COALESCE(MAX(recency), 0) + 1 FROM clips
                    HAVING (SELECT COUNT(*) FROM clips WHERE pinned = 1) < ?8
                    """) { row in
                    try bind(text, to: row, at: 1)
                    try bind(image, to: row, at: 2)
                    try bind(thumbnail, to: row, at: 3)
                    try requireOK(sqlite3_bind_double(row, 4, persistedTimestamp))
                    try bind(bundleID, to: row, at: 5)
                    try bind(appName, to: row, at: 6)
                    try bind(digest, to: row, at: 7)
                    try requireOK(sqlite3_bind_int64(row, 8, Int64(limit)))
                    try bind(filePath, to: row, at: 9)
                    _ = try next(row)
                }
                guard sqlite3_changes(db) != 0 else { return nil }
                let id = sqlite3_last_insert_rowid(db)
                let evicted = try pruneLocked(db, limit: limit)
                return (id, false, evicted)
            }
        }
        guard let committed else { return nil }
        let item = ClipboardItem(id: committed.id, text: text, capturedAt: storedCapturedAt,
                                 sourceBundleID: bundleID, sourceAppName: appName, pinned: committed.pinned,
                                 filePath: filePath)
        return UpsertResult(item: item, evictedIDs: committed.evicted)
    }

    func image(id: Int64) throws -> Data? { try validatedPNG("image", id: id) }
    func thumbnail(id: Int64) throws -> Data? { try validatedPNG("thumbnail", id: id) }

    private func validatedPNG(_ column: String, id: Int64) throws -> Data? {
        guard let bytes = try lock.withLock({ try imageBytesLocked(column, id: id) }),
              let source = Self.imageSource(bytes), Self.isDecodablePNG(source) else { return nil }
        return bytes
    }

    private func imageBytesLocked(_ column: String, id: Int64) throws -> Data? {
        guard let db = try databaseLocked() else { return nil }
        return try statement(db, "SELECT \(column) FROM clips WHERE id = ?1 AND typeof(\(column)) = 'blob' AND length(\(column)) BETWEEN 1 AND ?2") { row in
            try requireOK(sqlite3_bind_int64(row, 1, id))
            try requireOK(sqlite3_bind_int(row, 2, Int32(Self.maximumImageBytes)))
            guard try next(row) else { return nil }
            return data(row, 0)
        }
    }

    static func imageSource(_ bytes: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func isDecodablePNG(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_000_000 / height,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return false }
        // Check decoding without asking ImageIO to cache a full-resolution raster.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ] as CFDictionary) != nil
    }

    func noteUsed(id: Int64) throws {
        try lock.withLock {
            try updateLocked(id, "UPDATE clips SET recency = (SELECT MAX(recency) + 1 FROM clips) WHERE id = ?")
        }
    }

    func togglePin(id: Int64) throws {
        _ = try togglePinReturningEvicted(id: id)
    }

    func togglePinReturningEvicted(id: Int64) throws -> (pinned: Bool, evictedIDs: Set<Int64>)? {
        try lock.withLock {
            guard let db = try databaseLocked() else { return nil }
            return try transaction(db) {
                let pinned = try statement(db, "UPDATE clips SET pinned = 1 - pinned WHERE id = ? RETURNING pinned") { row -> Bool? in
                    try requireOK(sqlite3_bind_int64(row, 1, id))
                    var value: Bool?
                    while try next(row) { value = sqlite3_column_int(row, 0) != 0 }
                    return value
                }
                guard let pinned else { return nil }
                let evicted = try pruneLocked(db, limit: limit)
                return (pinned, evicted)
            }
        }
    }

    func remove(id: Int64) throws {
        try lock.withLock { try updateLocked(id, "DELETE FROM clips WHERE id = ?") }
    }

    func clearUnpinned() throws {
        try lock.withLock { if let db = try databaseLocked() { try execute(db, "DELETE FROM clips WHERE pinned = 0") } }
    }

    func clearAll() throws {
        try lock.withLock { if let db = try databaseLocked() { try execute(db, "DELETE FROM clips") } }
    }

    func setLimit(_ value: Int) throws {
        _ = try setLimitReturningEvicted(value)
    }

    func setLimitReturningEvicted(_ value: Int) throws -> Set<Int64> {
        try lock.withLock {
            let value = Self.boundedLimit(value)
            let evicted = if let db = try databaseLocked() { try pruneLocked(db, limit: value) } else { Set<Int64>() }
            limit = value
            return evicted
        }
    }

    private func pruneLocked(_ db: OpaquePointer, limit: Int) throws -> Set<Int64> {
        try statement(db, """
            DELETE FROM clips WHERE id IN (
                SELECT id FROM clips WHERE pinned = 0 ORDER BY recency DESC LIMIT -1
                OFFSET MAX(0, ? - (SELECT COUNT(*) FROM clips WHERE pinned = 1))
            ) RETURNING id
            """) { row in
            try requireOK(sqlite3_bind_int64(row, 1, Int64(limit)))
            var evicted: Set<Int64> = []
            while try next(row) { evicted.insert(sqlite3_column_int64(row, 0)) }
            return evicted
        }
    }

    private func updateLocked(_ id: Int64, _ sql: String) throws {
        guard let db = try databaseLocked() else { return }
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

    private func isPrivateStorageFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
    }

    private func storageFileExists(_ name: String, in directoryFD: Int32) throws -> Bool {
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard isPrivateStorageFile(info) else { throw StoreError.unavailable }
            return true
        }
        guard errno == ENOENT else { throw StoreError.unavailable }
        return false
    }

    private func databaseLocked(create: Bool = false) throws -> OpaquePointer? {
        guard let directoryFD = try openDirectory(directory, create: create) else { return nil }
        defer { close(directoryFD) }
        // All payloads are SQLite BLOBs, not separate files. Reject links on the
        // database and sidecars before chmod or any SQLite recovery or cleanup.
        let name = Self.databaseName
        let exists = try storageFileExists(name, in: directoryFD)
        for suffix in ["-wal", "-shm", "-journal"] { _ = try storageFileExists(name + suffix, in: directoryFD) }
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
            sqlite3_busy_timeout(db, 1000)
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
            try addFilePathColumnIfNeeded(db)
            connection = db
            return db
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    // Idempotent: databases created before file clips lack the column.
    private func addFilePathColumnIfNeeded(_ db: OpaquePointer) throws {
        let hasColumn = try statement(db, "PRAGMA table_info(clips)") { row in
            while try next(row) {
                if text(row, 1) == "file_path" { return true }
            }
            return false
        }
        if !hasColumn { try execute(db, "ALTER TABLE clips ADD COLUMN file_path TEXT") }
    }

    // Close the permission-setting descriptor before SQLite takes POSIX locks.
    private func prepareFile(_ name: String, in directoryFD: Int32, create: Bool) throws {
        let createFlags = create ? O_CREAT | O_EXCL : 0
        let fd = openat(directoryFD, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | createFlags, 0o600)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, isPrivateStorageFile(info), fchmod(fd, 0o600) == 0 else {
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
