import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class LauncherInlinePreview: ObservableObject {
    @Published private(set) var state: InlinePreviewState = .closed
    @Published private(set) var hit: SearchHit?
    private(set) var image: NSImage?

    private lazy var coordinator: InlinePreviewCoordinator = {
        let coordinator = InlinePreviewCoordinator { item in try await Self.render(item) }
        coordinator.onChange = { [weak self] state in
            guard let self else { return }
            self.image = nil
            if case .ready(_, let document) = state {
                switch document.visual {
                case .image(let bytes), .pdf(let bytes, _, _): self.image = NSImage(data: bytes)
                case nil: break
                }
            }
            self.state = state
        }
        return coordinator
    }()

    var isOpen: Bool { hit != nil }

    nonisolated static func kind(_ hit: SearchHit) -> PreviewKind? {
        guard hit.kind == "file" else { return nil }
        let ext = (hit.name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf(matchPage: hit.pdf_page) }
        if UTType(filenameExtension: ext)?.conforms(to: .image) == true { return .image }
        if hit.snippet != nil { return .excerpt }
        return nil
    }

    func show(_ hit: SearchHit) {
        guard let kind = Self.kind(hit) else { close(); return }
        guard self.hit != hit else { return }
        self.hit = hit
        let evidence = hit.snippet.map {
            PreviewEvidence(text: $0, match: hit.isSemanticCandidate ? .related : .literal, page: hit.pdf_page)
        }
        let url = URL(fileURLWithPath: hit.path)
        coordinator.show(PreviewSelection(id: hit.path, revision: hit.document_stamp ?? "",
                                          url: url, kind: kind,
                                          residency: hit.isLocal && Self.allows(url) ? .provenLocal : .placeholderOrManaged,
                                          evidence: evidence))
    }

    @discardableResult func close() -> Bool {
        guard hit != nil else { return false }
        hit = nil
        return coordinator.close()
    }

    nonisolated static func allows(_ url: URL) -> Bool {
        !url.pathComponents.contains { part in
            let name = part.lowercased()
            return ["cloudstorage", "mobile documents", "dropbox", "google drive", "icloud drive", "box sync", "onedrive"].contains(name)
                || name.hasPrefix("onedrive - ") || name.hasPrefix("onedrive-") || name.hasSuffix(".icloud")
        }
    }

    nonisolated private static func render(_ item: PreviewSelection) async throws -> PreviewDocument {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let path = item.url.path
            guard item.residency == .provenLocal, allows(item.url) else { throw PreviewFailure.notLocal }
            guard let stamp = SearchHit.pathStamp(at: path, kind: "file"),
                  item.evidence == nil || !item.revision.isEmpty,
                  item.revision.isEmpty || item.revision == stamp else { throw PreviewFailure.missing }
            if item.kind == .excerpt {
                guard let evidence = item.evidence else { throw PreviewFailure.noExcerpt }
                return PreviewDocument(evidence: evidence)
            }

            let hit = SearchHit(path: path, name: item.url.lastPathComponent, kind: "file",
                                availability: "local", matched_by: "name", snippet: nil,
                                document_stamp: nil, pdf_page: nil)
            let snapshot: PreviewSnapshot
            do {
                snapshot = try PreviewSnapshot.make(for: hit, maximum: 24 * 1024 * 1024,
                                                    expectedStamp: stamp, requiresResidentMetadata: true)
            } catch PreviewSnapshot.Failure.tooLarge {
                throw PreviewFailure.overLimit
            } catch PreviewSnapshot.Failure.unavailable {
                throw PreviewFailure.missing
            }
            defer { snapshot.remove() }
            guard let privateRoot = MacPreviewRenderer.canonicalDirectory(snapshot.directory) else { throw PreviewFailure.missing }
            let canonicalSnapshot = privateRoot.appendingPathComponent(snapshot.url.lastPathComponent, isDirectory: false)
            let copy = PreviewSelection(id: item.id, revision: item.revision, url: canonicalSnapshot,
                                        kind: item.kind, residency: .provenLocal, evidence: item.evidence)
            let preview = try await MacPreviewRenderer(knownLocalRoots: [privateRoot]).load(copy)
            try Task.checkCancellation()
            guard SearchHit.pathStamp(at: path, kind: "file") == stamp else { throw PreviewFailure.missing }
            return preview
        }
        return try await withTaskCancellationHandler(operation: { try await task.value },
                                                     onCancel: { task.cancel() })
    }
}
