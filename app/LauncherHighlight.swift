import CoreFoundation
import SwiftUI

struct LauncherHighlight {
    enum Mode { case literal, name, action }

    private static let comparison: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    private static let locale = Locale(identifier: "en_US_POSIX")
    private let terms: [String]
    private let fuzzyTerm: String

    init(_ query: String) {
        let words = LauncherFileQuery(query).words
        terms = words.split { $0.isWhitespace || "\"“”".contains($0) }.map(String.init)
        if terms.count == 1, terms[0].prefix(13).count <= 12 {
            fuzzyTerm = Self.normalized(terms[0])
        } else {
            fuzzyTerm = ""
        }
    }

    func text(_ value: String, size: CGFloat, colorScheme: ColorScheme, mode: Mode = .literal) -> AttributedString {
        var text = AttributedString(value)
        let matches = ranges(in: value, mode: mode)
        guard !matches.isEmpty else { return text }
        // Use a text-strength accent rather than the control tint (which can be pale in light mode).
        let tint = colorScheme == .dark ? Color(red: 0.60, green: 0.78, blue: 1)
            : Color(red: 0.07, green: 0.29, blue: 0.60)
        for match in matches {
            guard let start = AttributedString.Index(match.lowerBound, within: text),
                  let end = AttributedString.Index(match.upperBound, within: text) else { continue }
            text[start..<end].foregroundColor = tint
            text[start..<end].font = .system(size: size, weight: .semibold)
        }
        return text
    }

    private func ranges(in value: String, mode: Mode) -> [Range<String.Index>] {
        var matches: [Range<String.Index>] = []
        // Paths and excerpts stay literal; only display names need transliteration.
        lazy var pinyin = mode == .literal ? nil : Self.pinyin(for: value)
        for term in terms {
            let literal = Self.occurrences(of: term, in: value, options: Self.comparison)
            if !literal.isEmpty {
                // Foundation search can match a scalar inside an extended grapheme (e.g. a ZWJ emoji).
                let nsValue = value as NSString
                matches += literal.compactMap {
                    Range(nsValue.rangeOfComposedCharacterSequences(for: NSRange($0, in: value)), in: value)
                }
            } else if term.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                      let (alias, hanRanges) = pinyin {
                matches += alias.indices(for: term.lowercased()).map { hanRanges[$0] }
            }
        }
        if matches.isEmpty, mode == .action, (2...12).contains(fuzzyTerm.count) {
            // Prefer word starts so "vsc" paints V, S, C, not the s inside "Visual".
            matches = fuzzyRanges(in: value, initialsOnly: true)
            if matches.isEmpty { matches = fuzzyRanges(in: value, initialsOnly: false) }
        }
        var merged: [Range<String.Index>] = []
        for match in matches.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound >= match.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, match.upperBound)
            } else {
                merged.append(match)
            }
        }
        return merged
    }

    private static func occurrences(of term: String, in value: String,
                                    options: String.CompareOptions = []) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = value.startIndex
        while start < value.endIndex,
              let match = value.range(of: term, options: options, range: start..<value.endIndex, locale: locale) {
            ranges.append(match)
            start = match.upperBound
        }
        return ranges
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.folding(options: comparison, locale: locale)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func fuzzyRanges(in value: String, initialsOnly: Bool) -> [Range<String.Index>] {
        var remaining = fuzzyTerm[...]
        var matches: [Range<String.Index>] = []
        var atWordStart = true
        for index in value.indices {
            let character = value[index]
            if !initialsOnly || atWordStart {
                let before = remaining.startIndex
                for letter in Self.normalized(String(character)) where letter == remaining.first {
                    remaining = remaining.dropFirst()
                }
                if remaining.startIndex != before { matches.append(index..<value.index(after: index)) }
                if remaining.isEmpty { return matches }
            }
            atWordStart = !character.isLetter && !character.isNumber
        }
        return []
    }

    private final class Pinyin {
        let full: String
        let initials: String
        let owners: [Int]

        init(_ syllables: [Substring]) {
            full = syllables.joined()
            initials = String(syllables.compactMap(\.first))
            owners = syllables.enumerated().flatMap { index, syllable in
                Array(repeating: index, count: syllable.utf8.count)
            }
        }

        func indices(for term: String) -> [Int] {
            let matches = LauncherHighlight.occurrences(of: term, in: full)
            if !matches.isEmpty {
                return matches.flatMap { match in
                    let start = full.utf8.distance(from: full.startIndex, to: match.lowerBound)
                    let end = full.utf8.distance(from: full.startIndex, to: match.upperBound)
                    return owners[start]...owners[end - 1]
                }
            }
            return LauncherHighlight.occurrences(of: term, in: initials).flatMap { match in
                let start = initials.utf8.distance(from: initials.startIndex, to: match.lowerBound)
                let end = initials.utf8.distance(from: initials.startIndex, to: match.upperBound)
                return start..<end
            }
        }
    }

    private static let pinyinCache: NSCache<NSString, Pinyin> = {
        let cache = NSCache<NSString, Pinyin>()
        cache.countLimit = 256
        return cache
    }()

    private static func pinyin(for value: String) -> (Pinyin, [Range<String.Index>])? {
        guard value.prefix(65).count <= 64,
              value.unicodeScalars.contains(where: isHan) else { return nil }
        var han = String()
        var ranges: [Range<String.Index>] = []
        for index in value.indices {
            for scalar in value[index].unicodeScalars where isHan(scalar) {
                han.unicodeScalars.append(scalar)
                ranges.append(index..<value.index(after: index))
            }
        }
        // Transliterate the Han together, like LaunchCatalog.pinyinAliases, to preserve contextual readings.
        // Cache syllables, not String.Index values: the same Han can appear with different emoji or accents.
        let key = han as NSString
        if let cached = pinyinCache.object(forKey: key) { return (cached, ranges) }
        let latin = NSMutableString(string: han)
        CFStringTransform(latin, nil, kCFStringTransformToLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripCombiningMarks, false)
        let syllables = (latin as String).lowercased().split { !$0.isASCII || !$0.isLetter }
        // Only paint when the transform gives us an unambiguous syllable-to-Han mapping.
        let alias = Pinyin(syllables.count == ranges.count ? syllables : [])
        pinyinCache.setObject(alias, forKey: key)
        return (alias, ranges)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool { (0x3400...0x9fff).contains(scalar.value) }
}
