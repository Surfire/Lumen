import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class LauncherInlinePreview: ObservableObject {
    struct DownloadProvider: Sendable {
        let isPending: @Sendable (URL) -> Bool
        let download: @Sendable (URL, @escaping InlinePreviewCoordinator.DownloadProgress) async throws -> Void

        static let system = DownloadProvider(isPending: { LocalFile.isUbiquitousPlaceholder($0) },
                                             download: { try await downloadFromCloud($0, report: $1) })
    }

    @Published private(set) var state: InlinePreviewState = .closed
    @Published private(set) var hit: SearchHit?
    private(set) var image: NSImage?
    var onQuickLookReady: (() -> Void)?
    private let downloads: DownloadProvider

    init(downloads: DownloadProvider = .system) { self.downloads = downloads }

    private lazy var coordinator: InlinePreviewCoordinator = {
        let downloads = downloads
        let coordinator = InlinePreviewCoordinator { item, allowCloudDownload, report in
            try await Self.render(item, downloads: downloads, allowCloudDownload: allowCloudDownload, report: report)
        }
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
            if case .ready(let selection, _) = state, selection.kind == .quickLook {
                self.onQuickLookReady?()
            }
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

    func show(_ hit: SearchHit, kind: PreviewKind, allowCloudDownload: Bool) {
        guard self.hit != hit else { return }
        self.hit = hit
        let evidence = hit.snippet.map {
            PreviewEvidence(text: $0, match: hit.isSemanticCandidate ? .related : .literal, page: hit.pdf_page)
        }
        coordinator.show(PreviewSelection(id: hit.path, revision: hit.document_stamp ?? "",
                                          url: URL(fileURLWithPath: hit.path), kind: kind, evidence: evidence),
                         allowCloudDownload: allowCloudDownload)
    }

    func retainPreview(for current: SearchHit?) {
        guard let hit, hit != current else { return }
        // Hydration can refresh the availability of this same name-only result.
        if let current, current.path == hit.path, current.kind == hit.kind,
           current.snippet == nil, hit.snippet == nil,
           current.document_stamp == hit.document_stamp, current.pdf_page == hit.pdf_page {
            self.hit = current
        } else {
            close()
        }
    }

    @discardableResult func close() -> Bool {
        guard hit != nil else { return false }
        hit = nil
        return coordinator.close()
    }

    func withResidentFile<T>(_ url: URL, expectedStamp: String?, _ work: () throws -> T) throws -> T {
        try LocalFile.withResidentFile(url, expectedStamp: expectedStamp, isPending: downloads.isPending, work)
    }

    nonisolated private static func render(_ item: PreviewSelection, downloads: DownloadProvider,
                                           allowCloudDownload: Bool,
                                           report: @escaping InlinePreviewCoordinator.DownloadProgress) async throws -> PreviewDocument {
        let task = Task.detached(priority: .utility) {
            let renderer = MacPreviewRenderer()
            do {
                return try renderer.load(item, isPending: downloads.isPending)
            } catch is LocalFile.Placeholder {
                guard allowCloudDownload else { throw PreviewFailure.notLocal }
            }
            try Task.checkCancellation()
            await report(nil)
            do {
                try await downloads.download(item.url, report)
            } catch {
                try Task.checkCancellation()
                throw PreviewFailure.downloadFailed
            }
            do {
                return try renderer.load(item, isPending: downloads.isPending)
            } catch is LocalFile.Placeholder {
                throw PreviewFailure.downloadFailed
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value },
                                                     onCancel: { task.cancel() })
    }

    // Coordinate on one worker thread; NSFileCoordinator.cancel() is safe from any thread.
    private final class CloudRead: @unchecked Sendable {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let request = Progress(totalUnitCount: 1)
    }

    nonisolated private static func downloadFromCloud(_ url: URL,
                                                      report: @escaping InlinePreviewCoordinator.DownloadProgress) async throws {
        let read = CloudRead()
        let updates = Task {
            while !Task.isCancelled && !read.request.isCancelled {
                let coordinated = read.request.fractionCompleted
                // Some providers publish iCloud metadata instead of child Progress.
                let fraction: Double? = coordinated > 0 ? coordinated : try? LocalFile.withMaterializationDisabled {
                    let fresh = URL(fileURLWithPath: url.path)
                    let values = try fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey,
                                                                   .ubiquitousItemIsDownloadingKey])
                    if values.ubiquitousItemIsDownloading == true {
                        let percent = NSMetadataItem(url: fresh)?.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey)
                        return (percent as? NSNumber).map { $0.doubleValue / 100 }
                    }
                    let status = values.ubiquitousItemDownloadingStatus
                    return status == .downloaded || status == .current ? 1 : nil
                }
                await report(fraction)
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { updates.cancel() }
        try await withTaskCancellationHandler {
            // File coordination can block while the provider downloads. Keep it off
            // the main actor and the cooperative executor.
            try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    guard !read.request.isCancelled else { completion.resume(throwing: CancellationError()); return }
                    var error: NSError?
                    // Let the coordinated read request hydration and collect any child progress it emits.
                    read.request.becomeCurrent(withPendingUnitCount: 1)
                    read.coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in }
                    read.request.resignCurrent()
                    if read.request.isCancelled { completion.resume(throwing: CancellationError()) }
                    else if let error { completion.resume(throwing: error) }
                    else { completion.resume() }
                }
            }
        } onCancel: {
            read.request.cancel()
            read.coordinator.cancel()
        }
    }
}
