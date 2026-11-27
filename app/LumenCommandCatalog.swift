import Foundation

public enum LumenCommandResolution: Equatable, Sendable {
    case search
    /// Invoke the existing translation parser using the unchanged original string.
    case translation
    case discovery
    case missingArgument(commandID: String)
    case argumentTooLong(commandID: String, maximumUTF8Bytes: Int)
    case question(String)
    case image(String)
    case clipboard(String)
    case window(String)
    case web(commandID: String, title: String, url: URL)
}

public struct LumenHTTPSQueryLink: Sendable {
    public let commandID: String
    public let keyword: String
    public let title: String
    private let baseURL: URL
    private let queryKey: String
    private let fixedQueryItems: [URLQueryItem]

    /// The configured base must be an HTTPS origin/path, with no credentials, query, or fragment.
    public init?(commandID: String, keyword: String, title: String, baseURL: URL, queryKey: String, fixedQueryItems: [URLQueryItem] = []) {
        let ascii = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".utf8)
        guard !commandID.isEmpty, !title.isEmpty, !keyword.isEmpty, keyword.utf8.count <= 24,
              keyword.utf8.allSatisfy({ ascii.contains($0) }),
              keyword.utf8.first.map({ (65...90).contains($0) || (97...122).contains($0) }) == true,
              !queryKey.isEmpty, queryKey.utf8.count <= 64,
              queryKey.utf8.allSatisfy({ ascii.contains($0) || $0 == 95 }),
              let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              !fixedQueryItems.contains(where: { $0.name == queryKey }) else { return nil }
        self.commandID = commandID
        self.keyword = keyword.lowercased()
        self.title = title
        self.baseURL = baseURL
        self.queryKey = queryKey
        self.fixedQueryItems = fixedQueryItems
    }

    public func url(for query: String) -> URL? {
        guard !query.isEmpty, query.utf8.count <= LumenCommandCatalog.maximumURLArgumentBytes,
              var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        // Encode '+' as %2B: HTML form-style decoders otherwise treat it as a space.
        // Construct a single query field; arbitrary text cannot become a second parameter.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        parts.queryItems = fixedQueryItems.isEmpty ? nil : fixedQueryItems
        let prefix = parts.percentEncodedQuery.map { $0 + "&" } ?? ""
        parts.percentEncodedQuery = prefix + queryKey + "=" + escaped
        return parts.url
    }

    public var destinationHost: String { baseURL.host ?? "" }
}

public struct LumenCommandCatalog: Sendable {
    public struct Entry: Equatable, Sendable {
        public let keyword: String
        public let title: String
        public let commandID: String
        public let destinationHost: String?
    }

    public static let maximumURLArgumentBytes = 2_048
    public static let maximumQuestionBytes = 16_384
    private static let reservedVerbs: Set<String> = ["qa", "tr", "translate", "img", "cb", "clip", "win"]
    private static let defaultLinks = builtInLinks([
        ("google", "g", "Search Google", "https://www.google.com/search", "q")
    ])
    private static let optionalLinksZH = optionalBuiltInLinks(chinese: true)
    private static let optionalLinksEN = optionalBuiltInLinks(chinese: false)
    private let links: [String: LumenHTTPSQueryLink]

    private static func optionalBuiltInLinks(chinese: Bool) -> [LumenHTTPSQueryLink] {
        builtInLinks([
            ("github", "gh", "Search GitHub", "https://github.com/search", "q"),
            ("wikipedia", "wiki", "Search Wikipedia",
             chinese ? "https://zh.wikipedia.org/w/index.php" : "https://en.wikipedia.org/w/index.php", "search"),
            ("maps", "map", "Search Maps", "https://www.google.com/maps/search/", "query")
        ])
    }

    static func isBuiltInAlias(_ alias: String, includeOptionalLinks: Bool) -> Bool {
        reservedVerbs.contains(alias) || defaultLinks.contains { $0.keyword == alias }
            || (includeOptionalLinks && optionalLinksZH.contains { $0.keyword == alias })
    }

    /// Built-in verbs and Google stay reserved. Saved links take precedence over
    /// opt-in built-ins so enabling those searches cannot redirect an existing alias.
    public init(includeOptionalLinks: Bool = false, additionalLinks: [LumenHTTPSQueryLink] = [], chinese: Bool = true) {
        var table: [String: LumenHTTPSQueryLink] = [:]
        var usedIDs = Set(["qa", "translate", "discover", "img", "clipboard", "window"])
        let optionals = includeOptionalLinks ? (chinese ? Self.optionalLinksZH : Self.optionalLinksEN) : []
        for link in Self.defaultLinks + additionalLinks + optionals {
            guard !Self.reservedVerbs.contains(link.keyword), table[link.keyword] == nil,
                  usedIDs.insert(link.commandID).inserted else { continue }
            table[link.keyword] = link
        }
        links = table
    }

    public var entries: [Entry] {
        [.init(keyword: "?", title: "Browse Commands", commandID: "discover", destinationHost: nil),
         .init(keyword: "qa", title: "Ask Model", commandID: "qa", destinationHost: nil),
         .init(keyword: "tr", title: "Translate", commandID: "translate", destinationHost: nil),
         .init(keyword: "img", title: "Search Images", commandID: "img", destinationHost: nil),
         .init(keyword: "cb", title: "Clipboard History", commandID: "clipboard", destinationHost: nil),
         .init(keyword: "win", title: "Window Management", commandID: "window", destinationHost: nil)]
        + links.values.sorted { $0.keyword < $1.keyword }.map {
            Entry(keyword: $0.keyword, title: $0.title, commandID: $0.commandID, destinationHost: $0.destinationHost)
        }
    }

    public func resolve(_ input: String, isExistingTranslation: (String) -> Bool = { _ in false }) -> LumenCommandResolution {
        // Pass raw input to the active 0.3.2 translator; no clone of its multilingual parsing.
        if isExistingTranslation(input) { return .translation }
        if input == "?" { return .discovery }
        // Bare qa/g are still searchable filenames. Except for cb/clip, a command
        // starts at the first character and requires a space/tab. Newlines are payload only.
        let delimiter = input.firstIndex(where: { $0 == " " || $0 == "\t" })
        let token = input[..<(delimiter ?? input.endIndex)]
        guard !token.isEmpty, token.utf8.count <= (delimiter == nil ? 4 : 24),
              token.utf8.allSatisfy({ $0 < 128 }) else { return .search }
        let keyword = token.lowercased()
        let isClipboard = keyword == "cb" || keyword == "clip"
        guard let delimiter else {
            if isClipboard { return .clipboard("") }
            return keyword == "win" ? .window("") : .search
        }
        let payload = input[input.index(after: delimiter)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if isClipboard { return .clipboard(payload) }
        if keyword == "win" { return .window(payload) }
        if keyword == "img" {
            if payload.isEmpty { return .missingArgument(commandID: "img") }
            if payload.utf8.count > 8192 { return .argumentTooLong(commandID: "img", maximumUTF8Bytes: 8192) }
            return .image(payload)
        }
        if keyword == "qa" {
            if payload.isEmpty { return .missingArgument(commandID: "qa") }
            if payload.utf8.count > Self.maximumQuestionBytes {
                return .argumentTooLong(commandID: "qa", maximumUTF8Bytes: Self.maximumQuestionBytes)
            }
            return .question(payload)
        }
        guard let link = links[keyword] else { return .search }
        if payload.isEmpty { return .missingArgument(commandID: link.commandID) }
        guard let url = link.url(for: payload) else {
            return .argumentTooLong(commandID: link.commandID, maximumUTF8Bytes: Self.maximumURLArgumentBytes)
        }
        return .web(commandID: link.commandID, title: link.title, url: url)
    }

    private static func builtInLinks(_ definitions: [(String, String, String, String, String)]) -> [LumenHTTPSQueryLink] {
        definitions.compactMap { id, verb, title, base, key in
            guard let url = URL(string: base) else { return nil }
            let fixed = id == "maps" ? [URLQueryItem(name: "api", value: "1")] : []
            return .init(commandID: id, keyword: verb, title: title, baseURL: url, queryKey: key, fixedQueryItems: fixed)
        }
    }
}
