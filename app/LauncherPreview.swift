import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Quartz

enum FileAction: Equatable {
    case open, reveal, preview, copyName, copyPath

    var allowsCloudReference: Bool {
        switch self {
        case .reveal, .copyName, .copyPath: return true
        case .open, .preview: return false
        }
    }
}

struct PreviewSnapshot {
    let directory: URL
    let url: URL

    enum Failure: Error { case unavailable, tooLarge }

    static func make(for hit: SearchHit, maximum: Int64 = 128 * 1024 * 1024,
                     expectedStamp: String? = nil, requiresResidentMetadata: Bool = false) throws -> PreviewSnapshot {
        guard hit.isLocal, hit.kind == "file", let current = hit.pathStamp(),
              expectedStamp == nil || expectedStamp == current,
              !hit.hasPreview || hit.document_stamp == current else { throw Failure.unavailable }

        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw Failure.unavailable }
        defer { _ = setiopolicy_np(policy, scope, prior) }

        if requiresResidentMetadata {
            let url = URL(fileURLWithPath: hit.path)
            guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]),
                  values.isUbiquitousItem != true, values.volumeIsLocal == true else { throw Failure.unavailable }
        }

        guard let descriptor = LocalFile.openReadOnly(hit.path) else { throw Failure.unavailable }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var attributes = stat()
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              fstat(descriptor, &attributes) == 0, matches(attributes, stamp: current) else {
            throw Failure.unavailable
        }
        let length = Int64(attributes.st_size)
        guard length >= 0 && length <= maximum else { throw Failure.tooLarge }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-preview-" + UUID().uuidString, isDirectory: true)
        let filename = URL(fileURLWithPath: hit.path).lastPathComponent
        guard !filename.isEmpty else { throw Failure.unavailable }
        let snapshot = PreviewSnapshot(directory: directory, url: directory.appendingPathComponent(filename, isDirectory: false))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { snapshot.remove() } }

        let target = Darwin.open(snapshot.url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard target >= 0 else { throw Failure.unavailable }
        let output = FileHandle(fileDescriptor: target, closeOnDealloc: true)
        defer { try? output.close() }

        var copied: Int64 = 0
        while let bytes = try input.read(upToCount: 256 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            copied += Int64(bytes.count)
            guard copied <= length else { throw Failure.unavailable }
            try output.write(contentsOf: bytes)
        }
        try output.close()
        guard copied == length, fstat(descriptor, &attributes) == 0, matches(attributes, stamp: current),
              hit.pathStamp() == current else { throw Failure.unavailable }

        // Quick Look may open its input from another process. Give it only the private local snapshot.
        complete = true
        return snapshot
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static func matches(_ info: stat, stamp: String) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_flags & UInt32(SF_DATALESS) == 0 &&
            SearchHit.filesystemStamp(info) == stamp
    }
}

enum LocalFile {
    static func dragURL(for hit: SearchHit, resourceValues: (URL, [URLResourceKey]) throws -> [URLResourceKey: Any] = {
        try ($0 as NSURL).resourceValues(forKeys: $1)
    }) -> URL? {
        guard hit.isLocal, SearchHit.pathAttributes(at: hit.path, kind: hit.kind) != nil else { return nil }
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return nil }
        defer { _ = setiopolicy_np(policy, scope, prior) }
        // The live path check rejects dataless leaves and ancestors. Ubiquity only
        // signals iCloud membership, not whether the item is locally resident.
        let url = URL(fileURLWithPath: hit.path, isDirectory: hit.kind == "directory")
        guard let values = try? resourceValues(url, [.volumeIsLocalKey]),
              values[.volumeIsLocalKey] as? Bool == true else { return nil }
        return url
    }

    static func openReadOnly(_ path: String) -> Int32? {
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        let options = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var parent = Darwin.open("/", options | O_DIRECTORY)
        guard parent >= 0 else { return nil }
        defer { if parent >= 0 { Darwin.close(parent) } }
        for (index, name) in components.enumerated() {
            let isFile = index == components.count - 1
            let next = openat(parent, String(name), options | (isFile ? 0 : O_DIRECTORY))
            guard next >= 0 else { return nil }
            Darwin.close(parent)
            parent = next
            var info = stat()
            guard fstat(parent, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0,
                  info.st_mode & S_IFMT == (isFile ? S_IFREG : S_IFDIR) else { return nil }
        }
        let opened = parent
        parent = -1
        return opened
    }
}

@MainActor
final class LocalPreviewPanel: NSPanel {
    private let preview: QLPreviewView?
    private let pdf: PDFView?
    private let snapshot: PreviewSnapshot
    private var closed = false

    init?(snapshot: PreviewSnapshot, title: String, page: Int? = nil) {
        let frame = NSRect(x: 0, y: 0, width: 680, height: 520)
        let view: NSView
        var destination: PDFPage?
        if let page {
            let display = PDFView(frame: frame)
            guard page > 0, let document = PDFDocument(url: snapshot.url), !document.isLocked,
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
            display.previewItem = snapshot.url as NSURL
            preview = display
            pdf = nil
            view = display
        }
        self.snapshot = snapshot
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
        snapshot.remove()
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

    var previewURL: URL? { closed ? nil : snapshot.url }
    var displayedPDFPage: Int? {
        guard let view = pdf, let page = view.currentPage, let document = view.document else { return nil }
        let index = document.index(for: page)
        return index >= 0 && index < document.pageCount ? index + 1 : nil
    }
}
