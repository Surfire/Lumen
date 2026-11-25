import Foundation

/// Normalize Spotlight-style qualifiers before sending them to the lexical engine.
struct LauncherFileQuery {
    let words: String
    let kind: String?
    let path: String?
    let extensions: [String]

    var isFiltered: Bool { kind != nil || path != nil || !extensions.isEmpty }

    init(_ raw: String) {
        let pattern = #"(?:[^\s"“”]+|["“][^"”]*(?:["”]|$))+"#
        let tokens = raw.ranges(of: pattern, options: .regularExpression).map { String(raw[$0]) }
        var words: [String] = []
        var extensions: [String] = []
        var kind: String?
        var path: String?
        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("kind:") {
                switch lower.dropFirst(5) {
                case "folder", "directory": kind = "folder"
                case "doc", "image", "video", "audio", "code", "archive", "app": kind = String(lower.dropFirst(5))
                default: words.append(token)
                }
            } else if lower.hasPrefix("path:"), let prefix = Self.prefix(String(token.dropFirst(5))) {
                path = prefix
            } else if let prefix = Self.prefix(token) {
                path = prefix
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
        self.kind = kind
        self.path = path
        self.extensions = extensions
    }

    var engineQuery: String {
        var tokens = extensions
        if !words.isEmpty { tokens.append(words) }
        if let kind { tokens.insert("kind:\(kind)", at: 0) }
        if let path {
            let quoteCharacters = "\"“”"
            let escaped = path.map { quoteCharacters.contains($0) || $0 == "\\" ? "\\\($0)" : String($0) }.joined()
            tokens.insert(path.contains(where: \.isWhitespace) ? "\"\(escaped)\"" : escaped, at: 0)
        }
        return tokens.joined(separator: " ")
    }

    private static func prefix(_ value: String) -> String? {
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard unquoted.hasPrefix("/") || unquoted.hasPrefix("~/") else { return nil }
        // Preserve the trailing slash, which distinguishes a subtree from its root row.
        return unquoted.precomposedStringWithCanonicalMapping
    }
}

private extension String {
    func ranges(of pattern: String, options: String.CompareOptions) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex, let match = range(of: pattern, options: options, range: start..<endIndex) {
            ranges.append(match)
            start = match.upperBound
        }
        return ranges
    }
}
