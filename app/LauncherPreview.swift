import AppKit
import Darwin
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
    private let directory: URL
    let url: URL

    private enum Failure: Error { case unavailable, tooLarge }

    static func make(for hit: SearchHit) throws -> PreviewSnapshot {
        let maximum: Int64 = 128 * 1024 * 1024
        guard hit.isLocal, hit.kind == "file", let current = hit.pathStamp(),
              !hit.hasPreview || hit.document_stamp == current else { throw Failure.unavailable }

        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw Failure.unavailable }
        defer { _ = setiopolicy_np(policy, scope, prior) }

        let descriptor = try openLocalFile(hit.path)
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

    private static func openLocalFile(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure.unavailable }
        let options = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var parent = Darwin.open("/", options | O_DIRECTORY)
        guard parent >= 0 else { throw Failure.unavailable }
        defer { if parent >= 0 { Darwin.close(parent) } }
        for (index, name) in components.enumerated() {
            let isFile = index == components.count - 1
            let next = openat(parent, String(name), options | (isFile ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw Failure.unavailable }
            Darwin.close(parent)
            parent = next
            var info = stat()
            guard fstat(parent, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0,
                  info.st_mode & S_IFMT == (isFile ? S_IFREG : S_IFDIR) else { throw Failure.unavailable }
        }
        let opened = parent
        parent = -1
        return opened
    }
}

@MainActor
final class LocalPreviewPanel: NSPanel {
    private let preview: QLPreviewView
    private let snapshot: PreviewSnapshot
    private var closed = false

    init?(snapshot: PreviewSnapshot, title: String) {
        let frame = NSRect(x: 0, y: 0, width: 680, height: 520)
        guard let preview = QLPreviewView(frame: frame, style: .normal) else { return nil }
        self.preview = preview
        self.snapshot = snapshot
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        minSize = NSSize(width: 400, height: 300)
        contentView = preview
        preview.shouldCloseWithWindow = false
        preview.autostarts = true
        preview.previewItem = snapshot.url as NSURL
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        guard !closed else { return }
        closed = true
        preview.previewItem = nil
        preview.close()
        super.close()
        snapshot.remove()
    }

    var previewURL: URL? { (preview.previewItem as? NSURL).map { $0 as URL } }
}
