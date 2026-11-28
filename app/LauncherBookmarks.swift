import Combine
import CryptoKit
import Darwin
import Foundation

struct BookmarkSource: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case chromiumJSON
        case safariPlist
    }

    let browser: String
    let kind: Kind
    let url: URL

    static func defaultSources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BookmarkSource] {
        withNoDatalessMaterialization { () -> [BookmarkSource]? in
            let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            let chromiumRoots: [(browser: String, relativePath: String)] = [
                ("Chrome", "Google/Chrome"),
                ("Chrome Canary", "Google/Chrome Canary"),
                ("Edge", "Microsoft Edge"),
                ("Brave", "BraveSoftware/Brave-Browser"),
                ("Arc", "Arc/User Data"),
                ("Vivaldi", "Vivaldi"),
                ("Dia", "Dia/User Data"),
            ]

            let manager = FileManager.default
            let dirKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey]
            var results: [BookmarkSource] = []
            var seenPaths = Set<String>()

            func appendIfResident(_ browser: String, _ kind: Kind, _ fileURL: URL) {
                let normalizedPath = fileURL.standardizedFileURL.path
                guard seenPaths.insert(normalizedPath).inserted,
                      BookmarkFileIO.residentFileMtime(at: fileURL) != nil else { return }
                results.append(BookmarkSource(browser: browser, kind: kind, url: fileURL))
            }

            for entry in chromiumRoots {
                let rootURL = appSupport.appendingPathComponent(entry.relativePath, isDirectory: true)
                guard BookmarkFileIO.isResidentLocalDirectory(rootURL) else { continue }

                let defaultBookmarks = rootURL.appendingPathComponent("Default/Bookmarks", isDirectory: false)
                appendIfResident(entry.browser, .chromiumJSON, defaultBookmarks)

                guard let children = try? manager.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: dirKeys,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = child.lastPathComponent
                    guard name.hasPrefix("Profile ") else { continue }
                    let profileDir = rootURL.appendingPathComponent(name, isDirectory: true)
                    guard BookmarkFileIO.isResidentLocalDirectory(profileDir) else { continue }
                    let profileBookmarks = profileDir.appendingPathComponent("Bookmarks", isDirectory: false)
                    appendIfResident(entry.browser, .chromiumJSON, profileBookmarks)
                }
            }

            let safariURL = home.appendingPathComponent("Library/Safari/Bookmarks.plist", isDirectory: false)
            appendIfResident("Safari", .safariPlist, safariURL)
            return results
        } ?? []
    }
}

private enum BookmarkFileIO {
    static let maxBookmarkFileBytes: Int64 = 64 * 1024 * 1024

    static func isInCloudStorage(_ url: URL) -> Bool {
        let path = url.path + "/"
        return path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/")
    }

    static func isResidentLocalDirectory(_ url: URL) -> Bool {
        guard !isInCloudStorage(url) else { return false }
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              (st.st_flags & UInt32(SF_DATALESS)) == 0 else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
              values.isUbiquitousItem != true else { return false }
        return true
    }

    static func residentFileMtime(at url: URL) -> Date? {
        withNoDatalessMaterialization { () -> Date? in
            guard !isInCloudStorage(url) else { return nil }
            var st = Darwin.stat()
            guard lstat(url.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG,
                  (st.st_flags & UInt32(SF_DATALESS)) == 0 else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
                  values.isUbiquitousItem != true else { return nil }
            return Date(
                timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                    + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
            )
        }
    }

    static func readResidentFile(at url: URL) -> (data: Data, mtime: Date)? {
        withNoDatalessMaterialization { () -> (data: Data, mtime: Date)? in
            guard !isInCloudStorage(url) else { return nil }
            var lstatInfo = Darwin.stat()
            guard lstat(url.path, &lstatInfo) == 0,
                  (lstatInfo.st_mode & S_IFMT) == S_IFREG,
                  (lstatInfo.st_flags & UInt32(SF_DATALESS)) == 0 else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
                  values.isUbiquitousItem != true else { return nil }

            let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            var fstatInfo = Darwin.stat()
            guard fstat(fd, &fstatInfo) == 0,
                  (fstatInfo.st_mode & S_IFMT) == S_IFREG,
                  (fstatInfo.st_flags & UInt32(SF_DATALESS)) == 0,
                  fstatInfo.st_size >= 0,
                  fstatInfo.st_size <= maxBookmarkFileBytes else {
                close(fd)
                return nil
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard let data = try? handle.readToEnd() else { return nil }
            let mtime = Date(
                timeIntervalSince1970: TimeInterval(fstatInfo.st_mtimespec.tv_sec)
                    + TimeInterval(fstatInfo.st_mtimespec.tv_nsec) / 1_000_000_000.0
            )
            return (data, mtime)
        }
    }
}

private struct IndexedBookmark: Sendable {
    let hit: BookmarkHit
    let lowerTitle: String
    let normTitle: String
    let titleWords: [String]
    let pinyinTitle: [String]
    let lowerDomain: String
    let domainStem: String
    let normDomain: String
    let lowerURL: String
    let lowerFolder: String
    let normFolder: String
    let pinyinFolder: [String]
    let lowerBrowser: String

    init(hit: BookmarkHit) {
        self.hit = hit
        let lowerTitle = hit.title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        self.lowerTitle = lowerTitle
        self.normTitle = LaunchCatalog.normalized(hit.title)
        self.titleWords = lowerTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        self.pinyinTitle = LaunchCatalog.pinyinAliases(hit.title)
        let lowerDomain = hit.domain.lowercased()
        self.lowerDomain = lowerDomain
        self.domainStem = lowerDomain.split(separator: ".").first.map(String.init) ?? lowerDomain
        self.normDomain = LaunchCatalog.normalized(hit.domain)
        self.lowerURL = hit.url.lowercased()
        let lowerFolder = hit.folderPath.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        self.lowerFolder = lowerFolder
        self.normFolder = LaunchCatalog.normalized(hit.folderPath)
        self.pinyinFolder = LaunchCatalog.pinyinAliases(hit.folderPath)
        self.lowerBrowser = hit.browser.lowercased()
    }
}

private enum BookmarkParser {
    private static let allowedSchemes: Set<String> = ["http", "https", "file"]
    private static let maxDepth = 64

    static func parse(source: BookmarkSource, data: Data) -> [IndexedBookmark] {
        let hits: [BookmarkHit]
        switch source.kind {
        case .chromiumJSON:
            hits = parseChromiumJSON(data: data, browser: source.browser)
        case .safariPlist:
            hits = parseSafariPlist(data: data, browser: source.browser)
        }
        return hits.map(IndexedBookmark.init)
    }

    static func parseChromiumJSON(data: Data, browser: String) -> [BookmarkHit] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return [] }

        let preferredOrder = ["bookmark_bar", "other", "synced"]
        let extraKeys = roots.keys.filter { !preferredOrder.contains($0) }.sorted()
        let orderedKeys = preferredOrder.filter { roots[$0] != nil } + extraKeys

        var hits: [BookmarkHit] = []
        var seenURLs = Set<String>()

        func walk(node: [String: Any], folders: [String], depth: Int) {
            guard depth < maxDepth else { return }
            let nodeType = (node["type"] as? String)?.lowercased()
            if nodeType == "url" {
                guard let rawURL = (node["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let parsed = validatedBookmarkURL(rawURL),
                      seenURLs.insert(parsed.url).inserted else { return }
                let rawTitle = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = rawTitle.isEmpty ? (parsed.domain.isEmpty ? parsed.url : parsed.domain) : rawTitle
                let folderPath = folders.joined(separator: " / ")
                let id = stableID(browser: browser, url: parsed.url, folderPath: folderPath)
                hits.append(BookmarkHit(
                    id: id,
                    title: title,
                    url: parsed.url,
                    domain: parsed.domain,
                    browser: browser,
                    folderPath: folderPath
                ))
                return
            }

            if let children = node["children"] as? [[String: Any]] {
                let folderName = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let nextFolders = folderName.isEmpty ? folders : folders + [folderName]
                for child in children {
                    walk(node: child, folders: nextFolders, depth: depth + 1)
                }
            }
        }

        for key in orderedKeys {
            guard let branch = roots[key] as? [String: Any] else { continue }
            walk(node: branch, folders: [], depth: 0)
        }
        return hits
    }

    static func parseSafariPlist(data: Data, browser: String) -> [BookmarkHit] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return []
        }

        var hits: [BookmarkHit] = []
        var seenURLs = Set<String>()

        func friendlyFolderName(_ raw: String) -> String {
            switch raw {
            case "BookmarksBar": return "Favorites"
            case "BookmarksMenu": return "Bookmarks Menu"
            case "com.apple.ReadingList": return "Reading List"
            default: return raw
            }
        }

        func walk(node: [String: Any], folders: [String], depth: Int) {
            guard depth < maxDepth else { return }
            let bookmarkType = node["WebBookmarkType"] as? String ?? ""
            if bookmarkType == "WebBookmarkTypeProxy" { return }

            if bookmarkType == "WebBookmarkTypeLeaf" {
                guard let rawURL = (node["URLString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let parsed = validatedBookmarkURL(rawURL),
                      seenURLs.insert(parsed.url).inserted else { return }
                let uriDict = node["URIDictionary"] as? [String: Any]
                let rawTitle = ((uriDict?["title"] as? String) ?? (node["Title"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.isEmpty ? (parsed.domain.isEmpty ? parsed.url : parsed.domain) : rawTitle
                let folderPath = folders.joined(separator: " / ")
                let id = stableID(browser: browser, url: parsed.url, folderPath: folderPath)
                hits.append(BookmarkHit(
                    id: id,
                    title: title,
                    url: parsed.url,
                    domain: parsed.domain,
                    browser: browser,
                    folderPath: folderPath
                ))
                return
            }

            if let children = node["Children"] as? [[String: Any]] {
                let rawTitle = (node["Title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let folderName = friendlyFolderName(rawTitle)
                let nextFolders = (depth == 0 || folderName.isEmpty) ? folders : folders + [folderName]
                for child in children {
                    walk(node: child, folders: nextFolders, depth: depth + 1)
                }
            }
        }

        walk(node: plist, folders: [], depth: 0)
        return hits
    }

    private static func validatedBookmarkURL(_ raw: String) -> (url: String, domain: String)? {
        guard !raw.isEmpty, raw.utf8.count <= 4096,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }

        if scheme == "file" {
            let fileURL = URL(string: raw)
            let label = fileURL?.lastPathComponent.isEmpty == false ? (fileURL?.lastPathComponent ?? "file") : "file"
            return (raw, label)
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let domain = host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host
        return (raw, domain)
    }

    private static func stableID(browser: String, url: String, folderPath: String) -> String {
        let payload = browser.lowercased() + "\0" + url + "\0" + folderPath
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class BookmarkLibrary: ObservableObject {
    static let enabledKey = "lumen.bookmarksEnabled"

    @Published private(set) var enabled: Bool
    @Published private(set) var count: Int = 0

    private let defaults: UserDefaults
    private let customSources: [BookmarkSource]?
    private var activeSources: [BookmarkSource] = []
    private var fileMtimes: [URL: Date] = [:]
    private var fileEntries: [URL: [IndexedBookmark]] = [:]
    private var indexedEntries: [IndexedBookmark] = []
    private var lastSyncAt: Date?
    private var lastDiscoveryAt: Date?
    private var inFlightTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var parsedFileCount: Int = 0

    init(defaults: UserDefaults = .standard, sources: [BookmarkSource]? = nil) {
        self.defaults = defaults
        self.customSources = sources
        let storedEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.enabled = storedEnabled
        if storedEnabled {
            refreshIfNeeded(force: true)
        }
    }

    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.enabledKey)
        guard enabled != value else {
            if value { refreshIfNeeded(force: false) }
            return
        }
        enabled = value
        if !value {
            clearEntries()
        } else {
            refreshIfNeeded(force: true)
        }
    }

    func refreshIfNeeded(force: Bool = false) {
        guard enabled else { return }
        if !force {
            if inFlightTask != nil { return }
            if let lastSyncAt, Date().timeIntervalSince(lastSyncAt) < 2.0 { return }
        }
        let shouldForce = force
        Task { [weak self] in
            await self?.syncNow(force: shouldForce)
        }
    }

    func syncNow(force: Bool = false) async {
        guard enabled else {
            clearEntries()
            return
        }
        if !force, let existing = inFlightTask {
            await existing.value
            return
        }
        if force {
            inFlightTask?.cancel()
        }

        generation &+= 1
        let myGen = generation
        let explicitSources = customSources
        let knownSources = activeSources
        let cachedMtimes = force ? [:] : fileMtimes
        let cachedEntries = force ? [:] : fileEntries
        let shouldRediscover = explicitSources == nil
            && (force || lastDiscoveryAt == nil || Date().timeIntervalSince(lastDiscoveryAt!) > 30)

        struct SyncOutcome: Sendable {
            let sources: [BookmarkSource]
            let mtimes: [URL: Date]
            let entriesByURL: [URL: [IndexedBookmark]]
            let orderedEntries: [IndexedBookmark]
            let parsedCount: Int
            let changed: Bool
            let rediscovered: Bool
        }

        let task = Task<Void, Never> { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> SyncOutcome in
                let sources: [BookmarkSource]
                if let explicitSources {
                    sources = explicitSources
                } else if shouldRediscover || knownSources.isEmpty {
                    sources = BookmarkSource.defaultSources()
                } else {
                    sources = knownSources
                }

                var nextMtimes: [URL: Date] = [:]
                var nextEntries: [URL: [IndexedBookmark]] = [:]
                var parsedCount = 0
                var changed = force || sources != knownSources

                for source in sources {
                    guard !Task.isCancelled else {
                        return SyncOutcome(
                            sources: sources,
                            mtimes: nextMtimes,
                            entriesByURL: nextEntries,
                            orderedEntries: [],
                            parsedCount: parsedCount,
                            changed: false,
                            rediscovered: shouldRediscover
                        )
                    }
                    guard let liveMtime = BookmarkFileIO.residentFileMtime(at: source.url) else {
                        if cachedMtimes[source.url] != nil { changed = true }
                        continue
                    }
                    if !force,
                       let previousMtime = cachedMtimes[source.url],
                       previousMtime == liveMtime,
                       let reused = cachedEntries[source.url] {
                        nextMtimes[source.url] = previousMtime
                        nextEntries[source.url] = reused
                        continue
                    }
                    guard let file = BookmarkFileIO.readResidentFile(at: source.url) else {
                        if cachedMtimes[source.url] != nil { changed = true }
                        continue
                    }
                    let parsed = BookmarkParser.parse(source: source, data: file.data)
                    nextMtimes[source.url] = file.mtime
                    nextEntries[source.url] = parsed
                    parsedCount += 1
                    changed = true
                }

                if nextMtimes.count != cachedMtimes.count {
                    changed = true
                }

                var ordered: [IndexedBookmark] = []
                if changed {
                    var seenGlobal = Set<String>()
                    for source in sources {
                        guard let entries = nextEntries[source.url] else { continue }
                        for entry in entries {
                            let dedupeKey = entry.hit.browser.lowercased() + "\0" + entry.hit.url
                            if seenGlobal.insert(dedupeKey).inserted {
                                ordered.append(entry)
                            }
                        }
                    }
                }

                return SyncOutcome(
                    sources: sources,
                    mtimes: nextMtimes,
                    entriesByURL: nextEntries,
                    orderedEntries: ordered,
                    parsedCount: parsedCount,
                    changed: changed,
                    rediscovered: shouldRediscover
                )
            }.value

            guard let self, !Task.isCancelled, self.enabled, self.generation == myGen else { return }
            let now = Date()
            self.lastSyncAt = now
            if outcome.rediscovered { self.lastDiscoveryAt = now }
            self.activeSources = outcome.sources
            self.parsedFileCount += outcome.parsedCount
            if outcome.changed {
                self.fileMtimes = outcome.mtimes
                self.fileEntries = outcome.entriesByURL
                self.indexedEntries = outcome.orderedEntries
                if self.count != outcome.orderedEntries.count {
                    self.count = outcome.orderedEntries.count
                }
            }
            self.inFlightTask = nil
        }

        inFlightTask = task
        await task.value
    }

    func matches(_ query: String, limit: Int = 8) -> [(hit: BookmarkHit, score: Double)] {
        guard enabled, limit > 0, !indexedEntries.isEmpty else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return [] }

        let lowered = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let normQuery = LaunchCatalog.normalized(trimmed)
        let hasCJK = trimmed.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        guard trimmed.count >= 2 || hasCJK else { return [] }

        let tokens = lowered.split(whereSeparator: \.isWhitespace).map(String.init)
        let normTokens = tokens.map(LaunchCatalog.normalized)
        guard !tokens.isEmpty else { return [] }

        var scored: [(hit: BookmarkHit, score: Double)] = []
        scored.reserveCapacity(min(limit * 2, indexedEntries.count))

        for entry in indexedEntries {
            guard let score = Self.score(
                entry: entry,
                lowerQuery: lowered,
                normQuery: normQuery,
                tokens: tokens,
                normTokens: normTokens
            ) else { continue }
            scored.append((entry.hit, score))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.hit.title.count != rhs.hit.title.count { return lhs.hit.title.count < rhs.hit.title.count }
            return lhs.hit.id < rhs.hit.id
        }
        return Array(scored.prefix(limit))
    }

    private func clearEntries() {
        generation &+= 1
        inFlightTask?.cancel()
        inFlightTask = nil
        fileMtimes.removeAll()
        fileEntries.removeAll()
        indexedEntries.removeAll()
        lastSyncAt = nil
        lastDiscoveryAt = nil
        if count != 0 { count = 0 }
    }

    private static func score(
        entry: IndexedBookmark,
        lowerQuery: String,
        normQuery: String,
        tokens: [String],
        normTokens: [String]
    ) -> Double? {
        if tokens.count == 1 {
            return singleTokenScore(entry: entry, lowerToken: lowerQuery, normToken: normQuery)
        }

        var sum = 0.0
        var titleOrDomainHits = 0
        for index in tokens.indices {
            guard let tokenScore = singleTokenScore(
                entry: entry,
                lowerToken: tokens[index],
                normToken: normTokens[index],
                allowSingleChar: true
            ) else { return nil }
            sum += tokenScore
            if tokenScore >= 62 { titleOrDomainHits += 1 }
        }

        let average = sum / Double(tokens.count)
        let bonus = titleOrDomainHits == tokens.count ? 4.0 : 0.0
        return min(84.0, max(45.0, average + bonus))
    }

    private static func singleTokenScore(
        entry: IndexedBookmark,
        lowerToken: String,
        normToken: String,
        allowSingleChar: Bool = false
    ) -> Double? {
        guard allowSingleChar || lowerToken.count >= 2 || lowerToken.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else {
            return nil
        }

        if entry.lowerTitle == lowerToken || (!normToken.isEmpty && entry.normTitle == normToken) {
            return 84.0
        }
        if entry.lowerDomain == lowerToken || entry.domainStem == lowerToken || (!normToken.isEmpty && entry.normDomain == normToken) {
            return 82.0
        }
        if entry.lowerTitle.hasPrefix(lowerToken) || (!normToken.isEmpty && entry.normTitle.hasPrefix(normToken)) {
            return 78.0
        }
        if entry.lowerDomain.hasPrefix(lowerToken) || entry.domainStem.hasPrefix(lowerToken) {
            return 76.0
        }
        if entry.titleWords.contains(where: { $0.hasPrefix(lowerToken) }) {
            return 72.0
        }
        if !normToken.isEmpty, entry.pinyinTitle.contains(normToken) {
            return 72.0
        }
        if entry.lowerTitle.contains(lowerToken) || (!normToken.isEmpty && entry.normTitle.contains(normToken)) {
            return 68.0
        }
        if entry.lowerDomain.contains(lowerToken) || (!normToken.isEmpty && entry.normDomain.contains(normToken)) {
            return 65.0
        }
        if !normToken.isEmpty, entry.pinyinTitle.contains(where: { $0.hasPrefix(normToken) }) {
            return 63.0
        }
        if lowerToken.count >= 2, entry.lowerURL.contains(lowerToken) {
            return 56.0
        }
        if !normToken.isEmpty, entry.pinyinTitle.contains(where: { $0.contains(normToken) }) {
            return 54.0
        }
        if !entry.lowerFolder.isEmpty,
           entry.lowerFolder.contains(lowerToken)
           || (!normToken.isEmpty && (entry.normFolder.contains(normToken) || entry.pinyinFolder.contains(where: { $0.hasPrefix(normToken) }))) {
            return 50.0
        }
        if lowerToken.count >= 2, entry.lowerBrowser == lowerToken || entry.lowerBrowser.hasPrefix(lowerToken) {
            return 46.0
        }
        return nil
    }
}
