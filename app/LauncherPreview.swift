import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Quartz

enum FileAction: Equatable {
    case open, reveal, preview, copyName, copyPath

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
            guard fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
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

@MainActor
final class LocalPreviewPanel: NSPanel {
    private let preview: QLPreviewView?
    private let pdf: PDFView?
    private let url: URL
    private var closed = false

    init?(url: URL, title: String, page: Int? = nil) {
        let frame = NSRect(x: 0, y: 0, width: 680, height: 520)
        let view: NSView
        var destination: PDFPage?
        if let page {
            let display = PDFView(frame: frame)
            guard page > 0, let document = PDFDocument(url: url), !document.isLocked,
                  page <= document.pageCount, let target = document.page(at: page - 1) else { return nil }
            display.displayMode = .singlePage
            display.autoScales = true
            display.document = document
            preview = nil
            pdf = display
            destination = target
            view = display
        } else {
            guard let display = QLPreviewView(frame: frame, style: .normal) else { return nil }
            display.shouldCloseWithWindow = false
            display.autostarts = true
            display.previewItem = url as NSURL
            preview = display
            pdf = nil
            view = display
        }
        self.url = url
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        minSize = NSSize(width: 400, height: 300)
        contentView = view
        if let destination { pdf?.go(to: destination) }
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        guard !closed else { return }
        closed = true
        preview?.previewItem = nil
        preview?.close()
        pdf?.document = nil
        super.close()
    }

    var onToggle: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if modifiers.isEmpty && event.keyCode == kVK_Space ||
                modifiers == [.command] && event.charactersIgnoringModifiers?.lowercased() == "y" {
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
