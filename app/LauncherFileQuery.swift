import Foundation

/// Launcher-only qualifiers; the free text and extension syntax still go to the index.
struct LauncherFileQuery {
    let words: String
    let kind: String?
    let path: String?

    var isFiltered: Bool { kind != nil || path != nil || words.split(whereSeparator: \.isWhitespace).contains { $0.lowercased().hasPrefix("ext:") } }

    init(_ raw: String) {
        let pattern = #"(?:[^\s"“”]+|["“][^"”]*(?:["”]|$))+"#
        let tokens = raw.ranges(of: pattern, options: .regularExpression).map { String(raw[$0]) }
        var words: [String] = []
        var kind: String?
        var path: String?
        for token in tokens {
            let lower = token.lowercased()
            if lower.hasPrefix("kind:") {
                switch lower.dropFirst(5) {
                case "folder", "directory": kind = "directory"
                case "file": kind = "file"
                default: words.append(token)
                }
            } else if lower.hasPrefix("path:"), let prefix = Self.prefix(String(token.dropFirst(5))) {
                path = prefix
            } else if let prefix = Self.prefix(token) {
                path = prefix
            } else if lower.hasPrefix("ext:.") {
                words.append("ext:" + token.dropFirst(5))
            } else {
                words.append(token)
            }
        }
        self.words = words.joined(separator: " ")
        self.kind = kind
        self.path = path
    }

    // Include the prefix as a name/path search term to avoid retrieving global candidates first.
    var nameTerm: String {
        guard let path else { return words.isEmpty && kind != nil ? "/" : words }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return [words, "\"\(escaped)\""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func contains(_ hit: SearchHit) -> Bool {
        if let kind, hit.kind != kind { return false }
        guard let path else { return true }
        let candidate = hit.path.precomposedStringWithCanonicalMapping
        return candidate.localizedLowercase.hasPrefix(path.localizedLowercase)
    }

    private static func prefix(_ value: String) -> String? {
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        let path = (unquoted as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
        return path.hasPrefix("/") ? path : nil
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
