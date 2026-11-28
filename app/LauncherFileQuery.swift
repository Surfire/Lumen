import Foundation

/// Normalize Spotlight-style qualifiers before sending them to the lexical engine.
struct LauncherFileQuery {
    private static let tokenRegex = try! NSRegularExpression(pattern: #"(?:[^\s"“”]+|["“][^"”]*(?:["”]|$))+"#)

    let words: String
    private let kinds: [String]
    private let paths: [String]
    private let extensions: [String]

    // A single effective kind lets the launcher skip a redundant folder text lookup.
    var kind: String? {
        guard let first = kinds.first, kinds.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    var isFiltered: Bool { !kinds.isEmpty || !paths.isEmpty || !extensions.isEmpty }

    static func normalizedDirectoryScope(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var normalized = trimmed.precomposedStringWithCanonicalMapping
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized == "/" ? "/" : normalized + "/"
    }

    init(_ raw: String, scopedDirectory: String? = nil) {
        let fullRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let tokens = Self.tokenRegex.matches(in: raw, range: fullRange).compactMap { match in
            Range(match.range, in: raw).map { String(raw[$0]) }
        }
        var words: [String] = []
        var extensions: [String] = []
        var kinds: [String] = []
        var paths: [String] = []
        if let scopedDirectory {
            let normalizedScope = Self.normalizedDirectoryScope(scopedDirectory)
            if !normalizedScope.isEmpty {
                paths.append(normalizedScope)
            }
        }
        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("kind:") {
                let value = lower.dropFirst(5)
                switch value {
                case "folder", "directory": kinds.append("folder")
                case "doc", "image", "video", "audio", "code", "archive", "app": kinds.append(String(value))
                default: words.append(token)
                }
            } else if lower.hasPrefix("path:"), let prefix = Self.prefix(String(token.dropFirst(5))) {
                paths.append(prefix)
            } else if let prefix = Self.prefix(token) {
                paths.append(prefix)
            } else if lower.hasPrefix("ext:") {
                let value = lower.dropFirst(4)
                let ext = value.hasPrefix(".") ? value.dropFirst() : value
                if !ext.isEmpty && ext.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) {
                    extensions.append("ext:\(ext)")
                } else {
                    words.append(token)
                }
            } else {
                words.append(token)
            }
        }
        self.words = words.joined(separator: " ")
        self.kinds = kinds
        self.paths = paths
        self.extensions = extensions
    }

    var engineQuery: String {
        // The engine intersects paths and rejects conflicts; don't deduplicate or collapse qualifiers here.
        var tokens = paths.map { path in
            let quoteCharacters = "\"“”"
            let escaped = path.map { quoteCharacters.contains($0) || $0 == "\\" ? "\\\($0)" : String($0) }.joined()
            return path.contains(where: \.isWhitespace) ? "\"\(escaped)\"" : escaped
        }
        tokens += kinds.map { "kind:\($0)" }
        tokens += extensions
        if !words.isEmpty { tokens.append(words) }
        return tokens.joined(separator: " ")
    }

    private static func prefix(_ value: String) -> String? {
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard unquoted.hasPrefix("/") || unquoted.hasPrefix("~/") else { return nil }
        // Preserve the trailing slash, which distinguishes a subtree from its root row.
        return unquoted.precomposedStringWithCanonicalMapping
    }
}
