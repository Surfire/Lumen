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
            case .excerpt:
                guard let evidence = item.evidence, !evidence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PreviewFailure.noExcerpt
                }
                // Text previews only reuse the selected result's existing index evidence.
                return PreviewDocument(evidence: evidence)
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
        guard let bitmap = ctx.makeImage() else { throw PreviewFailure.invalidContent }
        let validEvidence = evidence.flatMap { $0.page == nil || $0.page == number ? $0 : nil }
        return PreviewDocument(visual: .pdf(try png(bitmap), displayedPage: number, isMatchPage: matchPage != nil),
                               evidence: validEvidence)
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
}
#endif
