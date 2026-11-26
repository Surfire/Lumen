import CoreFoundation
import os
import SwiftUI

struct LauncherHighlight {
    enum Mode { case literal, name, action }

    private static let comparison: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let maxTerms = 16
    private static let maxCharacters = 512
    private static let maxRuns = 64
    // Same shorthand set as common_extension in src/query.rs, not the full kind lists.
    private static let commonExtensions = Set("""
        pdf doc docx ppt pptx xls xlsx txt md markdown rtf odt ods odp csv tsv json yaml yml xml html htm
        png jpg jpeg gif webp heic svg tiff tif bmp mp3 wav m4a aac flac mp4 mov mkv avi webm zip rar 7z gz tar dmg
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let kinds: Set<String> = ["kind:doc", "kind:image", "kind:video", "kind:audio",
                                            "kind:code", "kind:archive", "kind:folder", "kind:app"]
    private let fileTerms: [String]
    private let actionTerms: [String]
    private let fuzzyTerm: String

    init(_ query: String) {
        // Only paths and colon qualifiers need the launcher's syntax normalization.
        let input = query.utf8.contains { $0 == 47 || $0 == 58 } ? LauncherFileQuery(query).engineQuery : query
        let tokens = Self.tokenize(input)
        // Like the engine, decide whether bare extensions are filters before removing qualifiers.
        let hasSearchWord = tokens.contains { $0.quoted || (!Self.isExtension($0.key) && !Self.commonExtensions.contains($0.key)) }
        var files: [String] = [], actions: [String] = []
        var seenFiles: Set<String> = [], seenActions: Set<String> = []
        collect: for (word, key, quoted) in tokens {
            if key.hasPrefix("/") || key.hasPrefix("~/") { continue }
            let explicit = !quoted && Self.isExtension(key)
            if !quoted && (Self.kinds.contains(key) || (explicit && key.hasPrefix("ext:"))) { continue }
            let fileFilter = explicit || (!quoted && hasSearchWord && Self.commonExtensions.contains(key))
            for part in word.split(whereSeparator: \.isWhitespace) {
                let term = part.folding(options: Self.comparison, locale: Self.locale)
                guard !term.isEmpty else { continue }
                if !fileFilter && files.count < Self.maxTerms && seenFiles.insert(term).inserted { files.append(term) }
                if actions.count < Self.maxTerms && seenActions.insert(term).inserted { actions.append(term) }
                if files.count == Self.maxTerms && actions.count == Self.maxTerms { break collect }
            }
        }
        fileTerms = files
        actionTerms = actions
        fuzzyTerm = actions.count == 1 && actions[0].prefix(13).count <= 12 ? Self.normalized(actions[0]) : ""
    }

    private static func isExtension(_ word: String) -> Bool {
        let ext: Substring
        if word.hasPrefix(".") { ext = word.dropFirst() }
        else if word.hasPrefix("ext:") { ext = word.dropFirst(4) }
        else { return false }
        return !ext.isEmpty && ext.utf8.allSatisfy(isASCIILetterOrDigit)
    }

    private static func tokenize(_ query: String) -> [(word: String, key: String, quoted: Bool)] {
        let quotes = "\"“”"
        var tokens: [(String, String, Bool)] = []
        var seenUnquoted: Set<String> = [], seenQuoted: Set<String> = []
        var word = ""
        var quoted = false
        func push() {
            guard !word.isEmpty else { return }
            defer { word = "" }
            let inserted = quoted ? seenQuoted.insert(word).inserted : seenUnquoted.insert(word).inserted
            if inserted && (!quoted || word.contains(where: { !$0.isWhitespace })) {
                tokens.append((word, word.precomposedStringWithCompatibilityMapping.lowercased(), quoted))
            }
        }
        var index = query.startIndex
        while index < query.endIndex {
            let character = query[index]
            query.formIndex(after: &index)
            if character == "\\", index < query.endIndex, quotes.contains(query[index]) || query[index] == "\\" {
                word.append(query[index])
                query.formIndex(after: &index)
            } else if quotes.contains(character) {
                push()
                quoted.toggle()
            } else if !quoted && character.isWhitespace {
                push()
            } else {
                word.append(character)
            }
        }
        push()
        return tokens
    }

    func text(_ value: String, size: CGFloat, colorScheme: ColorScheme, mode: Mode = .literal) -> AttributedString {
        // These rows truncate to a single line. Keep the full value, but only search and style its prefix.
        let scanned = String(value.prefix(Self.maxCharacters))
        let matches = ranges(in: scanned, mode: mode)
        var text = AttributedString(value)
        guard !matches.isEmpty else { return text }
        // Use a text-strength accent rather than the control tint (which can be pale in light mode).
        let tint = colorScheme == .dark ? Color(red: 0.60, green: 0.78, blue: 1)
            : Color(red: 0.07, green: 0.29, blue: 0.60)
        let style = AttributeContainer().foregroundColor(tint).font(.system(size: size, weight: .semibold))
        // The scan starts at offset zero, so its indices refer to the same prefix of the attributed value.
        for match in matches {
            guard let start = AttributedString.Index(match.lowerBound, within: text),
                  let end = AttributedString.Index(match.upperBound, within: text) else { continue }
            text[start..<end].mergeAttributes(style)
        }
        return text
    }

    private func ranges(in value: String, mode: Mode) -> [Range<String.Index>] {
        let terms = mode == .action ? actionTerms : fileTerms
        guard !terms.isEmpty else { return [] }
        var matches: [Range<String.Index>] = []
        let nsValue = value as NSString
        // Paths and excerpts stay literal; only display names need transliteration.
        lazy var pinyin = mode == .literal ? nil : Self.pinyin(for: value)
        for term in terms {
            let literal = Self.occurrences(of: term, in: nsValue)
            if !literal.isEmpty {
                // Foundation search can match a scalar inside an extended grapheme (e.g. a ZWJ emoji).
                matches += literal.compactMap {
                    Range(nsValue.rangeOfComposedCharacterSequences(for: $0), in: value)
                }
            } else if term.utf8.allSatisfy(Self.isASCIILetterOrDigit),
                      let (alias, indices) = pinyin {
                matches += alias.indices(for: term, allowsSubsequence: mode == .action)
                    .map { indices[$0]..<indices[$0 + 1] }
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
                // Avoid creating hundreds of separately styled runs for inputs like "a a a ...".
                guard merged.count < Self.maxRuns else { break }
                merged.append(match)
            }
        }
        return merged
    }

    private static func occurrences(of term: String, in value: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        let end = value.length
        while start < end {
            let match = value.range(of: term, options: comparison,
                                    range: NSRange(start..<end), locale: locale)
            guard match.location != NSNotFound, match.length > 0 else { break }
            if let last = ranges.last, NSMaxRange(last) == match.location {
                ranges[ranges.count - 1].length += match.length
            } else {
                ranges.append(match)
            }
            start = NSMaxRange(match)
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

    private struct PinyinAlias {
        // Aliases are ASCII, so NSString ranges and UTF-8 offsets index the same owners.
        let text: NSString
        let owners: [Int]

        init(_ pieces: [String]) {
            text = pieces.joined() as NSString
            owners = pieces.enumerated().flatMap { index, piece in
                Array(repeating: index, count: piece.utf8.count)
            }
        }

        func contiguous(_ term: String) -> [Int]? {
            let ranges = LauncherHighlight.occurrences(of: term, in: text)
            return ranges.isEmpty ? nil : ranges.flatMap { owners[$0.location..<NSMaxRange($0)] }
        }

        func subsequence(_ term: String) -> [Int]? {
            var remaining = term.utf8[...]
            var matches: [Int] = []
            for (offset, letter) in (text as String).utf8.enumerated() where letter == remaining.first {
                matches.append(owners[offset])
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return matches }
            }
            return nil
        }
    }

    private final class Pinyin {
        let variants: [(full: PinyinAlias, initials: PinyinAlias)]

        init(current: [String], legacy: [String], asciiAlphanumeric: [Bool]) {
            variants = (current == legacy ? [current] : [current, legacy]).map { tokens in
                let initials = tokens.enumerated().map { offset, token in
                    // Like the indexer, take one initial per ASCII word and one per Han syllable.
                    // Keep empty pieces so alias owners still point to the original characters.
                    if offset > 0 && asciiAlphanumeric[offset] && asciiAlphanumeric[offset - 1] { return "" }
                    return String(token.prefix(1))
                }
                return (PinyinAlias(tokens), PinyinAlias(initials))
            }
        }

        func indices(for term: String, allowsSubsequence: Bool) -> Set<Int> {
            for (full, initials) in variants {
                if let matches = full.contiguous(term) ?? initials.contiguous(term) { return Set(matches) }
            }
            if allowsSubsequence && term.utf8.count >= 2 {
                // Prefer syllable starts, just as the Latin fallback prefers word starts.
                for (full, initials) in variants {
                    if let matches = initials.subsequence(term) ?? full.subsequence(term) { return Set(matches) }
                }
            }
            return []
        }
    }

    private struct BoundedLRU<Key: Hashable, Value> {
        let capacity: Int
        private var entries: [Key: (value: Value, tick: UInt64)] = [:]
        private var tick: UInt64 = 0

        init(capacity: Int) {
            self.capacity = capacity
        }

        mutating func value(for key: Key) -> Value? {
            guard var entry = entries[key] else { return nil }
            tick &+= 1
            entry.tick = tick
            entries[key] = entry
            return entry.value
        }

        mutating func insert(_ value: Value, for key: Key) {
            tick &+= 1
            if entries[key] == nil, entries.count >= capacity,
               let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key {
                entries.removeValue(forKey: oldest)
            }
            entries[key] = (value, tick)
        }
    }

    private static let pinyinCache = OSAllocatedUnfairLock(initialState: BoundedLRU<String, Pinyin>(capacity: 512))
    private static let transliterateCache = OSAllocatedUnfairLock(initialState: BoundedLRU<String, [String]>(capacity: 512))

    // Keep the current and older catalog syllables in sync with src/pinyin.rs.
    private static let readings = [
        ("成都", "cheng du", "cheng dou"), ("重庆", "chong qing", "chong qing"),
        ("厦门", "xia men", "sha men"), ("长沙", "chang sha", "zhang sha"),
        ("长春", "chang chun", "zhang chun"), ("长安", "chang an", "zhang an"),
        ("长治", "chang zhi", "zhang zhi"), ("六安", "lu an", "liu an"),
        ("西藏", "xi zang", "xi cang"), ("银行", "yin hang", "yin xing"), ("音乐", "yin yue", "yin le"),
    ]

    private static func pinyin(for value: String) -> (Pinyin, [String.Index])? {
        guard value.prefix(65).count <= 64,
              value.unicodeScalars.contains(where: isHan) else { return nil }
        let indices = Array(value.indices) + [value.endIndex]
        // Cache owner offsets, not String.Index values, and include Latin and separators in the key.
        if let cached = pinyinCache.withLock({ $0.value(for: value) }) { return (cached, indices) }

        let characters = Array(value)
        let asciiAlphanumeric = characters.map { $0.utf8.count == 1 && $0.utf8.allSatisfy(isASCIILetterOrDigit) }
        var current = Array(repeating: "", count: characters.count)
        var legacy = current
        var offset = 0
        while offset < characters.count {
            let character = characters[offset]
            guard let scalar = character.unicodeScalars.first, isHan(scalar) else {
                if asciiAlphanumeric[offset] {
                    current[offset] = character.lowercased()
                    legacy[offset] = current[offset]
                }
                offset += 1
                continue
            }
            // Keep Han context within a run, rather than inventing a phrase across Latin or punctuation.
            let start = offset
            var han = ""
            while offset < characters.count, let scalar = characters[offset].unicodeScalars.first, isHan(scalar) {
                han.unicodeScalars.append(scalar)
                offset += 1
            }
            var input = han, oldInput = han
            for (phrase, reading, oldReading) in readings where han.contains(phrase) {
                input = input.replacingOccurrences(of: phrase, with: " \(reading) ")
                oldInput = oldInput.replacingOccurrences(of: phrase, with: " \(oldReading) ")
            }
            let syllables = transliterate(input)
            // Only paint when the transform gives us an unambiguous syllable-to-Han mapping.
            if syllables.count == offset - start {
                current.replaceSubrange(start..<offset, with: syllables)
            }
            let oldSyllables = input == oldInput ? syllables : transliterate(oldInput)
            if oldSyllables.count == offset - start {
                legacy.replaceSubrange(start..<offset, with: oldSyllables)
            }
        }
        let pinyin = Pinyin(current: current, legacy: legacy, asciiAlphanumeric: asciiAlphanumeric)
        pinyinCache.withLock { $0.insert(pinyin, for: value) }
        return (pinyin, indices)
    }

    private static func transliterate(_ input: String) -> [String] {
        if let cached = transliterateCache.withLock({ $0.value(for: input) }) { return cached }
        let latin = NSMutableString(string: input)
        CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripDiacritics, false)
        let result = (latin as String).lowercased().split { !$0.isASCII || !$0.isLetter }.map(String.init)
        transliterateCache.withLock { $0.insert(result, for: input) }
        return result
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9fff).contains(scalar.value) || (0x20000...0x2ffff).contains(scalar.value)
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (97...122).contains(byte | 32) || (48...57).contains(byte)
    }
}
