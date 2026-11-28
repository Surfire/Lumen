#if os(macOS)
import AppKit
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

enum DocumentPreviewRenderer {
    private static let maxMarkdownBytes = 2 * 1024 * 1024
    private static let maxWordBytes = 12 * 1024 * 1024
    private static let maxSpreadsheetBytes = 16 * 1024 * 1024
    private static let maxDelimitedBytes = 2 * 1024 * 1024
    private static let maxPlainTextBytes = 512 * 1024
    private static let maxDelimitedRows = 1500
    private static let maxDelimitedCols = 64
    private static let maxAttachmentBytes = 8 * 1024 * 1024
    private static let maxTotalAttachmentBytes = 16 * 1024 * 1024
    private static let maxAttachments = 32

    /// Renders a resident local file into a self-contained HTML preview package.
    /// Callers must already be inside `LocalFile.withResidentFile`.
    static func render(
        url: URL,
        format: RichPreviewFormat,
        evidence: PreviewEvidence?,
        isPending: (URL) -> Bool = LocalFile.isUbiquitousPlaceholder
    ) -> RichPreviewContent? {
        switch format {
        case .markdown:
            return renderMarkdown(url: url, evidence: evidence, isPending: isPending)
        case .word:
            return renderWord(url: url, evidence: evidence)
        case .spreadsheet:
            return renderSpreadsheet(url: url, evidence: evidence)
        case .delimited:
            return renderDelimited(url: url, evidence: evidence)
        case .plainText:
            guard let text = readBoundedUTF8(at: url, maxBytes: maxPlainTextBytes) else { return nil }
            let isCode = MacPreviewRenderer.isCodeExtension(url.pathExtension)
            return renderPlainText(text: text, isCode: isCode, fileName: url.lastPathComponent, evidence: evidence)
        }
    }

    static func renderPlainText(
        text: String,
        isCode: Bool,
        fileName: String,
        evidence: PreviewEvidence?
    ) -> RichPreviewContent {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let headerHTML = "<div class=\"lumen-file-header\"><span class=\"lumen-file-name\">\(escapeHTML(fileName))</span><span class=\"lumen-file-meta\">\(lines.count) lines</span></div>"
        let bodyHTML: String
        if isCode {
            var out = String()
            out.reserveCapacity(normalized.utf8.count + lines.count * 44)
            out += headerHTML
            out += "<pre class=\"lumen-code-view\"><code>"
            for line in lines {
                out += "<span class=\"lumen-code-line\">"
                out += escapeHTML(String(line))
                out += "\n</span>"
            }
            out += "</code></pre>"
            bodyHTML = out
        } else {
            bodyHTML = headerHTML + "<div class=\"lumen-plain-prose\">\(escapeHTML(normalized))</div>"
        }
        return wrapDocument(
            format: .plainText,
            bodyHTML: bodyHTML,
            extraCSS: "",
            localResources: [:],
            memoryResources: [:],
            memoryMimeTypes: [:],
            evidence: evidence,
            prefersPaperCanvas: false,
            bodyClass: isCode ? "lumen-mode-code" : "lumen-mode-plain"
        )
    }

    // MARK: - Bounded File Readers

    private static func readExactBoundedData(at url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1),
              !data.isEmpty,
              data.count <= maxBytes else {
            return nil
        }
        return data
    }

    private static func readBoundedUTF8(at url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        let bytes = [UInt8](data)
        guard !bytes.isEmpty, !bytes.contains(0) else { return nil }
        var end = bytes.count
        if end == maxBytes {
            var lead = end - 1
            while lead >= 0, end - lead <= 3, bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
            if lead >= 0, bytes[lead] >= 0xC0 {
                let needed = bytes[lead] >= 0xF0 ? 4 : (bytes[lead] >= 0xE0 ? 3 : 2)
                if end - lead < needed { end = lead }
            }
        }
        return String(data: Data(bytes[..<end]), encoding: .utf8)
    }

    // MARK: - Markdown Renderer

    private static func renderMarkdown(
        url: URL,
        evidence: PreviewEvidence?,
        isPending: (URL) -> Bool
    ) -> RichPreviewContent? {
        guard let source = readBoundedUTF8(at: url, maxBytes: maxMarkdownBytes) else { return nil }
        let baseDir = url.deletingLastPathComponent().standardizedFileURL
        let (renderedBody, localResources): (String, [String: URL]) = withoutActuallyEscaping(isPending) { escapingPending in
            var context = MarkdownRenderContext(baseDirectory: baseDir, isPending: escapingPending)
            return (context.renderDocument(source), context.localResources)
        }
        return wrapDocument(
            format: .markdown,
            bodyHTML: "<article class=\"lumen-markdown\">\(renderedBody)</article>",
            extraCSS: "",
            localResources: localResources,
            memoryResources: [:],
            memoryMimeTypes: [:],
            evidence: evidence,
            prefersPaperCanvas: false,
            bodyClass: "lumen-mode-markdown"
        )
    }

    // MARK: - Word (DOCX / RTF) Renderer

    private static func renderWord(url: URL, evidence: PreviewEvidence?) -> RichPreviewContent? {
        guard let data = readExactBoundedData(at: url, maxBytes: maxWordBytes) else { return nil }
        let ext = url.pathExtension.lowercased()
        let docType: NSAttributedString.DocumentType = (ext == "rtf") ? .rtf : .officeOpenXML
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: docType],
            documentAttributes: nil
        ) else {
            return nil
        }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let salt = randomHex(byteCount: 8)
        var memoryResources: [String: Data] = [:]
        var memoryMimeTypes: [String: String] = [:]
        var replacementTags: [(marker: String, html: String)] = []
        var totalAttBytes = 0

        var attachmentRanges: [(NSRange, NSTextAttachment)] = []
        mutable.enumerateAttribute(.attachment, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                attachmentRanges.append((range, attachment))
            }
        }

        for (reverseOffset, pair) in attachmentRanges.reversed().enumerated() {
            let index = attachmentRanges.count - 1 - reverseOffset
            let (range, attachment) = pair
            if memoryResources.count < maxAttachments,
               let (imgData, mime) = extractImageData(from: attachment),
               imgData.count <= maxAttachmentBytes,
               totalAttBytes + imgData.count <= maxTotalAttachmentBytes {
                let token = "\(index)"
                memoryResources[token] = imgData
                memoryMimeTypes[token] = mime
                totalAttBytes += imgData.count
                let marker = "LUMENATT\(salt)X\(token)END"
                let alt = attachment.fileWrapper?.preferredFilename ?? "Image \(index + 1)"
                let imgHTML = "<img class=\"lumen-docx-img\" src=\"lumen-local://att/\(token)\" alt=\"\(escapeHTML(alt))\">"
                replacementTags.append((marker: marker, html: imgHTML))
                mutable.replaceCharacters(in: range, with: marker)
            } else {
                mutable.replaceCharacters(in: range, with: "")
            }
        }

        guard let htmlData = try? mutable.data(
            from: NSRange(location: 0, length: mutable.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ),
        let rawHTML = String(data: htmlData, encoding: .utf8),
        !rawHTML.isEmpty else {
            return nil
        }

        let extractedCSS = sanitizeCocoaCSS(extractTagContent(from: rawHTML, tag: "style") ?? "")
        let rawBody = extractTagContent(from: rawHTML, tag: "body") ?? rawHTML
        var safeBody = HTMLSanitizer.sanitize(rawBody, allowClasses: true) { _, _ in nil }
        for item in replacementTags {
            safeBody = safeBody.replacingOccurrences(of: item.marker, with: item.html)
        }
        guard !safeBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let wrappedBody = "<div class=\"lumen-paper-stage\"><div class=\"lumen-paper-sheet\">\(safeBody)</div></div>"
        return wrapDocument(
            format: .word,
            bodyHTML: wrappedBody,
            extraCSS: extractedCSS,
            localResources: [:],
            memoryResources: memoryResources,
            memoryMimeTypes: memoryMimeTypes,
            evidence: evidence,
            prefersPaperCanvas: true,
            bodyClass: "lumen-mode-word"
        )
    }

    private static func extractImageData(from attachment: NSTextAttachment) -> (Data, String)? {
        if let raw = attachment.fileWrapper?.regularFileContents ?? attachment.contents, !raw.isEmpty {
            if let mime = detectImageMime(data: raw, fileType: attachment.fileType, filename: attachment.fileWrapper?.preferredFilename) {
                if mime == "image/tiff", let png = convertToPNG(raw) {
                    return (png, "image/png")
                }
                return (raw, mime)
            }
            if let png = convertToPNG(raw) {
                return (png, "image/png")
            }
        }
        if let image = attachment.image,
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = encodePNG(cgImage) {
            return (png, "image/png")
        }
        return nil
    }

    private static func detectImageMime(data: Data, fileType: String?, filename: String?) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "image/png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 6,
           (bytes.starts(with: [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) || bytes.starts(with: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
            return "image/gif"
        }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        if bytes.count >= 4,
           (bytes[0...3] == [0x49, 0x49, 0x2A, 0x00] || bytes[0...3] == [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }
        if let fileType, let ut = UTType(fileType), ut.conforms(to: .image), let mime = ut.preferredMIMEType {
            return mime
        }
        if let filename {
            let ext = (filename as NSString).pathExtension.lowercased()
            if let ut = UTType(filenameExtension: ext), ut.conforms(to: .image), let mime = ut.preferredMIMEType {
                return mime
            }
        }
        return nil
    }

    private static func convertToPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return encodePNG(cgImage)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Data(referencing: out)
    }

    private static func extractTagContent(from html: String, tag: String) -> String? {
        guard let openStart = html.range(of: "<\(tag)", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: openStart.upperBound..<html.endIndex),
              let closeStart = html.range(of: "</\(tag)>", options: .caseInsensitive, range: openEnd.upperBound..<html.endIndex),
              openEnd.upperBound <= closeStart.lowerBound else {
            return nil
        }
        return String(html[openEnd.upperBound..<closeStart.lowerBound])
    }

    private static func sanitizeCocoaCSS(_ css: String) -> String {
        guard !css.isEmpty else { return "" }
        var cleaned = css.replacingOccurrences(of: "<", with: "")
        let forbiddenPatterns = [
            "@import[^;]*;?",
            "url\\s*\\([^)]*\\)",
            "expression\\s*\\([^)]*\\)",
            "behavior\\s*:[^;]*;?",
            "-moz-binding\\s*:[^;]*;?",
        ]
        for pattern in forbiddenPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned),
                    withTemplate: ""
                )
            }
        }
        return cleaned
    }

    // MARK: - Spreadsheet (XLSX) Renderer

    private struct XLSXPreviewPayload: Decodable {
        struct Sheet: Decodable {
            let name: String
            let rows: [[String]]
            let truncated: Bool
        }
        let sheets: [Sheet]
    }

    private static func renderSpreadsheet(url: URL, evidence: PreviewEvidence?) -> RichPreviewContent? {
        guard let data = readExactBoundedData(at: url, maxBytes: maxSpreadsheetBytes) else { return nil }
        let jsonString: String? = data.withUnsafeBytes { raw -> String? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            guard let ptr = lumen_preview_xlsx_json(base, raw.count) else { return nil }
            defer { lumen_string_free(ptr) }
            return String(cString: ptr)
        }
        guard let jsonString,
              let jsonData = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(XLSXPreviewPayload.self, from: jsonData),
              !payload.sheets.isEmpty else {
            return nil
        }

        var html = String()
        html.reserveCapacity(min(512 * 1024, jsonString.utf8.count * 2 + 2048))
        html += "<div class=\"lumen-sheet-shell\">"
        html += "<div class=\"lumen-sheet-tabs\" role=\"tablist\">"
        for (idx, sheet) in payload.sheets.enumerated() {
            let active = idx == 0 ? " is-active" : ""
            html += "<button type=\"button\" class=\"lumen-sheet-tab\(active)\" role=\"tab\" aria-selected=\"\(idx == 0 ? "true" : "false")\" data-sheet-idx=\"\(idx)\" data-sheet-name=\"\(escapeHTML(sheet.name))\">\(escapeHTML(sheet.name))</button>"
        }
        html += "</div>"

        for (idx, sheet) in payload.sheets.enumerated() {
            let active = idx == 0 ? " is-active" : ""
            html += "<section class=\"lumen-sheet-panel\(active)\" data-sheet-idx=\"\(idx)\" data-sheet-name=\"\(escapeHTML(sheet.name))\">"
            if sheet.rows.isEmpty {
                html += "<div class=\"lumen-sheet-empty\">Empty sheet</div>"
            } else {
                let colCount = max(1, sheet.rows.reduce(0) { max($0, $1.count) })
                html += "<div class=\"lumen-sheet-wrap\"><table class=\"lumen-grid-table\"><thead><tr><th class=\"lumen-row-num\">#</th>"
                for c in 0..<colCount {
                    html += "<th>\(excelColumnName(c))</th>"
                }
                html += "</tr></thead><tbody>"
                for (rIdx, row) in sheet.rows.enumerated() {
                    let rowClass = rIdx == 0 ? " class=\"lumen-first-row\"" : ""
                    html += "<tr\(rowClass)><td class=\"lumen-row-num\">\(rIdx + 1)</td>"
                    for c in 0..<colCount {
                        let cell = c < row.count ? row[c] : ""
                        let cls = isNumericCell(cell) ? " class=\"lumen-num\"" : ""
                        html += "<td\(cls)>\(escapeHTML(cell))</td>"
                    }
                    html += "</tr>"
                }
                html += "</tbody></table></div>"
            }
            if sheet.truncated {
                html += "<div class=\"lumen-truncated-note\">Large workbook preview truncated to keep rendering instant.</div>"
            }
            html += "</section>"
        }
        html += "</div>"

        return wrapDocument(
            format: .spreadsheet,
            bodyHTML: html,
            extraCSS: "",
            localResources: [:],
            memoryResources: [:],
            memoryMimeTypes: [:],
            evidence: evidence,
            prefersPaperCanvas: false,
            bodyClass: "lumen-mode-spreadsheet"
        )
    }

    private static func excelColumnName(_ index: Int) -> String {
        var n = index
        var letters: [Character] = []
        repeat {
            let rem = n % 26
            if let scalar = UnicodeScalar(65 + rem) {
                letters.append(Character(scalar))
            }
            n = (n / 26) - 1
        } while n >= 0
        return String(letters.reversed())
    }

    private static func isNumericCell(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return false }
        var stripped = trimmed
        for prefix in ["¥", "$", "€", "£", "+", "-"] where stripped.hasPrefix(prefix) {
            stripped.removeFirst()
            break
        }
        if stripped.hasSuffix("%") { stripped.removeLast() }
        stripped = stripped.replacingOccurrences(of: ",", with: "")
        guard !stripped.isEmpty else { return false }
        var sawDigit = false
        var sawDot = false
        for ch in stripped {
            if ch.isASCII && ch.isNumber {
                sawDigit = true
            } else if ch == "." && !sawDot {
                sawDot = true
            } else {
                return false
            }
        }
        return sawDigit
    }

    // MARK: - Delimited (CSV / TSV) Renderer

    private static func renderDelimited(url: URL, evidence: PreviewEvidence?) -> RichPreviewContent? {
        guard let text = readBoundedUTF8(at: url, maxBytes: maxDelimitedBytes) else { return nil }
        let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let (rows, truncated) = parseDelimited(text, delimiter: delimiter, maxRows: maxDelimitedRows, maxCols: maxDelimitedCols)
        guard !rows.isEmpty else { return nil }

        let colCount = max(1, rows.reduce(0) { max($0, $1.count) })
        var html = "<div class=\"lumen-sheet-shell\"><div class=\"lumen-sheet-wrap\"><table class=\"lumen-grid-table\"><thead><tr><th class=\"lumen-row-num\">#</th>"
        let headerRow = rows[0]
        for c in 0..<colCount {
            let label = c < headerRow.count && !headerRow[c].isEmpty ? headerRow[c] : excelColumnName(c)
            html += "<th>\(escapeHTML(label))</th>"
        }
        html += "</tr></thead><tbody>"
        for (idx, row) in rows.dropFirst().enumerated() {
            html += "<tr><td class=\"lumen-row-num\">\(idx + 1)</td>"
            for c in 0..<colCount {
                let cell = c < row.count ? row[c] : ""
                let cls = isNumericCell(cell) ? " class=\"lumen-num\"" : ""
                html += "<td\(cls)>\(escapeHTML(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table></div>"
        if truncated {
            html += "<div class=\"lumen-truncated-note\">Preview truncated at \(maxDelimitedRows) rows / \(maxDelimitedCols) columns.</div>"
        }
        html += "</div>"

        return wrapDocument(
            format: .delimited,
            bodyHTML: html,
            extraCSS: "",
            localResources: [:],
            memoryResources: [:],
            memoryMimeTypes: [:],
            evidence: evidence,
            prefersPaperCanvas: false,
            bodyClass: "lumen-mode-spreadsheet"
        )
    }

    private static func parseDelimited(
        _ input: String,
        delimiter: Character,
        maxRows: Int,
        maxCols: Int
    ) -> (rows: [[String]], truncated: Bool) {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = String()
        var inQuotes = false
        var truncated = false
        let chars = Array(input)
        var i = 0

        func finishField() {
            if currentRow.count < maxCols {
                currentRow.append(field)
            } else {
                truncated = true
            }
            field.removeAll(keepingCapacity: true)
        }

        func finishRow() {
            finishField()
            if currentRow.count == 1 && currentRow[0].isEmpty && i >= chars.count {
                currentRow.removeAll(keepingCapacity: true)
                return
            }
            if rows.count < maxRows {
                rows.append(currentRow)
            } else {
                truncated = true
            }
            currentRow.removeAll(keepingCapacity: true)
        }

        while i < chars.count {
            if rows.count >= maxRows {
                truncated = true
                break
            }
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(ch)
                    i += 1
                }
            } else {
                if ch == "\"" && field.isEmpty {
                    inQuotes = true
                    i += 1
                } else if ch == delimiter {
                    finishField()
                    i += 1
                } else if ch == "\r" {
                    if i + 1 < chars.count && chars[i + 1] == "\n" { i += 2 } else { i += 1 }
                    finishRow()
                } else if ch == "\n" {
                    i += 1
                    finishRow()
                } else {
                    field.append(ch)
                    i += 1
                }
            }
        }
        if !field.isEmpty || !currentRow.isEmpty {
            if rows.count < maxRows {
                finishRow()
            } else {
                truncated = true
            }
        }
        return (rows, truncated)
    }

    // MARK: - Highlight Candidate Extraction

    private static func highlightNeedles(from evidence: PreviewEvidence?) -> (primary: [String], secondary: [String]) {
        guard let evidence else { return ([], []) }
        var queryNeedles: [String] = []
        var snippetNeedles: [String] = []
        var seenQuery = Set<String>()
        var seenSnippet = Set<String>()

        func push(_ candidate: String, into list: inout [String], seen: inout Set<String>, minCount: Int) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minCount else { return }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return }
            if list.count < 16 { list.append(trimmed) }
        }

        if let rawHighlight = evidence.highlight?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHighlight.isEmpty {
            let tokens = rawHighlight.split(whereSeparator: \.isWhitespace).map { raw -> String in
                String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            }.filter { token in
                let lower = token.lowercased()
                return !lower.isEmpty && !lower.hasPrefix("kind:") && !lower.hasPrefix("path:")
                    && !lower.hasPrefix("ext:") && !token.hasPrefix("/") && !token.hasPrefix("~/")
            }
            let phrase = tokens.joined(separator: " ")
            if phrase.count >= 2 || containsCJK(phrase) {
                push(phrase, into: &queryNeedles, seen: &seenQuery, minCount: containsCJK(phrase) ? 1 : 2)
            }
            for token in tokens.sorted(by: { $0.count > $1.count }) {
                let minLen = containsCJK(token) ? 1 : 2
                push(token, into: &queryNeedles, seen: &seenQuery, minCount: minLen)
            }
        }

        let cleanSnippet = evidence.text
            .trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespacesAndNewlines))
        if cleanSnippet.count >= 4 {
            push(cleanSnippet, into: &snippetNeedles, seen: &seenSnippet, minCount: 4)
            let collapsed = cleanSnippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if collapsed != cleanSnippet {
                push(collapsed, into: &snippetNeedles, seen: &seenSnippet, minCount: 4)
            }
            if cleanSnippet.count > 48 {
                push(String(cleanSnippet.prefix(48)), into: &snippetNeedles, seen: &seenSnippet, minCount: 4)
            }
            let clauses = cleanSnippet.split(whereSeparator: {
                $0 == "\n" || $0 == "。" || $0 == "." || $0 == "；" || $0 == ";" ||
                $0 == "！" || $0 == "!" || $0 == "？" || $0 == "?" || $0 == "|" || $0 == "\t"
            })
            for clause in clauses {
                let piece = String(clause).trimmingCharacters(in: .whitespacesAndNewlines)
                if piece.count >= 4 || (containsCJK(piece) && piece.count >= 2) {
                    push(piece, into: &snippetNeedles, seen: &seenSnippet, minCount: containsCJK(piece) ? 2 : 4)
                }
            }
        }

        if evidence.match == .related {
            let dedupedQuery = queryNeedles.filter { !seenSnippet.contains($0.lowercased()) }
            return (snippetNeedles, dedupedQuery)
        }
        let dedupedSnippet = snippetNeedles.filter { !seenQuery.contains($0.lowercased()) }
        return (queryNeedles, dedupedSnippet)
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x3040...0x30FF).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    // MARK: - Document Shell, Native CSS & Highlight JS

    private static func wrapDocument(
        format: RichPreviewFormat,
        bodyHTML: String,
        extraCSS: String,
        localResources: [String: URL],
        memoryResources: [String: Data],
        memoryMimeTypes: [String: String],
        evidence: PreviewEvidence?,
        prefersPaperCanvas: Bool,
        bodyClass: String
    ) -> RichPreviewContent {
        let nonce = randomHex(byteCount: 16)
        let needles = highlightNeedles(from: evidence)
        let hasHighlights = !needles.primary.isEmpty || !needles.secondary.isEmpty
        let primaryJSON = encodeJSONStringArray(needles.primary)
        let secondaryJSON = encodeJSONStringArray(needles.secondary)

        let csp = "default-src 'none'; img-src lumen-local:; style-src 'nonce-\(nonce)'; script-src 'nonce-\(nonce)'; font-src 'none'; base-uri 'none'; form-action 'none';"
        let combinedCSS = extraCSS.isEmpty ? baseCSS : (extraCSS + "\n" + baseCSS)

        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style nonce="\(nonce)">
        \(combinedCSS)
        </style>
        </head>
        <body class="\(bodyClass)">
        <main class="lumen-doc-body">
        \(bodyHTML)
        </main>
        <script nonce="\(nonce)">
        (function() {
          const primaryNeedles = \(primaryJSON);
          const secondaryNeedles = \(secondaryJSON);
          const root = document.querySelector('.lumen-doc-body') || document.body;
          const skipTags = new Set(['SCRIPT', 'STYLE', 'MARK', 'NOSCRIPT', 'TEXTAREA']);

          function shouldSkip(node) {
            let el = node.parentElement;
            while (el && el !== root) {
              if (skipTags.has(el.tagName)) return true;
              if (el.classList && (
                el.classList.contains('lumen-sheet-tabs') ||
                el.classList.contains('lumen-remote-badge') ||
                el.classList.contains('lumen-img-fallback') ||
                el.classList.contains('lumen-truncated-note') ||
                el.classList.contains('lumen-row-num') ||
                el.classList.contains('lumen-file-header')
              )) return true;
              el = el.parentElement;
            }
            return false;
          }

          function attachImageFallback(img) {
            function replaceBroken() {
              if (!img || !img.parentNode) return;
              const alt = (img.getAttribute('alt') || '').trim();
              if (alt) {
                const pill = document.createElement('span');
                pill.className = 'lumen-img-fallback';
                pill.textContent = alt;
                img.replaceWith(pill);
              } else {
                img.remove();
              }
            }
            img.addEventListener('error', replaceBroken, { once: true });
            if (img.complete && img.naturalWidth === 0) {
              replaceBroken();
            }
          }

          document.querySelectorAll('img').forEach(attachImageFallback);

          const sheetTabs = Array.from(document.querySelectorAll('.lumen-sheet-tab'));
          const sheetPanels = Array.from(document.querySelectorAll('.lumen-sheet-panel'));
          let activeSheetIndex = sheetPanels.length > 0 ? 0 : -1;

          function currentSheetName() {
            if (activeSheetIndex < 0 || activeSheetIndex >= sheetPanels.length) return null;
            return sheetPanels[activeSheetIndex].getAttribute('data-sheet-name') || null;
          }

          function selectSheet(idx) {
            const numeric = Number(idx);
            if (!Number.isFinite(numeric) || numeric < 0 || numeric >= sheetPanels.length) return;
            activeSheetIndex = numeric;
            sheetTabs.forEach((tab, i) => {
              const on = i === numeric;
              tab.classList.toggle('is-active', on);
              tab.setAttribute('aria-selected', on ? 'true' : 'false');
            });
            sheetPanels.forEach((panel, i) => {
              panel.classList.toggle('is-active', i === numeric);
            });
            if (window.__lumenPreview) {
              window.__lumenPreview.activeSheet = currentSheetName();
              window.__lumenPreview.activeSheetIndex = activeSheetIndex;
            }
            const activeTab = sheetTabs[numeric];
            if (activeTab && typeof activeTab.scrollIntoView === 'function') {
              activeTab.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
            }
          }

          sheetTabs.forEach((tab) => {
            tab.addEventListener('click', () => {
              selectSheet(Number(tab.getAttribute('data-sheet-idx')));
            });
          });

          function collectTextNodes() {
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
            const nodes = [];
            let current;
            while ((current = walker.nextNode())) {
              if (!current.nodeValue || !current.nodeValue.trim()) continue;
              if (shouldSkip(current)) continue;
              nodes.push(current);
            }
            return nodes;
          }

          function findRangesInText(text, needles) {
            const lower = text.toLowerCase();
            const found = [];
            for (let n = 0; n < needles.length; n++) {
              const needle = needles[n];
              const needleLower = needle.toLowerCase();
              if (!needleLower) continue;
              let pos = 0;
              while (pos < lower.length) {
                const idx = lower.indexOf(needleLower, pos);
                if (idx === -1) break;
                const end = idx + needleLower.length;
                let overlaps = false;
                for (let k = 0; k < found.length; k++) {
                  if (idx < found[k].end && end > found[k].start) {
                    overlaps = true;
                    break;
                  }
                }
                if (!overlaps) {
                  found.push({ start: idx, end: end });
                }
                pos = end;
              }
            }
            found.sort((a, b) => a.start - b.start);
            return found;
          }

          function applyHighlights(needles) {
            if (!needles || needles.length === 0) return [];
            const nodes = collectTextNodes();
            const marks = [];
            const maxMarks = 200;
            for (let i = 0; i < nodes.length && marks.length < maxMarks; i++) {
              const node = nodes[i];
              const text = node.nodeValue || '';
              const ranges = findRangesInText(text, needles);
              if (ranges.length === 0) continue;
              const frag = document.createDocumentFragment();
              let cursor = 0;
              for (let r = 0; r < ranges.length && marks.length < maxMarks; r++) {
                const range = ranges[r];
                if (range.start > cursor) {
                  frag.appendChild(document.createTextNode(text.slice(cursor, range.start)));
                }
                const mark = document.createElement('mark');
                mark.className = 'lumen-hit';
                mark.textContent = text.slice(range.start, range.end);
                frag.appendChild(mark);
                marks.push(mark);
                cursor = range.end;
              }
              if (cursor < text.length) {
                frag.appendChild(document.createTextNode(text.slice(cursor)));
              }
              if (node.parentNode) {
                node.parentNode.replaceChild(frag, node);
              }
            }
            return marks;
          }

          let hits = [];
          if (primaryNeedles.length > 0) {
            hits = applyHighlights(primaryNeedles);
          }
          if (hits.length === 0 && secondaryNeedles.length > 0) {
            hits = applyHighlights(secondaryNeedles);
          }

          let activeIndex = hits.length > 0 ? 0 : -1;

          function postState() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lumenPreview) {
              try {
                window.webkit.messageHandlers.lumenPreview.postMessage({
                  matchCount: hits.length,
                  activeIndex: activeIndex,
                  activeSheet: currentSheetName()
                });
              } catch (_) {}
            }
          }

          function focusHit(idx, smooth) {
            if (hits.length === 0) return;
            const wrapped = ((idx % hits.length) + hits.length) % hits.length;
            if (activeIndex >= 0 && activeIndex < hits.length) {
              hits[activeIndex].classList.remove('lumen-hit-active');
            }
            activeIndex = wrapped;
            const target = hits[activeIndex];
            target.classList.add('lumen-hit-active');
            const panel = target.closest('.lumen-sheet-panel');
            if (panel) {
              const sheetIdx = Number(panel.getAttribute('data-sheet-idx'));
              if (Number.isFinite(sheetIdx) && sheetIdx !== activeSheetIndex) {
                selectSheet(sheetIdx);
              }
            }
            target.scrollIntoView({ block: 'center', inline: 'nearest', behavior: smooth ? 'smooth' : 'instant' });
            if (window.__lumenPreview) {
              window.__lumenPreview.activeIndex = activeIndex;
              window.__lumenPreview.activeSheet = currentSheetName();
              window.__lumenPreview.activeSheetIndex = activeSheetIndex;
            }
            postState();
          }

          function scrollToHash(rawHash) {
            const clean = String(rawHash || '').replace(/^#/, '');
            if (!clean) return false;
            let decoded = clean;
            try { decoded = decodeURIComponent(clean); } catch (_) {}
            const target = document.getElementById(decoded) || document.getElementById(clean);
            if (target) {
              target.scrollIntoView({ block: 'start', inline: 'nearest', behavior: 'smooth' });
              return true;
            }
            return false;
          }

          window.__lumenPreview = {
            matchCount: hits.length,
            activeIndex: activeIndex,
            activeSheet: currentSheetName(),
            activeSheetIndex: activeSheetIndex,
            jump: function(delta) {
              if (hits.length === 0) return -1;
              focusHit(activeIndex + Number(delta || 0), true);
              return activeIndex;
            },
            selectSheet: selectSheet,
            scrollToHash: scrollToHash
          };

          if (hits.length > 0) {
            focusHit(0, false);
            window.addEventListener('load', function() {
              document.querySelectorAll('img').forEach((img) => {
                if (img.complete && img.naturalWidth === 0) {
                  img.dispatchEvent(new Event('error'));
                }
              });
              if (activeIndex >= 0 && activeIndex < hits.length) {
                hits[activeIndex].scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
              }
            }, { once: true });
          } else {
            postState();
          }
        })();
        </script>
        </body>
        </html>
        """

        return RichPreviewContent(
            format: format,
            html: html,
            localResources: localResources,
            memoryResources: memoryResources,
            memoryMimeTypes: memoryMimeTypes,
            hasHighlights: hasHighlights,
            prefersPaperCanvas: prefersPaperCanvas
        )
    }

    private static let baseCSS = """
    :root {
      color-scheme: light dark;
      --bg: #ffffff;
      --surface: #ffffff;
      --surface-subtle: #f6f7f9;
      --surface-code: #f4f5f7;
      --text: #1d1d1f;
      --text-secondary: #5c6370;
      --border: rgba(0, 0, 0, 0.11);
      --border-soft: rgba(0, 0, 0, 0.06);
      --accent: #0a66e0;
      --badge-bg: rgba(15, 23, 42, 0.07);
      --badge-border: rgba(15, 23, 42, 0.14);
      --badge-text: #334155;
      --hit-bg: rgba(255, 208, 56, 0.45);
      --hit-text: #1d1d1f;
      --hit-active-bg: #fbbf24;
      --hit-active-text: #111827;
      --hit-active-ring: #d97706;
      --table-cell: #ffffff;
      --table-stripe: #f8f9fb;
      --table-head: #f2f4f7;
      --paper-stage: #f2f3f5;
      --shadow-paper: 0 1px 4px rgba(0, 0, 0, 0.08), 0 6px 20px rgba(0, 0, 0, 0.05);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1c1e22;
        --surface: #25282e;
        --surface-subtle: #262930;
        --surface-code: #15171b;
        --text: #eceef2;
        --text-secondary: #9aa2b1;
        --border: rgba(255, 255, 255, 0.14);
        --border-soft: rgba(255, 255, 255, 0.09);
        --accent: #58a6ff;
        --badge-bg: rgba(255, 255, 255, 0.09);
        --badge-border: rgba(255, 255, 255, 0.16);
        --badge-text: #d6dce6;
        --hit-bg: rgba(251, 191, 36, 0.32);
        --hit-text: #fef3c7;
        --hit-active-bg: #f59e0b;
        --hit-active-text: #111827;
        --hit-active-ring: #fde68a;
        --table-cell: #1c1e22;
        --table-stripe: #22252b;
        --table-head: #282b32;
        --paper-stage: #17181c;
        --shadow-paper: 0 2px 10px rgba(0, 0, 0, 0.42);
      }
    }
    * { box-sizing: border-box; }
    html, body {
      margin: 0;
      padding: 0;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "SF Pro Text", "Helvetica Neue", sans-serif;
      font-size: 13.5px;
      line-height: 1.65;
      -webkit-font-smoothing: antialiased;
      overflow-wrap: break-word;
    }
    .lumen-doc-body { width: 100%; }
    .lumen-markdown {
      max-width: 820px;
      margin: 0 auto;
      padding: 16px 20px 56px;
    }
    .lumen-markdown > :first-child { margin-top: 0; }
    .lumen-markdown h1, .lumen-markdown h2, .lumen-markdown h3,
    .lumen-markdown h4, .lumen-markdown h5, .lumen-markdown h6 {
      margin: 1.3em 0 0.55em;
      font-weight: 650;
      line-height: 1.3;
      letter-spacing: -0.01em;
    }
    .lumen-markdown h1 { font-size: 1.65em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border-soft); }
    .lumen-markdown h2 { font-size: 1.32em; padding-bottom: 0.25em; border-bottom: 1px solid var(--border-soft); }
    .lumen-markdown h3 { font-size: 1.12em; }
    .lumen-markdown h4 { font-size: 1.0em; }
    .lumen-markdown p { margin: 0.72em 0; }
    .lumen-markdown a { color: var(--accent); text-decoration: none; }
    .lumen-markdown a:hover { text-decoration: underline; }
    .lumen-markdown hr { border: 0; border-top: 1px solid var(--border); margin: 1.4em 0; }
    .lumen-markdown img {
      max-width: 100%;
      height: auto;
      border-radius: 8px;
      vertical-align: middle;
    }
    .lumen-markdown [align="center"] { text-align: center; }
    .lumen-markdown [align="right"] { text-align: right; }
    .lumen-markdown [align="left"] { text-align: left; }
    .lumen-markdown ul, .lumen-markdown ol {
      margin: 0.6em 0;
      padding-left: 1.55em;
    }
    .lumen-markdown li { margin: 0.28em 0; }
    .lumen-markdown li > p { margin: 0.3em 0; }
    .lumen-markdown blockquote {
      margin: 0.9em 0;
      padding: 0.55em 0.95em;
      border-left: 3px solid var(--accent);
      background: var(--surface-subtle);
      border-radius: 0 6px 6px 0;
      color: var(--text-secondary);
    }
    .lumen-markdown blockquote > :first-child { margin-top: 0; }
    .lumen-markdown blockquote > :last-child { margin-bottom: 0; }
    .lumen-markdown code {
      font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
      font-size: 0.89em;
      padding: 0.14em 0.38em;
      border-radius: 5px;
      background: var(--surface-code);
      border: 1px solid var(--border-soft);
    }
    .lumen-markdown pre {
      margin: 0.85em 0;
      padding: 11px 13px;
      border-radius: 8px;
      background: var(--surface-code);
      border: 1px solid var(--border-soft);
      overflow-x: auto;
      line-height: 1.52;
    }
    .lumen-markdown pre code {
      padding: 0;
      border: 0;
      background: transparent;
      font-size: 12px;
      display: block;
    }
    .lumen-table-wrap {
      width: 100%;
      overflow-x: auto;
      margin: 0.9em 0;
      border: 1px solid var(--border);
      border-radius: 8px;
    }
    .lumen-markdown table {
      width: 100%;
      border-collapse: collapse;
      font-size: 12.5px;
    }
    .lumen-markdown th, .lumen-markdown td {
      padding: 7px 10px;
      border-bottom: 1px solid var(--border-soft);
      border-right: 1px solid var(--border-soft);
      vertical-align: top;
    }
    .lumen-markdown th:last-child, .lumen-markdown td:last-child { border-right: 0; }
    .lumen-markdown tr:last-child td { border-bottom: 0; }
    .lumen-markdown th {
      background: var(--table-head);
      font-weight: 600;
      text-align: left;
      white-space: nowrap;
    }
    .lumen-markdown tbody tr:nth-child(even) { background: var(--table-stripe); }
    .lumen-align-left { text-align: left; }
    .lumen-align-center { text-align: center; }
    .lumen-align-right { text-align: right; }
    .lumen-task {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 14px;
      height: 14px;
      margin-right: 6px;
      border-radius: 3.5px;
      border: 1px solid var(--border);
      font-size: 10px;
      vertical-align: -1px;
    }
    .lumen-task-done {
      background: var(--accent);
      border-color: var(--accent);
      color: #ffffff;
    }
    .lumen-markdown details {
      margin: 0.85em 0;
      padding: 8px 12px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--surface-subtle);
    }
    .lumen-markdown summary {
      cursor: pointer;
      font-weight: 600;
    }
    .lumen-remote-badge, .lumen-img-fallback {
      display: inline-flex;
      align-items: center;
      padding: 2px 8px;
      margin: 2px 3px;
      border-radius: 999px;
      background: var(--badge-bg);
      border: 1px solid var(--badge-border);
      color: var(--badge-text);
      font-size: 11px;
      font-weight: 500;
      line-height: 1.35;
      vertical-align: middle;
    }
    /* Word / RTF paper canvas */
    .lumen-mode-word {
      background: var(--paper-stage);
    }
    .lumen-paper-stage {
      padding: 14px 16px 56px;
    }
    .lumen-paper-sheet {
      max-width: 780px;
      margin: 0 auto;
      padding: 24px 28px;
      background: #ffffff;
      color: #1d1d1f;
      border-radius: 8px;
      box-shadow: var(--shadow-paper);
      line-height: 1.6;
    }
    .lumen-paper-sheet table {
      border-collapse: collapse;
      max-width: 100%;
    }
    .lumen-paper-sheet td, .lumen-paper-sheet th {
      padding: 4px 8px;
    }
    .lumen-docx-img {
      max-width: 100%;
      height: auto;
      border-radius: 4px;
    }
    /* Spreadsheet & Delimited */
    .lumen-mode-spreadsheet {
      font-size: 12.5px;
      overflow: hidden;
    }
    .lumen-sheet-shell {
      display: flex;
      flex-direction: column;
      height: 100vh;
      overflow: hidden;
      background: var(--bg);
    }
    .lumen-sheet-tabs {
      flex: 0 0 auto;
      display: flex;
      gap: 4px;
      padding: 8px 12px;
      overflow-x: auto;
      background: var(--table-head);
      border-bottom: 1px solid var(--border);
    }
    .lumen-sheet-tab {
      appearance: none;
      border: 1px solid transparent;
      background: transparent;
      color: var(--text-secondary);
      padding: 4px 11px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 500;
      white-space: nowrap;
      cursor: pointer;
    }
    .lumen-sheet-tab:hover {
      background: var(--badge-bg);
      color: var(--text);
    }
    .lumen-sheet-tab.is-active {
      background: var(--surface);
      color: var(--text);
      border-color: var(--border);
      font-weight: 600;
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.06);
    }
    .lumen-sheet-panel {
      display: none;
      flex: 1 1 auto;
      min-height: 0;
      overflow: auto;
      background: var(--bg);
      padding-bottom: 52px;
    }
    .lumen-sheet-panel.is-active {
      display: block;
    }
    .lumen-sheet-empty {
      padding: 24px 16px;
      color: var(--text-secondary);
    }
    .lumen-sheet-wrap {
      width: 100%;
    }
    .lumen-grid-table {
      width: 100%;
      border-collapse: separate;
      border-spacing: 0;
      font-variant-numeric: tabular-nums;
      background: var(--table-cell);
    }
    .lumen-grid-table th, .lumen-grid-table td {
      padding: 6px 10px;
      border-right: 1px solid var(--border-soft);
      border-bottom: 1px solid var(--border-soft);
      white-space: pre-wrap;
      word-break: break-word;
      max-width: 320px;
      vertical-align: top;
      line-height: 1.45;
    }
    @media (max-width: 520px) {
      .lumen-grid-table th, .lumen-grid-table td {
        padding: 5px 8px;
        max-width: 185px;
      }
    }
    .lumen-grid-table thead th {
      position: sticky;
      top: 0;
      z-index: 10;
      background: var(--table-head);
      font-weight: 600;
      text-align: left;
      color: var(--text-secondary);
      border-bottom: 1px solid var(--border);
    }
    .lumen-grid-table .lumen-row-num {
      width: 40px;
      min-width: 40px;
      text-align: right;
      color: var(--text-secondary);
      background: var(--table-head);
      user-select: none;
      -webkit-user-select: none;
    }
    .lumen-grid-table tbody td:not(.lumen-row-num) {
      background: var(--table-cell);
      color: var(--text);
    }
    .lumen-grid-table tbody tr:nth-child(even) td:not(.lumen-row-num) {
      background: var(--table-stripe);
    }
    .lumen-grid-table tr.lumen-first-row td:not(.lumen-row-num) {
      font-weight: 600;
    }
    .lumen-grid-table td.lumen-num {
      text-align: right;
    }
    .lumen-truncated-note {
      padding: 10px 14px;
      font-size: 11.5px;
      color: var(--text-secondary);
    }
    /* Plain Text & Source Code */
    .lumen-file-header {
      position: sticky;
      top: 0;
      z-index: 10;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 7px 14px;
      background: var(--table-head);
      border-bottom: 1px solid var(--border-soft);
      font-size: 11.5px;
      color: var(--text-secondary);
    }
    .lumen-file-name {
      font-weight: 600;
      color: var(--text);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .lumen-code-view {
      margin: 0;
      padding: 10px 0 56px;
      font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
      font-size: 12px;
      line-height: 1.56;
      overflow-x: auto;
      counter-reset: line;
    }
    .lumen-code-line {
      display: block;
      padding: 0 14px 0 0;
      white-space: pre;
    }
    .lumen-code-line::before {
      counter-increment: line;
      content: counter(line);
      display: inline-block;
      width: 44px;
      padding-right: 12px;
      margin-right: 10px;
      text-align: right;
      color: var(--text-secondary);
      opacity: 0.65;
      border-right: 1px solid var(--border-soft);
      user-select: none;
      -webkit-user-select: none;
    }
    .lumen-plain-prose {
      padding: 14px 18px 56px;
      white-space: pre-wrap;
      word-break: break-word;
      font-size: 13px;
      line-height: 1.65;
    }
    /* Match Highlights */
    mark.lumen-hit {
      background: var(--hit-bg);
      color: var(--hit-text);
      padding: 0.04em 0.14em;
      border-radius: 3px;
    }
    mark.lumen-hit.lumen-hit-active {
      background: var(--hit-active-bg);
      color: var(--hit-active-text);
      box-shadow: 0 0 0 1.5px var(--hit-active-ring);
    }
    """

    // MARK: - Utilities

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            for i in 0..<byteCount {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeJSONStringArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let raw = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return raw
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func escapeHTML(_ value: String) -> String {
        var out = String()
        out.reserveCapacity(value.utf8.count)
        for ch in value {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Markdown Parser & Local Resource Registry

private struct MarkdownRenderContext {
    let baseDirectory: URL
    let isPending: (URL) -> Bool
    var localResources: [String: URL] = [:]
    private var urlToToken: [URL: String] = [:]
    private var usedSlugs: [String: Int] = [:]

    init(baseDirectory: URL, isPending: @escaping (URL) -> Bool) {
        self.baseDirectory = baseDirectory
        self.isPending = isPending
    }

    mutating func renderDocument(_ markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return renderBlocks(lines)
    }

    mutating func resolveImageSource(_ raw: String) -> ResolvedImageSource {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") && trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return .invalid }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") {
            return .remote(trimmed)
        }
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:") ||
           lower.hasPrefix("blob:") || lower.hasPrefix("file:") {
            return .invalid
        }
        let pathOnly: String
        if let qIdx = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            pathOnly = String(trimmed[..<qIdx])
        } else {
            pathOnly = trimmed
        }
        let decoded = pathOnly.removingPercentEncoding ?? pathOnly
        guard !decoded.isEmpty, !decoded.contains("\0") else { return .invalid }
        let resolved: URL
        if decoded.hasPrefix("/") {
            resolved = URL(fileURLWithPath: decoded).standardizedFileURL
        } else {
            resolved = URL(fileURLWithPath: decoded, relativeTo: baseDirectory).standardizedFileURL
        }
        // Never materialize cloud files; check pending status with materialization disabled.
        let pending = (try? LocalFile.withMaterializationDisabled { isPending(resolved) }) ?? false
        if pending {
            return .blockedCloud
        }
        if let existing = urlToToken[resolved] {
            return .local("lumen-local://res/\(existing)")
        }
        let token = "r\(urlToToken.count)"
        urlToToken[resolved] = token
        localResources[token] = resolved
        return .local("lumen-local://res/\(token)")
    }

    private mutating func makeHeadingSlug(_ text: String) -> String {
        let plain = stripInlineFormatting(text).lowercased()
        var slug = String()
        for scalar in plain.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "-" || scalar == "_" {
                slug.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "\t" {
                slug.append("-")
            }
        }
        let base = slug.isEmpty ? "section" : slug
        if let count = usedSlugs[base] {
            usedSlugs[base] = count + 1
            return "\(base)-\(count)"
        } else {
            usedSlugs[base] = 1
            return base
        }
    }

    private func stripInlineFormatting(_ s: String) -> String {
        var out = String()
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if inTag { continue }
            if ch == "`" || ch == "*" || ch == "~" { continue }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Block Parser

    private mutating func renderBlocks(_ lines: [String]) -> String {
        var out = String()
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // HTML comment block
            if trimmed.hasPrefix("<!--") {
                while i < lines.count {
                    if lines[i].contains("-->") { i += 1; break }
                    i += 1
                }
                continue
            }

            // Transparent <details> / </details> / <summary>...</summary> wrappers so inner Markdown works
            let lowerTrim = trimmed.lowercased()
            if lowerTrim == "<details>" || lowerTrim == "<details open>" || lowerTrim.hasPrefix("<details ") && lowerTrim.hasSuffix(">") {
                let openAttr = lowerTrim.contains("open") ? " open" : ""
                out += "<details\(openAttr)>\n"
                i += 1
                continue
            }
            if lowerTrim == "</details>" {
                out += "</details>\n"
                i += 1
                continue
            }
            if lowerTrim.hasPrefix("<summary>") && lowerTrim.hasSuffix("</summary>") {
                let innerStart = trimmed.index(trimmed.startIndex, offsetBy: 9)
                let innerEnd = trimmed.index(trimmed.endIndex, offsetBy: -10)
                let inner = String(trimmed[innerStart..<innerEnd])
                out += "<summary>\(renderInline(inner))</summary>\n"
                i += 1
                continue
            }

            // Fenced code block (``` or ~~~)
            if let fence = parseFenceOpen(trimmed) {
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    if isFenceClose(lines[i].trimmingCharacters(in: .whitespaces), marker: fence.marker, minLength: fence.length) {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                let langAttr = fence.lang.isEmpty ? "" : " class=\"language-\(DocumentPreviewRenderer.escapeHTML(fence.lang))\""
                let codeText = DocumentPreviewRenderer.escapeHTML(codeLines.joined(separator: "\n"))
                out += "<pre><code\(langAttr)>\(codeText)</code></pre>\n"
                continue
            }

            // ATX Heading (# .. ######)
            if let heading = parseATXHeading(trimmed) {
                let slug = makeHeadingSlug(heading.text)
                out += "<h\(heading.level) id=\"\(DocumentPreviewRenderer.escapeHTML(slug))\">\(renderInline(heading.text))</h\(heading.level)>\n"
                i += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                out += "<hr>\n"
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let qt = lines[i].trimmingCharacters(in: .whitespaces)
                    if qt.hasPrefix(">") {
                        var rest = String(qt.dropFirst())
                        if rest.hasPrefix(" ") { rest.removeFirst() }
                        quoteLines.append(rest)
                        i += 1
                    } else if qt.isEmpty {
                        break
                    } else {
                        break
                    }
                }
                out += "<blockquote>\(renderBlocks(quoteLines))</blockquote>\n"
                continue
            }

            // GFM Pipe Table
            if i + 1 < lines.count, let alignments = parseTableSeparator(lines[i + 1]) {
                let headerCells = splitTableRow(lines[i])
                if !headerCells.isEmpty {
                    i += 2
                    var bodyRows: [[String]] = []
                    while i < lines.count {
                        let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                        if rowLine.isEmpty || !rowLine.contains("|") { break }
                        bodyRows.append(splitTableRow(lines[i]))
                        i += 1
                    }
                    out += renderTable(headers: headerCells, alignments: alignments, rows: bodyRows)
                    continue
                }
            }

            // Raw HTML block
            if isHTMLBlockStart(trimmed) {
                var htmlLines: [String] = []
                let blockTag = leadingHTMLTagName(trimmed)
                let singleLineClosed = blockTag.map { lowerTrim.contains("</\($0)>") } ?? false
                htmlLines.append(line)
                i += 1
                if !singleLineClosed && blockTag != "hr" && blockTag != "br" && blockTag != "img" {
                    while i < lines.count {
                        let next = lines[i]
                        let nextTrim = next.trimmingCharacters(in: .whitespaces)
                        if nextTrim.isEmpty { break }
                        htmlLines.append(next)
                        i += 1
                        if let blockTag, nextTrim.lowercased().contains("</\(blockTag)>") {
                            break
                        }
                    }
                }
                let rawBlock = htmlLines.joined(separator: "\n")
                out += sanitizeEmbeddedHTML(rawBlock) + "\n"
                continue
            }

            // List (unordered or ordered)
            if parseListMarker(line) != nil {
                let (listHTML, nextIndex) = parseList(lines: lines, start: i)
                out += listHTML
                i = nextIndex
                continue
            }

            // Setext heading (next line === or ---)
            if i + 1 < lines.count {
                let nextTrim = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if nextTrim.count >= 3 && nextTrim.allSatisfy({ $0 == "=" }) {
                    let slug = makeHeadingSlug(trimmed)
                    out += "<h1 id=\"\(DocumentPreviewRenderer.escapeHTML(slug))\">\(renderInline(trimmed))</h1>\n"
                    i += 2
                    continue
                }
                if nextTrim.count >= 3 && nextTrim.allSatisfy({ $0 == "-" }) {
                    let slug = makeHeadingSlug(trimmed)
                    out += "<h2 id=\"\(DocumentPreviewRenderer.escapeHTML(slug))\">\(renderInline(trimmed))</h2>\n"
                    i += 2
                    continue
                }
            }

            // Paragraph
            var paraLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrim = next.trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty ||
                   parseFenceOpen(nextTrim) != nil ||
                   parseATXHeading(nextTrim) != nil ||
                   isHorizontalRule(nextTrim) ||
                   nextTrim.hasPrefix(">") ||
                   isHTMLBlockStart(nextTrim) ||
                   parseListMarker(next) != nil ||
                   (i + 1 < lines.count && parseTableSeparator(lines[i + 1]) != nil) {
                    break
                }
                paraLines.append(nextTrim)
                i += 1
            }
            var joined = String()
            for (idx, pLine) in paraLines.enumerated() {
                if idx > 0 {
                    let prev = paraLines[idx - 1]
                    if prev.hasSuffix("  ") || prev.hasSuffix("\\") {
                        if prev.hasSuffix("\\") && !joined.isEmpty { joined.removeLast() }
                        joined += "<br>"
                    } else {
                        joined += "\n"
                    }
                }
                joined += renderInline(pLine)
            }
            out += "<p>\(joined)</p>\n"
        }
        return out
    }

    private func parseFenceOpen(_ trimmed: String) -> (marker: Character, length: Int, lang: String)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else { break }
        }
        guard count >= 3 else { return nil }
        let rest = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        if first == "`" && rest.contains("`") { return nil }
        let lang = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let safeLang = lang.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+" || $0 == "#") }
        return (first, count, safeLang)
    }

    private func isFenceClose(_ trimmed: String, marker: Character, minLength: Int) -> Bool {
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == marker }) else { return false }
        return trimmed.count >= minLength
    }

    private func parseATXHeading(_ trimmed: String) -> (level: Int, text: String)? {
        var hashes = 0
        for ch in trimmed {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1 && hashes <= 6 else { return nil }
        let after = trimmed.dropFirst(hashes)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            let without = text.dropLast()
            if without.isEmpty || without.last == " " || without.last == "\t" {
                text = without.trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
        }
        return (hashes, text)
    }

    private func isHorizontalRule(_ trimmed: String) -> Bool {
        let stripped = trimmed.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3, let first = stripped.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private enum TableAlign { case none, left, center, right }

    private func parseTableSeparator(_ line: String) -> [TableAlign]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") && trimmed.contains("|") else { return nil }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return nil }
        var aligns: [TableAlign] = []
        for raw in cells {
            let cell = raw.trimmingCharacters(in: .whitespaces)
            guard cell.count >= 1 else { return nil }
            let startsColon = cell.hasPrefix(":")
            let endsColon = cell.hasSuffix(":")
            let coreStart = startsColon ? cell.index(after: cell.startIndex) : cell.startIndex
            let coreEnd = endsColon && cell.count > (startsColon ? 1 : 0) ? cell.index(before: cell.endIndex) : cell.endIndex
            let core = cell[coreStart..<coreEnd]
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            if startsColon && endsColon { aligns.append(.center) }
            else if endsColon { aligns.append(.right) }
            else if startsColon { aligns.append(.left) }
            else { aligns.append(.none) }
        }
        return aligns
    }

    private func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = String()
        var inCode = false
        let chars = Array(trimmed)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" && i + 1 < chars.count && chars[i + 1] == "|" {
                current.append("|")
                i += 2
                continue
            }
            if ch == "`" {
                inCode.toggle()
                current.append(ch)
                i += 1
                continue
            }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
                i += 1
                continue
            }
            current.append(ch)
            i += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private mutating func renderTable(headers: [String], alignments: [TableAlign], rows: [[String]]) -> String {
        let colCount = max(headers.count, alignments.count)
        func alignClass(_ c: Int) -> String {
            guard c < alignments.count else { return "" }
            switch alignments[c] {
            case .none: return ""
            case .left: return " class=\"lumen-align-left\""
            case .center: return " class=\"lumen-align-center\""
            case .right: return " class=\"lumen-align-right\""
            }
        }
        var html = "<div class=\"lumen-table-wrap\"><table><thead><tr>"
        for c in 0..<colCount {
            let cell = c < headers.count ? headers[c] : ""
            html += "<th\(alignClass(c))>\(renderInline(cell))</th>"
        }
        html += "</tr></thead><tbody>"
        for row in rows {
            html += "<tr>"
            for c in 0..<colCount {
                let cell = c < row.count ? row[c] : ""
                html += "<td\(alignClass(c))>\(renderInline(cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table></div>\n"
        return html
    }

    private struct ListMarker {
        let indent: Int
        let ordered: Bool
        let startNumber: Int
        let content: String
        let taskChecked: Bool?
    }

    private func parseListMarker(_ line: String) -> ListMarker? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == " " { indent += 1 }
            else if line[idx] == "\t" { indent += 2 }
            else { break }
            idx = line.index(after: idx)
        }
        let rest = line[idx...]
        guard !rest.isEmpty else { return nil }

        // Unordered: - , * , +
        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            guard let sp = after.first, sp == " " || sp == "\t" else { return nil }
            var body = String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
            var task: Bool? = nil
            if body.hasPrefix("[ ] ") {
                task = false
                body = String(body.dropFirst(4))
            } else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                task = true
                body = String(body.dropFirst(4))
            }
            return ListMarker(indent: indent, ordered: false, startNumber: 1, content: body, taskChecked: task)
        }

        // Ordered: 1. or 1)
        var digits = String()
        var scan = rest.startIndex
        while scan < rest.endIndex && rest[scan].isASCII && rest[scan].isNumber && digits.count < 9 {
            digits.append(rest[scan])
            scan = rest.index(after: scan)
        }
        guard !digits.isEmpty, scan < rest.endIndex, rest[scan] == "." || rest[scan] == ")" else { return nil }
        let afterPunct = rest.index(after: scan)
        guard afterPunct < rest.endIndex, rest[afterPunct] == " " || rest[afterPunct] == "\t" else { return nil }
        let body = String(rest[rest.index(after: afterPunct)...]).trimmingCharacters(in: .whitespaces)
        return ListMarker(indent: indent, ordered: true, startNumber: Int(digits) ?? 1, content: body, taskChecked: nil)
    }

    private mutating func parseList(lines: [String], start: Int) -> (String, Int) {
        guard let first = parseListMarker(lines[start]) else { return ("", start) }
        let baseIndent = first.indent
        let ordered = first.ordered
        let tag = ordered ? "ol" : "ul"
        let startAttr = (ordered && first.startNumber != 1) ? " start=\"\(first.startNumber)\"" : ""
        var html = "<\(tag)\(startAttr)>\n"
        var i = start

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if i + 1 < lines.count,
                   let nextMarker = parseListMarker(lines[i + 1]),
                   nextMarker.indent == baseIndent && nextMarker.ordered == ordered {
                    i += 1
                    continue
                }
                break
            }
            guard let marker = parseListMarker(line),
                  marker.indent == baseIndent && marker.ordered == ordered else {
                break
            }
            i += 1
            var itemLines = [marker.content]
            var nestedHTML = String()

            while i < lines.count {
                let nextLine = lines[i]
                let nextTrim = nextLine.trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty { break }
                if let sub = parseListMarker(nextLine) {
                    if sub.indent > baseIndent {
                        let (subHTML, afterSub) = parseList(lines: lines, start: i)
                        nestedHTML += subHTML
                        i = afterSub
                        continue
                    } else {
                        break
                    }
                }
                let leadingSpaces = nextLine.prefix(while: { $0 == " " || $0 == "\t" }).count
                if leadingSpaces >= baseIndent + 2 {
                    itemLines.append(nextTrim)
                    i += 1
                } else {
                    break
                }
            }

            let taskPrefix: String
            if let checked = marker.taskChecked {
                taskPrefix = checked
                    ? "<span class=\"lumen-task lumen-task-done\">✓</span>"
                    : "<span class=\"lumen-task\"></span>"
            } else {
                taskPrefix = ""
            }
            let itemBody = itemLines.map { renderInline($0) }.joined(separator: " ")
            html += "<li>\(taskPrefix)\(itemBody)\(nestedHTML)</li>\n"
        }
        html += "</\(tag)>\n"
        return (html, i)
    }

    private static let htmlBlockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "picture", "table",
        "ul", "ol", "blockquote", "pre", "hr", "figure", "section", "header",
        "script", "style", "iframe", "object", "embed", "svg",
    ]

    private func leadingHTMLTagName(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("<"), trimmed.count >= 2 else { return nil }
        var idx = trimmed.index(after: trimmed.startIndex)
        if idx < trimmed.endIndex && trimmed[idx] == "/" {
            idx = trimmed.index(after: idx)
        }
        var name = String()
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                name.append(ch.lowercased())
                idx = trimmed.index(after: idx)
            } else {
                break
            }
        }
        return name.isEmpty ? nil : name
    }

    private func isHTMLBlockStart(_ trimmed: String) -> Bool {
        guard let name = leadingHTMLTagName(trimmed) else { return false }
        return Self.htmlBlockTags.contains(name)
    }

    // MARK: Inline Parser

    private mutating func renderInline(_ input: String) -> String {
        let chars = Array(input)
        var out = String()
        out.reserveCapacity(chars.count + 16)
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            // Backslash escape
            if ch == "\\" && i + 1 < chars.count {
                let next = chars[i + 1]
                if "\\`*_{}[]()#+-.!|~<>\"'".contains(next) {
                    out += DocumentPreviewRenderer.escapeHTML(String(next))
                    i += 2
                    continue
                }
            }

            // Inline code span (`...`)
            if ch == "`" {
                var ticks = 0
                while i + ticks < chars.count && chars[i + ticks] == "`" { ticks += 1 }
                if let closeIdx = findClosingTicks(chars: chars, from: i + ticks, count: ticks) {
                    var content = String(chars[(i + ticks)..<closeIdx])
                    if content.count >= 2 && content.hasPrefix(" ") && content.hasSuffix(" ") && !content.allSatisfy({ $0 == " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    out += "<code>\(DocumentPreviewRenderer.escapeHTML(content))</code>"
                    i = closeIdx + ticks
                    continue
                }
                out += String(repeating: "`", count: ticks)
                i += ticks
                continue
            }

            // Image ![alt](url)
            if ch == "!" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let parsed = parseBracketLink(chars: chars, openBracket: i + 1) {
                    out += renderMarkdownImage(alt: parsed.label, rawURL: parsed.url, title: parsed.title)
                    i = parsed.nextIndex
                    continue
                }
            }

            // Link [label](url)
            if ch == "[" {
                if let parsed = parseBracketLink(chars: chars, openBracket: i) {
                    let innerHTML = renderInline(parsed.label)
                    if let safeHref = HTMLSanitizer.sanitizeHref(parsed.url) {
                        let titleAttr = parsed.title.isEmpty ? "" : " title=\"\(DocumentPreviewRenderer.escapeHTML(parsed.title))\""
                        out += "<a href=\"\(DocumentPreviewRenderer.escapeHTML(safeHref))\"\(titleAttr)>\(innerHTML)</a>"
                    } else {
                        out += innerHTML
                    }
                    i = parsed.nextIndex
                    continue
                }
            }

            // Inline HTML or Autolink <...>
            if ch == "<" {
                // Autolink <https://...>
                if let close = chars[i...].firstIndex(of: ">") {
                    let inside = String(chars[(i + 1)..<close])
                    let lowerInside = inside.lowercased()
                    if (lowerInside.hasPrefix("https://") || lowerInside.hasPrefix("http://")) && !inside.contains(" ") {
                        let escaped = DocumentPreviewRenderer.escapeHTML(inside)
                        out += "<a href=\"\(escaped)\">\(escaped)</a>"
                        i = close + 1
                        continue
                    }
                    // Strip dangerous inline container up to closing tag
                    if let tagName = leadingHTMLTagName(String(chars[i...close])),
                       HTMLSanitizer.droppedContainerTags.contains(tagName) {
                        let remainder = String(chars[i...])
                        let closeNeedle = "</\(tagName)>"
                        if let endRange = remainder.range(of: closeNeedle, options: .caseInsensitive) {
                            let consumed = remainder[..<endRange.upperBound].count
                            i += consumed
                        } else {
                            i = close + 1
                        }
                        continue
                    }
                    // Safe inline HTML tag
                    if isLikelyHTMLTag(inside) {
                        let snippet = String(chars[i...close])
                        out += sanitizeEmbeddedHTML(snippet)
                        i = close + 1
                        continue
                    }
                }
                out += "&lt;"
                i += 1
                continue
            }

            // Strikethrough ~~...~~
            if ch == "~" && i + 1 < chars.count && chars[i + 1] == "~" {
                if let end = findClosingDelimiter(chars: chars, from: i + 2, delimiter: "~", count: 2) {
                    let inner = String(chars[(i + 2)..<end])
                    out += "<del>\(renderInline(inner))</del>"
                    i = end + 2
                    continue
                }
            }

            // Bold / Italic (* or _)
            if ch == "*" || ch == "_" {
                let prevIsWord = i > 0 && isWordChar(chars[i - 1])
                if ch == "_" && prevIsWord {
                    out.append(ch)
                    i += 1
                    continue
                }
                if i + 2 < chars.count && chars[i + 1] == ch && chars[i + 2] == ch,
                   let end = findClosingDelimiter(chars: chars, from: i + 3, delimiter: ch, count: 3) {
                    let inner = String(chars[(i + 3)..<end])
                    out += "<strong><em>\(renderInline(inner))</em></strong>"
                    i = end + 3
                    continue
                }
                if i + 1 < chars.count && chars[i + 1] == ch,
                   let end = findClosingDelimiter(chars: chars, from: i + 2, delimiter: ch, count: 2) {
                    let inner = String(chars[(i + 2)..<end])
                    out += "<strong>\(renderInline(inner))</strong>"
                    i = end + 2
                    continue
                }
                if let end = findClosingDelimiter(chars: chars, from: i + 1, delimiter: ch, count: 1) {
                    let nextAfterIsWord = (end + 1 < chars.count) && isWordChar(chars[end + 1])
                    if !(ch == "_" && nextAfterIsWord) {
                        let inner = String(chars[(i + 1)..<end])
                        out += "<em>\(renderInline(inner))</em>"
                        i = end + 1
                        continue
                    }
                }
            }

            switch ch {
            case "&": out += "&amp;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
            i += 1
        }
        return out
    }

    private func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    private func isLikelyHTMLTag(_ inside: String) -> Bool {
        guard let first = inside.first else { return false }
        if first == "/" {
            guard inside.count >= 2 else { return false }
            let second = inside[inside.index(after: inside.startIndex)]
            return second.isASCII && second.isLetter
        }
        if first == "!" { return true }
        return first.isASCII && first.isLetter
    }

    private func findClosingTicks(chars: [Character], from start: Int, count: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                var run = 0
                while i + run < chars.count && chars[i + run] == "`" { run += 1 }
                if run == count { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    private func findClosingDelimiter(chars: [Character], from start: Int, delimiter: Character, count: Int) -> Int? {
        guard start < chars.count, !chars[start].isWhitespace else { return nil }
        var i = start
        while i + count <= chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "`" {
                var ticks = 0
                while i + ticks < chars.count && chars[i + ticks] == "`" { ticks += 1 }
                if let close = findClosingTicks(chars: chars, from: i + ticks, count: ticks) {
                    i = close + ticks
                    continue
                }
                i += ticks
                continue
            }
            var matched = true
            for k in 0..<count where chars[i + k] != delimiter {
                matched = false
                break
            }
            if matched && i > start && !chars[i - 1].isWhitespace {
                return i
            }
            i += 1
        }
        return nil
    }

    private func parseBracketLink(chars: [Character], openBracket: Int) -> (label: String, url: String, title: String, nextIndex: Int)? {
        var depth = 0
        var i = openBracket
        var closeBracket: Int? = nil
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "[" { depth += 1 }
            else if chars[i] == "]" {
                depth -= 1
                if depth == 0 { closeBracket = i; break }
            }
            i += 1
        }
        guard let cb = closeBracket, cb + 1 < chars.count, chars[cb + 1] == "(" else { return nil }
        var parenDepth = 0
        var j = cb + 1
        var closeParen: Int? = nil
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "(" { parenDepth += 1 }
            else if chars[j] == ")" {
                parenDepth -= 1
                if parenDepth == 0 { closeParen = j; break }
            }
            j += 1
        }
        guard let cp = closeParen else { return nil }
        let label = String(chars[(openBracket + 1)..<cb])
        let destRaw = String(chars[(cb + 2)..<cp]).trimmingCharacters(in: .whitespacesAndNewlines)
        let (url, title) = splitLinkDestinationAndTitle(destRaw)
        return (label, url, title, cp + 1)
    }

    private func splitLinkDestinationAndTitle(_ raw: String) -> (String, String) {
        if raw.hasPrefix("<"), let gt = raw.firstIndex(of: ">") {
            let url = String(raw[raw.index(after: raw.startIndex)..<gt])
            let rest = String(raw[raw.index(after: gt)...]).trimmingCharacters(in: .whitespaces)
            let title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (url, title)
        }
        if let space = raw.firstIndex(where: \.isWhitespace) {
            let url = String(raw[..<space])
            let rest = String(raw[space...]).trimmingCharacters(in: .whitespaces)
            let title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (url, title)
        }
        return (raw, "")
    }

    private mutating func renderMarkdownImage(alt: String, rawURL: String, title: String) -> String {
        switch resolveImageSource(rawURL) {
        case .local(let localURL):
            let titleAttr = title.isEmpty ? "" : " title=\"\(DocumentPreviewRenderer.escapeHTML(title))\""
            return "<img src=\"\(DocumentPreviewRenderer.escapeHTML(localURL))\" alt=\"\(DocumentPreviewRenderer.escapeHTML(alt))\"\(titleAttr)>"
        case .remote(let remoteURL):
            let label = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = label.isEmpty ? (URL(string: remoteURL)?.host ?? "Image") : label
            return "<span class=\"lumen-remote-badge\">\(DocumentPreviewRenderer.escapeHTML(fallback))</span>"
        case .blockedCloud:
            let label = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = label.isEmpty ? "Cloud image" : label
            return "<span class=\"lumen-img-fallback\">\(DocumentPreviewRenderer.escapeHTML(fallback))</span>"
        case .invalid:
            return alt.isEmpty ? "" : "<span class=\"lumen-img-fallback\">\(DocumentPreviewRenderer.escapeHTML(alt))</span>"
        }
    }

    private mutating func sanitizeEmbeddedHTML(_ html: String) -> String {
        HTMLSanitizer.sanitize(html, allowClasses: false) { src, _ in
            resolveImageSource(src)
        }
    }
}

private enum ResolvedImageSource {
    case local(String)
    case remote(String)
    case blockedCloud
    case invalid
}

// MARK: - Strict Allowlist HTML Sanitizer

private enum HTMLSanitizer {
    static let droppedContainerTags: Set<String> = [
        "script", "style", "iframe", "frame", "frameset", "object", "embed",
        "applet", "svg", "math", "noscript", "template", "form", "input",
        "button", "textarea", "select", "option", "meta", "link", "base",
        "title", "head",
    ]

    private static let allowedTags: Set<String> = [
        "p", "div", "span", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6",
        "strong", "b", "em", "i", "u", "s", "del", "ins", "sub", "sup", "small",
        "code", "pre", "kbd", "blockquote", "ul", "ol", "li", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "colgroup", "col",
        "caption", "details", "summary", "picture", "source", "img", "a",
        "figure", "figcaption", "mark", "abbr", "q", "cite", "font",
    ]

    private static let voidTags: Set<String> = ["br", "hr", "img", "source", "col"]

    static func sanitize(
        _ html: String,
        allowClasses: Bool,
        resolveImage: (String, String) -> ResolvedImageSource?
    ) -> String {
        let chars = Array(html)
        var out = String()
        out.reserveCapacity(chars.count)
        var i = 0

        while i < chars.count {
            if chars[i] != "<" {
                out.append(chars[i])
                i += 1
                continue
            }

            // HTML comment <!-- ... -->
            if i + 3 < chars.count && chars[i + 1] == "!" && chars[i + 2] == "-" && chars[i + 3] == "-" {
                if let end = findSequence(chars: chars, from: i + 4, needle: ["-", "-", ">"]) {
                    i = end + 3
                } else {
                    break
                }
                continue
            }

            // Find closing '>' outside quotes
            guard let gt = findTagEnd(chars: chars, from: i + 1) else {
                out += "&lt;"
                i += 1
                continue
            }

            let rawInside = String(chars[(i + 1)..<gt]).trimmingCharacters(in: .whitespacesAndNewlines)
            i = gt + 1

            guard !rawInside.isEmpty else { continue }
            if rawInside.hasPrefix("!") || rawInside.hasPrefix("?") { continue }

            let isClosing = rawInside.hasPrefix("/")
            let body = isClosing ? String(rawInside.dropFirst()).trimmingCharacters(in: .whitespaces) : rawInside
            let (tagName, attrSlice) = splitTagNameAndAttrs(body)
            let lowerTag = tagName.lowercased()
            guard !lowerTag.isEmpty else { continue }

            if droppedContainerTags.contains(lowerTag) {
                if !isClosing && !rawInside.hasSuffix("/") {
                    // Skip inner content until matching closing tag
                    if let closePos = findClosingTag(chars: chars, from: i, tagName: lowerTag) {
                        i = closePos
                    }
                }
                continue
            }

            guard allowedTags.contains(lowerTag) else { continue }

            if isClosing {
                if !voidTags.contains(lowerTag) {
                    out += "</\(lowerTag)>"
                }
                continue
            }

            let attrs = parseAttributes(attrSlice)

            // Special handling for <img>
            if lowerTag == "img" {
                let rawSrc = attrs["src"] ?? ""
                let alt = attrs["alt"] ?? ""
                guard let resolved = resolveImage(rawSrc, alt) else { continue }
                switch resolved {
                case .local(let safeURL):
                    var rebuilt = "<img src=\"\(DocumentPreviewRenderer.escapeHTML(safeURL))\""
                    if !alt.isEmpty {
                        rebuilt += " alt=\"\(DocumentPreviewRenderer.escapeHTML(alt))\""
                    }
                    if let w = sanitizeDimension(attrs["width"]) { rebuilt += " width=\"\(w)\"" }
                    if let h = sanitizeDimension(attrs["height"]) { rebuilt += " height=\"\(h)\"" }
                    if let title = attrs["title"], !title.isEmpty {
                        rebuilt += " title=\"\(DocumentPreviewRenderer.escapeHTML(title))\""
                    }
                    rebuilt += ">"
                    out += rebuilt
                case .remote(let remoteURL):
                    let trimmedAlt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = trimmedAlt.isEmpty ? (URL(string: remoteURL)?.host ?? "Image") : trimmedAlt
                    out += "<span class=\"lumen-remote-badge\">\(DocumentPreviewRenderer.escapeHTML(label))</span>"
                case .blockedCloud:
                    let trimmedAlt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = trimmedAlt.isEmpty ? "Cloud image" : trimmedAlt
                    out += "<span class=\"lumen-img-fallback\">\(DocumentPreviewRenderer.escapeHTML(label))</span>"
                case .invalid:
                    break
                }
                continue
            }

            // Special handling for <source> inside <picture>
            if lowerTag == "source" {
                guard let rawSrcset = attrs["srcset"], !rawSrcset.isEmpty else { continue }
                var safeEntries: [String] = []
                var hasRemoteOrInvalid = false
                for rawEntry in rawSrcset.split(separator: ",") {
                    let parts = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
                    guard let first = parts.first else { continue }
                    let candidateURL = String(first)
                    if let resolved = resolveImage(candidateURL, ""), case .local(let safeURL) = resolved {
                        if parts.count >= 2 {
                            let descriptor = String(parts[1])
                            if isSafeSrcsetDescriptor(descriptor) {
                                safeEntries.append("\(safeURL) \(descriptor)")
                            } else {
                                safeEntries.append(safeURL)
                            }
                        } else {
                            safeEntries.append(safeURL)
                        }
                    } else {
                        hasRemoteOrInvalid = true
                    }
                }
                guard !safeEntries.isEmpty && !hasRemoteOrInvalid else { continue }
                var rebuilt = "<source srcset=\"\(DocumentPreviewRenderer.escapeHTML(safeEntries.joined(separator: ", ")))\""
                if let media = attrs["media"], isSafeMediaQuery(media) {
                    rebuilt += " media=\"\(DocumentPreviewRenderer.escapeHTML(media))\""
                }
                if let mime = attrs["type"], isSafeImageMime(mime) {
                    rebuilt += " type=\"\(DocumentPreviewRenderer.escapeHTML(mime))\""
                }
                rebuilt += ">"
                out += rebuilt
                continue
            }

            // Rebuild allowed tag with allowlisted attributes only
            var rebuilt = "<\(lowerTag)"
            if let align = attrs["align"]?.lowercased(), ["left", "center", "right", "justify"].contains(align) {
                rebuilt += " align=\"\(align)\""
            }
            if let dir = attrs["dir"]?.lowercased(), ["ltr", "rtl", "auto"].contains(dir) {
                rebuilt += " dir=\"\(dir)\""
            }
            if let title = attrs["title"], !title.isEmpty {
                rebuilt += " title=\"\(DocumentPreviewRenderer.escapeHTML(title))\""
            }
            if let id = attrs["id"], isSafeIdentifier(id) {
                rebuilt += " id=\"\(DocumentPreviewRenderer.escapeHTML(id))\""
            }
            if allowClasses, let cls = attrs["class"], isSafeClassList(cls) {
                rebuilt += " class=\"\(DocumentPreviewRenderer.escapeHTML(cls))\""
            }
            if lowerTag == "a", let rawHref = attrs["href"], let safeHref = sanitizeHref(rawHref) {
                rebuilt += " href=\"\(DocumentPreviewRenderer.escapeHTML(safeHref))\""
            }
            if lowerTag == "td" || lowerTag == "th" {
                if let cs = attrs["colspan"], let n = Int(cs), n > 0, n <= 100 {
                    rebuilt += " colspan=\"\(n)\""
                }
                if let rs = attrs["rowspan"], let n = Int(rs), n > 0, n <= 100 {
                    rebuilt += " rowspan=\"\(n)\""
                }
                if let valign = attrs["valign"]?.lowercased(), ["top", "middle", "bottom", "baseline"].contains(valign) {
                    rebuilt += " valign=\"\(valign)\""
                }
            }
            if lowerTag == "ol", let start = attrs["start"], let n = Int(start) {
                rebuilt += " start=\"\(n)\""
            }
            if lowerTag == "details", attrs.keys.contains("open") {
                rebuilt += " open"
            }
            rebuilt += ">"
            out += rebuilt
        }

        return out
    }

    static func sanitizeHref(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:") ||
           lower.hasPrefix("file:") || lower.hasPrefix("blob:") {
            return nil
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || trimmed.hasPrefix("#") {
            return trimmed
        }
        // Relative href without dangerous colon scheme
        if !trimmed.contains(":") {
            return trimmed
        }
        return nil
    }

    private static func findSequence(chars: [Character], from start: Int, needle: [Character]) -> Int? {
        guard start + needle.count <= chars.count else { return nil }
        var i = start
        while i + needle.count <= chars.count {
            var ok = true
            for k in 0..<needle.count where chars[i + k] != needle[k] {
                ok = false
                break
            }
            if ok { return i }
            i += 1
        }
        return nil
    }

    private static func findTagEnd(chars: [Character], from start: Int) -> Int? {
        var i = start
        var quote: Character? = nil
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else {
                if ch == "\"" || ch == "'" { quote = ch }
                else if ch == ">" { return i }
            }
            i += 1
        }
        return nil
    }

    private static func findClosingTag(chars: [Character], from start: Int, tagName: String) -> Int? {
        let target = Array("</\(tagName)")
        var i = start
        while i + target.count < chars.count {
            if chars[i] == "<" && chars[i + 1] == "/" {
                var matched = true
                for k in 2..<target.count {
                    if String(chars[i + k]).lowercased() != String(target[k]) {
                        matched = false
                        break
                    }
                }
                if matched {
                    var j = i + target.count
                    while j < chars.count && chars[j] != ">" { j += 1 }
                    return j < chars.count ? j + 1 : chars.count
                }
            }
            i += 1
        }
        return chars.count
    }

    private static func splitTagNameAndAttrs(_ raw: String) -> (String, String) {
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let ch = raw[idx]
            if ch.isWhitespace || ch == "/" { break }
            idx = raw.index(after: idx)
        }
        return (String(raw[..<idx]), String(raw[idx...]))
    }

    private static func parseAttributes(_ slice: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(slice)
        var i = 0
        while i < chars.count {
            while i < chars.count && (chars[i].isWhitespace || chars[i] == "/") { i += 1 }
            if i >= chars.count { break }
            var name = String()
            while i < chars.count && !chars[i].isWhitespace && chars[i] != "=" && chars[i] != "/" {
                name.append(chars[i])
                i += 1
            }
            let lowerName = name.lowercased()
            if lowerName.isEmpty { break }
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count && chars[i] == "=" {
                i += 1
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                if i < chars.count && (chars[i] == "\"" || chars[i] == "'") {
                    let q = chars[i]
                    i += 1
                    let vStart = i
                    while i < chars.count && chars[i] != q { i += 1 }
                    value = decodeBasicEntities(String(chars[vStart..<i]))
                    if i < chars.count && chars[i] == q { i += 1 }
                } else {
                    let vStart = i
                    while i < chars.count && !chars[i].isWhitespace { i += 1 }
                    value = decodeBasicEntities(String(chars[vStart..<i]))
                }
            }
            if !lowerName.hasPrefix("on") {
                result[lowerName] = value
            }
        }
        return result
    }

    private static func decodeBasicEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func sanitizeDimension(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 10 else { return nil }
        if trimmed.hasSuffix("%") {
            let num = trimmed.dropLast()
            guard !num.isEmpty, num.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(num), v > 0, v <= 100 else { return nil }
            return "\(v)%"
        }
        let stripped = trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed
        guard !stripped.isEmpty, stripped.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(stripped), v > 0, v <= 4096 else { return nil }
        return "\(v)"
    }

    private static func isSafeSrcsetDescriptor(_ descriptor: String) -> Bool {
        guard descriptor.count >= 2 && descriptor.count <= 8 else { return false }
        let suffix = descriptor.last!
        guard suffix == "x" || suffix == "w" else { return false }
        let body = descriptor.dropLast()
        return !body.isEmpty && body.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
    }

    private static func isSafeMediaQuery(_ media: String) -> Bool {
        guard !media.isEmpty && media.count <= 128 else { return false }
        return media.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) ||
                   scalar == " " || scalar == "(" || scalar == ")" || scalar == ":" || scalar == "-" ||
                   scalar == "." || scalar == "," || scalar == "/"
        }
    }

    private static func isSafeImageMime(_ mime: String) -> Bool {
        let lower = mime.lowercased()
        guard lower.hasPrefix("image/"), lower.count <= 40 else { return false }
        return lower.dropFirst(6).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" || $0 == ".") }
    }

    private static func isSafeIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty && id.count <= 128 else { return false }
        return !id.contains(where: { $0 == "\"" || $0 == "'" || $0 == "<" || $0 == ">" || $0.isWhitespace })
    }

    private static func isSafeClassList(_ cls: String) -> Bool {
        guard !cls.isEmpty && cls.count <= 128 else { return false }
        return cls.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" || $0 == " " }
    }
}
#endif
