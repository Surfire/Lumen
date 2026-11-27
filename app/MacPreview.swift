#if os(macOS)
import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct MacPreviewRenderer: Sendable {
    private static let maxOutput = 4 * 1024 * 1024
    private static let maxPixels = 64_000_000

    func load(_ item: PreviewSelection, isPending: (URL) -> Bool) throws -> PreviewDocument {
        try Task.checkCancellation()
        guard item.evidence == nil || !item.revision.isEmpty else { throw PreviewFailure.missing }
        return try LocalFile.withResidentFile(item.url, expectedStamp: item.revision.isEmpty ? nil : item.revision,
                                              isPending: isPending) {
            switch item.kind {
            case .quickLook:
                // The launcher opens Quick Look only after the resident-file check succeeds.
                return PreviewDocument()
            case .excerpt:
                guard let evidence = item.evidence, !evidence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PreviewFailure.noExcerpt
                }
                let context = Self.plainTextContext(at: item.url, evidence: evidence)
                return PreviewDocument(evidence: PreviewEvidence(text: evidence.text,
                                                                 match: evidence.match,
                                                                 page: evidence.page,
                                                                 context: context,
                                                                 highlight: evidence.highlight))
            case .image:
                return PreviewDocument(visual: .image(try thumbnail(item.url)), evidence: item.evidence)
            case .pdf(let page):
                return try pdf(item.url, matchPage: page, evidence: item.evidence)
            }
        }
    }

    private func thumbnail(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= Self.maxPixels / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 960,
              ] as CFDictionary) else { throw PreviewFailure.invalidContent }
        return try png(image)
    }

    private func pdf(_ url: URL, matchPage: Int?, evidence: PreviewEvidence?) throws -> PreviewDocument {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw PreviewFailure.invalidContent
        }
        let number = matchPage ?? 1
        guard number > 0, number <= document.pageCount,
              let page = document.page(at: number - 1) else { throw PreviewFailure.unavailablePage }

        let box = page.bounds(for: .cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            throw PreviewFailure.invalidContent
        }
        let longest = max(box.width, box.height)
        let size = CGSize(width: max(1, floor(960 * (box.width / longest))),
                          height: max(1, floor(960 * (box.height / longest))))
        try Task.checkCancellation()
        // Rasterize a single page in a fixed-size bitmap: independent of AppKit
        // backing scale. Never route the actual file through Quick Look implicitly.
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: color,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreviewFailure.invalidContent
        }
        let outRect = CGRect(origin: .zero, size: size)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(outRect)
        guard let ref = page.pageRef else { throw PreviewFailure.invalidContent }
        ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: outRect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(ref)
        if matchPage != nil {
            let selections = Self.pdfPageSelections(in: document, on: page, highlight: evidence?.highlight, snippet: evidence?.text)
            if !selections.isEmpty {
                ctx.saveGState()
                ctx.setFillColor(CGColor(red: 1.0, green: 0.82, blue: 0.18, alpha: 0.34))
                for selection in selections {
                    for line in selection.selectionsByLine() where line.pages.contains(page) {
                        let lineRect = line.bounds(for: page)
                        if !lineRect.isEmpty {
                            ctx.fill(lineRect.insetBy(dx: -2, dy: -1))
                        }
                    }
                }
                ctx.restoreGState()
            }
        }
        guard let bitmap = ctx.makeImage() else { throw PreviewFailure.invalidContent }
        let validEvidence = evidence.flatMap { $0.page == nil || $0.page == number ? $0 : nil }
        return PreviewDocument(visual: .pdf(try png(bitmap), displayedPage: number, isMatchPage: matchPage != nil),
                               evidence: validEvidence)
    }

    static func pdfPageSelections(
        in document: PDFDocument,
        on page: PDFPage,
        highlight: String?,
        snippet: String?
    ) -> [PDFSelection] {
        var candidates: [String] = []
        if let snippet {
            let clean = snippet.trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespacesAndNewlines))
            if clean.count >= 4 {
                candidates.append(clean)
                if clean.count > 48 { candidates.append(String(clean.prefix(48))) }
                for clause in clean.split(whereSeparator: { $0 == "\n" || $0 == "。" || $0 == "." || $0 == "；" || $0 == ";" }) {
                    let piece = String(clause).trimmingCharacters(in: .whitespacesAndNewlines)
                    if piece.count >= 4 { candidates.append(piece) }
                }
            }
        }
        if let highlight {
            let trimmed = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init).filter { token in
                let lower = token.lowercased()
                return !lower.isEmpty && !lower.hasPrefix("kind:") && !lower.hasPrefix("path:")
                    && !lower.hasPrefix("ext:") && !token.hasPrefix("/") && !token.hasPrefix("~/")
            }
            let phrase = tokens.joined(separator: " ")
            if phrase.count >= 2 { candidates.append(phrase) }
            for token in tokens where token.count >= 2 { candidates.append(token) }
        }
        var seen = Set<String>()
        let needles = candidates.filter { seen.insert($0.lowercased()).inserted }
        var matches: [PDFSelection] = []
        for needle in needles {
            for selection in document.findString(needle, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
                if selection.pages.contains(page) {
                    matches.append(selection)
                    if matches.count >= 24 { return matches }
                }
            }
            if !matches.isEmpty && needle.count >= 12 { break }
        }
        return matches
    }

    private func png(_ image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw PreviewFailure.invalidContent
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder), data.length <= Self.maxOutput else {
            throw PreviewFailure.invalidContent
        }
        try Task.checkCancellation()
        return Data(referencing: data)
    }

    private static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "xml",
        "html", "htm", "log", "toml", "ini", "rs", "swift", "py", "js", "ts",
        "tsx", "jsx", "c", "h", "cpp", "hpp", "m", "mm", "go", "rb", "java",
        "kt", "sh", "zsh", "sql", "css", "scss",
    ]
    private static let maxPlainTextBytes = 512 * 1024

    private static func plainTextContext(at url: URL, evidence: PreviewEvidence) -> String? {
        guard plainTextExtensions.contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxPlainTextBytes + 1) else { return nil }
        let truncatedAtCap = data.count > maxPlainTextBytes
        let sample = truncatedAtCap ? data.prefix(maxPlainTextBytes) : data
        guard let text = String(data: sample, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleanSnippet = evidence.text.trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespacesAndNewlines))
        let anchorRange = findAnchor(in: text, snippet: cleanSnippet, highlight: evidence.highlight)
        // If a large plain-text file's match sits beyond the 512 KB read cap, defer to indexed document body.
        if truncatedAtCap && anchorRange == nil { return nil }
        return extractContextWindow(from: text, anchor: anchorRange, maxChars: 1600)
    }

    private static func findAnchor(in text: String, snippet: String, highlight: String?) -> Range<String.Index>? {
        if !snippet.isEmpty {
            if let range = text.range(of: snippet) { return range }
            let prefix = String(snippet.prefix(48))
            if prefix.count >= 6, let range = text.range(of: prefix) { return range }
        }
        if let highlight = highlight?.trimmingCharacters(in: .whitespacesAndNewlines), !highlight.isEmpty {
            if let range = text.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) {
                return range
            }
            if let first = highlight.split(whereSeparator: \.isWhitespace).first(where: { $0.count >= 2 }),
               let range = text.range(of: String(first), options: [.caseInsensitive, .diacriticInsensitive]) {
                return range
            }
        }
        return nil
    }

    private static func extractContextWindow(from text: String, anchor: Range<String.Index>?, maxChars: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxChars { return trimmed }

        let anchorStart = anchor?.lowerBound ?? text.startIndex
        let beforeBudget = maxChars / 3
        var start = text.index(anchorStart, offsetBy: -beforeBudget, limitedBy: text.startIndex) ?? text.startIndex
        if start > text.startIndex {
            let snapLimit = text.index(start, offsetBy: 160, limitedBy: anchorStart) ?? anchorStart
            if let newline = text[start..<snapLimit].firstIndex(of: "\n") {
                start = text.index(after: newline)
            }
        }
        let charsBefore = text.distance(from: start, to: anchorStart)
        let afterBudget = max(0, maxChars - charsBefore)
        var end = text.index(anchorStart, offsetBy: afterBudget, limitedBy: text.endIndex) ?? text.endIndex
        if end < text.endIndex {
            let minAnchor = text.index(anchorStart, offsetBy: 64, limitedBy: end) ?? end
            let snapFloor = text.index(end, offsetBy: -160, limitedBy: minAnchor) ?? minAnchor
            if snapFloor < end, let newline = text[snapFloor..<end].lastIndex(of: "\n") {
                end = newline
            }
        }
        let slice = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slice.isEmpty else { return nil }
        let prefix = start > text.startIndex && !text[..<start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "…\n" : ""
        let suffix = end < text.endIndex && !text[end...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\n…" : ""
        return prefix + slice + suffix
    }
}
#endif
