import AppKit
import Carbon.HIToolbox
import Darwin
import ImageIO
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

enum FileAction: Equatable {
    case open, reveal, preview, copyName, copyPath, copyFile, openInTerminal, openWith(URL), searchInFolder

    var allowsCloudReference: Bool { true }
}

enum LocalFile {
    struct Placeholder: Error {}

    static func withMaterializationDisabled<T>(_ work: () throws -> T) throws -> T {
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw PreviewFailure.notLocal }
        defer { _ = setiopolicy_np(policy, scope, prior) }
        return try work()
    }

    static func isUbiquitousPlaceholder(_ url: URL) -> Bool {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        return values?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    static func withResidentFile<T>(_ url: URL, expectedStamp: String? = nil,
                                    isPending: (URL) -> Bool = isUbiquitousPlaceholder,
                                    _ work: () throws -> T) throws -> T {
        try withMaterializationDisabled {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
                throw PreviewFailure.notLocal
            }
            let path = url.path
            guard let info = SearchHit.statOnDisk(at: path, kind: "file", permitsDatalessLeaf: true) else {
                throw PreviewFailure.missing
            }
            if info.st_flags & UInt32(SF_DATALESS) != 0 || isPending(url) {
                guard try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
                    throw PreviewFailure.notLocal
                }
                throw Placeholder()
            }
            let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw PreviewFailure.missing }
            defer { _ = Darwin.close(fd) }
            var opened = stat()
            var volume = statfs()
            // Kernel-anchored boundary: local volumes, or a mounted network filesystem type the kernel reports.
            guard fstatfs(fd, &volume) == 0,
                  volume.f_flags & UInt32(MNT_LOCAL) != 0 || Self.isAllowedNetworkFilesystem(Self.fsTypeName(of: volume)) else {
                throw PreviewFailure.notLocal
            }
            guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
                throw PreviewFailure.missing
            }
            if opened.st_flags & UInt32(SF_DATALESS) != 0 {
                throw Placeholder()
            }
            return try work()
        }
    }

    static func isAllowedNetworkFilesystem(_ fsTypeName: String) -> Bool {
        ["smbfs", "nfs", "afpfs", "webdav"].contains(fsTypeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// `statfs.f_fstypename` is a fixed C char tuple; read it up to the first NUL.
    static func fsTypeName(of volume: statfs) -> String {
        withUnsafeBytes(of: volume.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func dragURL(for hit: SearchHit, resourceValues: (URL, [URLResourceKey]) throws -> [URLResourceKey: Any] = {
        try ($0 as NSURL).resourceValues(forKeys: $1)
    }) -> URL? {
        guard hit.isResident,
              SearchHit.existsOnDisk(at: hit.path, kind: hit.kind, permitsDatalessLeaf: false) else { return nil }
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return nil }
        defer { _ = setiopolicy_np(policy, scope, prior) }
        // The live path check rejects dataless leaves. Ubiquity only
        // signals iCloud membership, not whether the item is locally resident.
        let url = URL(fileURLWithPath: hit.path, isDirectory: hit.kind == "directory")
        guard let values = try? resourceValues(url, [.volumeIsLocalKey]),
              values[.volumeIsLocalKey] as? Bool == true else { return nil }
        return url
    }
}

enum LauncherFileTools {
    struct OpenWithApp: Equatable, Identifiable, Sendable {
        let name: String
        let url: URL
        let bundleID: String?
        var id: String { url.path }
    }

    static let terminalBundleIdentifiers = [
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "org.alacritty",
        "com.apple.Terminal",
    ]

    static func isResidentForFileCopy(_ url: URL) -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            return false
        }
        let path = url.path
        let result = try? LocalFile.withMaterializationDisabled { () -> Bool in
            guard let info = SearchHit.statOnDisk(at: path, kind: "file", permitsDatalessLeaf: false)
                ?? SearchHit.statOnDisk(at: path, kind: "directory", permitsDatalessLeaf: false),
                info.st_flags & UInt32(SF_DATALESS) == 0 else {
                return false
            }
            return !LocalFile.isUbiquitousPlaceholder(url)
        }
        return result == true
    }

    static func preferredTerminalApplicationURL() -> URL? {
        for bundleID in terminalBundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        return nil
    }

    static func targetDirectoryForTerminal(path: String, isDirectory: Bool) -> URL {
        if isDirectory {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: false).deletingLastPathComponent()
    }

    static func openWithApplications(for url: URL, limit: Int = 12) -> [OpenWithApp] {
        guard limit > 0, url.isFileURL else { return [] }
        let candidates: [URL] = (try? LocalFile.withMaterializationDisabled {
            let workspace = NSWorkspace.shared
            let defaultApp = workspace.urlForApplication(toOpen: url)
            let allApps = workspace.urlsForApplications(toOpen: url)
            return (defaultApp.map { [$0] } ?? []) + allApps
        }) ?? []

        var seenPaths = Set<String>()
        var apps: [OpenWithApp] = []
        apps.reserveCapacity(min(limit, candidates.count))

        for candidate in candidates {
            let cleanURL = candidate.standardizedFileURL
            let bundlePath = cleanURL.path
            guard !bundlePath.isEmpty, seenPaths.insert(bundlePath).inserted else { continue }
            let bundle = Bundle(url: cleanURL)
            let bundleID = bundle?.bundleIdentifier
            let localizedName = try? cleanURL.resourceValues(forKeys: [.localizedNameKey]).localizedName
            let rawName = localizedName
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? cleanURL.deletingPathExtension().lastPathComponent
            let strippedName = rawName.lowercased().hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
            let trimmedName = strippedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmedName.isEmpty ? cleanURL.deletingPathExtension().lastPathComponent : trimmedName
            apps.append(OpenWithApp(name: name, url: cleanURL, bundleID: bundleID))
            if apps.count >= limit { break }
        }
        return apps
    }
}

@MainActor
final class LocalPreviewPanel: NSPanel {
    private let preview: QLPreviewView?
    private let pdf: PDFView?
    private let imageView: NSImageView?
    private(set) var webPreviewContainer: DocumentWebPreviewContainer?
    private let url: URL?
    private var closed = false
    private static let maxPlainTextPreviewBytes = 512 * 1024

    private static let spreadsheetOrDeckExtensions: Set<String> = [
        "xlsx", "xls", "csv", "tsv", "numbers", "pptx", "ppt", "key",
    ]
    private static let documentOrCodeExtensions: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "pages", "odt", "md", "markdown", "txt",
        "json", "yaml", "yml", "xml", "html", "htm", "toml", "ini", "log",
        "swift", "rs", "py", "ts", "tsx", "js", "jsx", "c", "cpp", "h", "hpp",
        "m", "mm", "go", "rb", "java", "kt", "sh", "zsh", "sql", "css", "scss",
    ]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "aac", "ogg"]

    private static func fittedSize(
        width: CGFloat,
        height: CGFloat,
        maxSize: NSSize,
        scaleHint: CGFloat = 1,
        maxUpscale: CGFloat = 1
    ) -> NSSize {
        let minW: CGFloat = 400
        let minH: CGFloat = 300
        let maxW = max(minW, maxSize.width)
        let maxH = max(minH, maxSize.height)
        guard width > 0, height > 0 else {
            return NSSize(width: min(680, maxW), height: min(520, maxH))
        }
        let targetW = width * scaleHint
        let targetH = height * scaleHint
        let ratioScale = min(maxW / targetW, maxH / targetH)
        let boundedScale = ratioScale < 1 ? ratioScale : min(ratioScale, maxUpscale)
        var fittedW = round(targetW * boundedScale)
        var fittedH = round(targetH * boundedScale)
        if fittedW < minW || fittedH < minH {
            let up = min(maxW / max(fittedW, 1), maxH / max(fittedH, 1), max(minW / max(fittedW, 1), minH / max(fittedH, 1)))
            fittedW = min(maxW, round(fittedW * up))
            fittedH = min(maxH, round(fittedH * up))
        }
        return NSSize(width: max(minW, min(maxW, fittedW)), height: max(minH, min(maxH, fittedH)))
    }

    static func preferredContentSize(
        for url: URL,
        page: Int?,
        maxSize: NSSize,
        backingScale: CGFloat = 2
    ) -> NSSize {
        let maxW = max(400, maxSize.width)
        let maxH = max(300, maxSize.height)
        func fit(width: CGFloat, height: CGFloat, scaleHint: CGFloat = 1, maxUpscale: CGFloat = 1) -> NSSize {
            Self.fittedSize(width: width, height: height, maxSize: maxSize, scaleHint: scaleHint, maxUpscale: maxUpscale)
        }

        let ext = url.pathExtension.lowercased()
        if page != nil || ext == "pdf",
           let document = PDFDocument(url: url), !document.isLocked,
           document.pageCount > 0 {
            let index = min(max((page ?? 1) - 1, 0), document.pageCount - 1)
            if let pdfPage = document.page(at: index) {
                let bounds = pdfPage.bounds(for: .cropBox)
                let rotated = abs(pdfPage.rotation) % 180 == 90
                let w = rotated ? bounds.height : bounds.width
                let h = rotated ? bounds.width : bounds.height
                return fit(width: w, height: h, scaleHint: 1.2, maxUpscale: 1.35)
            }
        }
        if UTType(filenameExtension: ext)?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let rawW = props[kCGImagePropertyPixelWidth as String] as? CGFloat,
           let rawH = props[kCGImagePropertyPixelHeight as String] as? CGFloat,
           rawW > 0, rawH > 0 {
            let orientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
            let swapped = (5...8).contains(orientation)
            let pxW = swapped ? rawH : rawW
            let pxH = swapped ? rawW : rawH
            let scale = max(backingScale, 1)
            return fit(width: pxW / scale, height: pxH / scale, scaleHint: 1, maxUpscale: 1.5)
        }
        if Self.spreadsheetOrDeckExtensions.contains(ext) {
            return NSSize(width: min(920, maxW), height: min(620, maxH))
        }
        if Self.documentOrCodeExtensions.contains(ext) || MacPreviewRenderer.isPlainTextExtension(ext) {
            return NSSize(width: min(760, maxW), height: min(680, maxH))
        }
        if Self.videoExtensions.contains(ext) {
            return NSSize(width: min(880, maxW), height: min(520, maxH))
        }
        if Self.audioExtensions.contains(ext) {
            return NSSize(width: min(480, maxW), height: min(300, maxH))
        }
        return NSSize(width: min(680, maxW), height: min(520, maxH))
    }

    private static func readBoundedPlainText(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxPlainTextPreviewBytes) else { return nil }
        let bytes = [UInt8](data)
        guard !bytes.contains(0) else { return nil }
        var end = bytes.count
        if end == maxPlainTextPreviewBytes {
            // Avoid splitting a multi-byte UTF-8 scalar at the cap.
            var lead = end - 1
            while lead >= 0, end - lead <= 3, bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
            if lead >= 0, bytes[lead] >= 0xC0 {
                let needed = bytes[lead] >= 0xF0 ? 4 : (bytes[lead] >= 0xE0 ? 3 : 2)
                if end - lead < needed { end = lead }
            }
        }
        guard let text = String(data: Data(bytes[..<end]), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    init?(
        url: URL,
        title: String,
        page: Int? = nil,
        highlight: String? = nil,
        snippet: String? = nil,
        context: String? = nil,
        isRelated: Bool = false,
        chinese: Bool = true,
        maxSize: NSSize? = nil,
        backingScale: CGFloat? = nil
    ) {
        let cap = maxSize ?? NSSize(width: 960, height: 760)
        let size = Self.preferredContentSize(for: url, page: page, maxSize: cap, backingScale: backingScale ?? 2)
        let frame = NSRect(origin: .zero, size: size)
        let ext = url.pathExtension.lowercased()
        let trimmedHighlight = highlight?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedHighlight = trimmedHighlight.isEmpty ? snippet : trimmedHighlight
        let evidence = snippet.map {
            PreviewEvidence(text: $0, match: isRelated ? .related : .literal,
                            page: page, context: context, highlight: resolvedHighlight)
        }
        let view: NSView
        var destination: PDFPage?
        var firstHighlight: PDFSelection?
        if let page {
            let display = PDFView(frame: frame)
            guard page > 0, let document = PDFDocument(url: url), !document.isLocked,
                  page <= document.pageCount, let target = document.page(at: page - 1) else { return nil }
            display.displayMode = .singlePageContinuous
            display.autoScales = true
            display.document = document
            let matches = MacPreviewRenderer.pdfPageSelections(in: document, on: target, highlight: resolvedHighlight, snippet: snippet)
            if !matches.isEmpty {
                display.highlightedSelections = matches
                firstHighlight = matches.first
            }
            preview = nil
            pdf = display
            imageView = nil
            webPreviewContainer = nil
            destination = target
            view = display
        } else if ext == "pdf",
                  let document = PDFDocument(url: url), !document.isLocked,
                  document.pageCount > 0 {
            let display = PDFView(frame: frame)
            display.displayMode = .singlePageContinuous
            display.autoScales = true
            display.document = document
            if resolvedHighlight != nil || snippet != nil {
                let limit = min(document.pageCount, 40)
                for index in 0..<limit {
                    guard let candidate = document.page(at: index) else { continue }
                    let matches = MacPreviewRenderer.pdfPageSelections(
                        in: document, on: candidate, highlight: resolvedHighlight, snippet: snippet
                    )
                    if !matches.isEmpty {
                        display.highlightedSelections = matches
                        firstHighlight = matches.first
                        destination = candidate
                        break
                    }
                }
            }
            preview = nil
            pdf = display
            imageView = nil
            webPreviewContainer = nil
            view = display
        } else {
            let richContent: RichPreviewContent?
            if let richFormat = MacPreviewRenderer.richFormat(forExtension: ext) {
                richContent = DocumentPreviewRenderer.render(
                    url: url,
                    format: richFormat,
                    evidence: evidence,
                    isPending: LocalFile.isUbiquitousPlaceholder
                )
            } else if MacPreviewRenderer.isPlainTextExtension(ext),
                      let text = Self.readBoundedPlainText(at: url) {
                richContent = DocumentPreviewRenderer.renderPlainText(
                    text: text,
                    isCode: MacPreviewRenderer.isCodeExtension(ext),
                    fileName: url.lastPathComponent,
                    evidence: evidence
                )
            } else {
                richContent = nil
            }
            if let richContent {
                let container = DocumentWebPreviewContainer(chinese: chinese)
                container.frame = frame
                container.load(richContent, interactiveFocus: true)
                preview = nil
                pdf = nil
                imageView = nil
                webPreviewContainer = container
                view = container
            } else {
                guard let display = QLPreviewView(frame: frame, style: .normal) else { return nil }
                display.shouldCloseWithWindow = false
                display.autostarts = true
                display.previewItem = url as NSURL
                preview = display
                pdf = nil
                imageView = nil
                webPreviewContainer = nil
                if let evidence {
                    let wrapper = NSView(frame: frame)
                    let banner = NSHostingView(rootView: PinnedMatchBannerView(evidence: evidence, chinese: chinese))
                    banner.translatesAutoresizingMaskIntoConstraints = false
                    display.translatesAutoresizingMaskIntoConstraints = false
                    wrapper.addSubview(banner)
                    wrapper.addSubview(display)
                    NSLayoutConstraint.activate([
                        banner.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
                        banner.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
                        banner.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
                        display.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 6),
                        display.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                        display.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                        display.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                    ])
                    view = wrapper
                } else {
                    view = display
                }
            }
        }
        self.url = url
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        minSize = NSSize(width: 400, height: 300)
        contentView = view
        if let webPreviewContainer {
            initialFirstResponder = webPreviewContainer
        }
        if let destination {
            pdf?.layoutDocumentView()
            pdf?.go(to: destination)
            if let firstHighlight, pdf?.currentPage == destination {
                pdf?.go(to: firstHighlight)
                if pdf?.currentPage != destination {
                    pdf?.go(to: destination)
                }
            }
        }
    }

    init?(
        image: NSImage,
        title: String,
        maxSize: NSSize? = nil,
        backingScale: CGFloat? = nil
    ) {
        let cap = maxSize ?? NSSize(width: 960, height: 760)
        let rep = image.representations.first
        let scale = max(backingScale ?? 2, 1)
        let rawW = rep.map { CGFloat($0.pixelsWide) / scale } ?? image.size.width
        let rawH = rep.map { CGFloat($0.pixelsHigh) / scale } ?? image.size.height
        let size = Self.fittedSize(width: max(rawW, image.size.width), height: max(rawH, image.size.height),
                                   maxSize: cap, scaleHint: 1, maxUpscale: 1.5)
        let frame = NSRect(origin: .zero, size: size)
        let display = NSImageView(frame: frame)
        display.image = image
        display.imageScaling = .scaleProportionallyUpOrDown
        display.imageAlignment = .alignCenter
        preview = nil
        pdf = nil
        imageView = display
        webPreviewContainer = nil
        url = nil
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        minSize = NSSize(width: 400, height: 300)
        contentView = display
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        if let onToggle { onToggle() } else { close() }
    }

    override func close() {
        guard !closed else { return }
        closed = true
        preview?.previewItem = nil
        preview?.close()
        pdf?.document = nil
        imageView?.image = nil
        webPreviewContainer?.teardown()
        webPreviewContainer = nil
        super.close()
    }

    var onToggle: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let editingFind = firstResponder is NSTextView
            if (modifiers.isEmpty && (event.keyCode == kVK_Escape || (event.keyCode == kVK_Space && !editingFind))) ||
                (modifiers == [.command] && event.charactersIgnoringModifiers?.lowercased() == "y") {
                if !event.isARepeat { onToggle?() }
                return
            }
        }
        super.sendEvent(event)
    }

    var previewURL: URL? {
        guard !closed else { return nil }
        if let preview { return (preview.previewItem as? NSURL).map { $0 as URL } }
        return url
    }
    var displayedPDFPage: Int? {
        guard let view = pdf, let page = view.currentPage, let document = view.document else { return nil }
        let index = document.index(for: page)
        return index >= 0 && index < document.pageCount ? index + 1 : nil
    }
}
