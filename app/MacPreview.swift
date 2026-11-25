#if os(macOS)
import AppKit
import Darwin
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct MacPreviewRenderer: Sendable {
    /// Give this a *small, positively vetted* local scope, not $HOME, / or
    /// any cloud file-provider root. Components inside it are opened no-follow.
    private let roots: [[String]]
    private static let maxInput = 24 * 1024 * 1024
    private static let maxOutput = 4 * 1024 * 1024
    private static let maxPixels = 64_000_000
    // The ABI flag for a dataless vnode (Apple BSD sys/stat.h).
    private static let dataless: UInt32 = 0x4000_0000

    public init(knownLocalRoots: [URL]) {
        self.roots = knownLocalRoots.compactMap(Self.canonicalDirectory).map(\.pathComponents).filter { $0.count > 1 }
    }

    static func canonicalDirectory(_ url: URL) -> URL? {
        guard url.isFileURL, let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    public func load(_ item: PreviewSelection) async throws -> PreviewDocument {
        let decode = Task.detached(priority: .utility) { try render(item) }
        return try await withTaskCancellationHandler(operation: {
            try await decode.value
        }, onCancel: { decode.cancel() })
    }

    private func render(_ item: PreviewSelection) throws -> PreviewDocument {
        try Task.checkCancellation()
        guard item.residency == .provenLocal, item.url.isFileURL,
              item.url.host == nil || item.url.host == "" || item.url.host == "localhost" else {
            throw PreviewFailure.notLocal
        }
        let file = item.url
        // Prevent entering provider-managed roots by default, even if integration
        // accidentally supplies a broad root. Canonical symlinks inside FILE scope
        // aren't resolved; the descriptor walk rejects them.
        let parts = file.pathComponents
        guard roots.contains(where: { parts.count > $0.count && parts.starts(with: $0) }),
              !parts.contains("."), !parts.contains(".."),
              !parts.contains("CloudStorage"), !parts.contains("Mobile Documents"),
              !parts.contains(where: { $0.lowercased().hasPrefix("onedrive") }),
              !parts.contains(where: { $0.lowercased().hasSuffix(".icloud") }) else {
            throw PreviewFailure.notLocal
        }
        return try withResidentFile(file) { fd, count in
            switch item.kind {
            case .excerpt:
                guard let evidence = item.evidence, !evidence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PreviewFailure.noExcerpt
                }
                // Text previews only reuse the selected result's existing index evidence.
                return PreviewDocument(evidence: evidence)
            case .image:
                let data = try read(fd, expected: count)
                return PreviewDocument(visual: .image(try thumbnail(data)), evidence: item.evidence)
            case .pdf(let page):
                let data = try read(fd, expected: count)
                return try pdf(data, matchPage: page, evidence: item.evidence)
            }
        }
    }

    private func withResidentFile<T>(_ file: URL, _ work: (Int32, Int64) throws -> T) throws -> T {
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw PreviewFailure.notLocal }
        defer { _ = setiopolicy_np(policy, scope, prior) }
        guard let metadata = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]),
              metadata.isUbiquitousItem != true, metadata.volumeIsLocal == true else {
            throw PreviewFailure.notLocal
        }
        // Darwin returns stat flags for the opened descriptor too, so races with
        // a symlink replacing a directory won't redirect this data read.
        var fd = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard fd >= 0 else { throw PreviewFailure.missing }
        defer { _ = Darwin.close(fd) }
        let components = file.pathComponents.dropFirst()
        for (i, component) in components.enumerated() {
            try Task.checkCancellation()
            let last = i == components.count - 1
            let opts = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (last ? 0 : O_DIRECTORY)
            let child = component.withCString { Darwin.openat(fd, $0, opts) }
            guard child >= 0 else { throw PreviewFailure.missing }
            _ = Darwin.close(fd)
            fd = child
        }
        var info = stat()
        var volume = statfs()
        guard Darwin.fstat(fd, &info) == 0, Darwin.fstatfs(fd, &volume) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw PreviewFailure.missing }
        guard volume.f_flags & UInt32(MNT_LOCAL) != 0,
              info.st_flags & Self.dataless == 0 else { throw PreviewFailure.notLocal }
        return try work(fd, info.st_size)
    }

    private func read(_ fd: Int32, expected: Int64) throws -> Data {
        guard expected > 0 else { throw PreviewFailure.invalidContent }
        guard expected <= Int64(Self.maxInput) else { throw PreviewFailure.overLimit }
        var result = Data()
        result.reserveCapacity(Int(expected))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        // Read at most the original known length plus one byte, never follow growth.
        while true {
            try Task.checkCancellation()
            let requested = min(chunk.count, Int(expected) - result.count + 1)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, requested) }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PreviewFailure.invalidContent }
            guard result.count + count <= Int(expected) else { throw PreviewFailure.invalidContent }
            result.append(contentsOf: chunk.prefix(count))
        }
        guard result.count == Int(expected) else { throw PreviewFailure.invalidContent }
        return result
    }

    private func thumbnail(_ original: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
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

    private func pdf(_ original: Data, matchPage: Int?, evidence: PreviewEvidence?) throws -> PreviewDocument {
        guard let document = PDFDocument(data: original), !document.isLocked else {
            throw PreviewFailure.invalidContent
        }
        let number = matchPage ?? 1
        guard number > 0, number <= document.pageCount,
              let page = document.page(at: number - 1) else { throw PreviewFailure.unavailablePage }

        let box = page.bounds(for: .cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            throw PreviewFailure.invalidContent
        }
        let scale = min(960 / box.width, 960 / box.height)
        let size = CGSize(width: max(1, floor(box.width * scale)), height: max(1, floor(box.height * scale)))
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
            throw PreviewFailure.overLimit
        }
        try Task.checkCancellation()
        return Data(referencing: data)
    }
}
#endif
