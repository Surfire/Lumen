import Foundation

public struct PreviewEvidence: Sendable, Equatable {
    public enum Match: Sendable, Equatable { case literal, related }
    public let text: String
    public let match: Match
    public let page: Int?
    public let context: String?
    public let highlight: String?
    public init(text: String, match: Match, page: Int? = nil, context: String? = nil, highlight: String? = nil) {
        self.text = String(text.prefix(400))
        self.match = match
        self.page = page.flatMap { $0 > 0 ? $0 : nil }
        self.context = context.map { String($0.prefix(2400)) }
        self.highlight = highlight.map { String($0.prefix(400)) }
    }
}

public enum PreviewKind: Sendable, Equatable {
    case image
    /// nil means no match page is known. It must not be labelled a hit.
    case pdf(matchPage: Int?)
    case excerpt
    /// Bounded inline text or source code from a resident local file.
    case plainText
    /// Use the inline area for hydration progress, then hand off to Quick Look.
    case quickLook
}

public struct PreviewSelection: Sendable, Equatable {
    public let id: String
    /// Compare even when result identity is stable and the backing file is replaced.
    public let revision: String
    public let url: URL
    public let kind: PreviewKind
    public let evidence: PreviewEvidence?
    public init(id: String, revision: String, url: URL, kind: PreviewKind, evidence: PreviewEvidence? = nil) {
        self.id = id
        self.revision = revision
        self.url = url
        self.kind = kind
        self.evidence = evidence
    }
}

public struct PreviewDocument: Sendable, Equatable {
    public enum Visual: Sendable, Equatable {
        case image(Data)
        case pdf(Data, displayedPage: Int, isMatchPage: Bool)
    }
    public let visual: Visual?
    public let evidence: PreviewEvidence?
    public let text: String?
    public let isCode: Bool
    public init(visual: Visual? = nil, evidence: PreviewEvidence? = nil, text: String? = nil, isCode: Bool = false) {
        self.visual = visual
        self.evidence = evidence
        self.text = text
        self.isCode = isCode
    }
}

public enum PreviewFailure: Error, Sendable, Equatable {
    case notLocal, missing, downloadFailed, invalidContent, unavailablePage, noExcerpt
}
public enum InlinePreviewState: Sendable, Equatable {
    case closed
    case loading(PreviewSelection)
    case downloading(PreviewSelection, fraction: Double?)
    case ready(PreviewSelection, PreviewDocument)
    case unavailable(PreviewSelection, PreviewFailure)
}

@MainActor
public final class InlinePreviewCoordinator {
    public typealias DownloadProgress = @MainActor @Sendable (Double?) -> Void
    public typealias Loader = @Sendable (PreviewSelection, Bool, @escaping DownloadProgress) async throws -> PreviewDocument
    private let load: Loader
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var selection: PreviewSelection?
    /// Delivery callback; bind it to the launcher's observable view model.
    public var onChange: ((InlinePreviewState) -> Void)?
    public private(set) var state: InlinePreviewState = .closed

    public init(load: @escaping Loader) { self.load = load }
    deinit { operation?.cancel() }

    public func show(_ item: PreviewSelection, allowCloudDownload: Bool) {
        if item == selection { return }
        invalidate()
        selection = item
        let current = generation
        let loader = load
        operation = Task { [weak self] in
            let next: InlinePreviewState
            do {
                try Task.checkCancellation()
                next = .ready(item, try await loader(item, allowCloudDownload) { [weak self] fraction in
                    guard let self, !Task.isCancelled, self.generation == current, self.operation != nil else { return }
                    let bounded = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
                    let downloading = InlinePreviewState.downloading(item, fraction: bounded)
                    if self.state != downloading { self.publish(downloading) }
                })
            } catch is CancellationError {
                return
            } catch let error as PreviewFailure {
                next = .unavailable(item, error)
            } catch {
                next = .unavailable(item, .invalidContent)
            }
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.operation = nil
            self.publish(next)
        }
        publish(.loading(item))
    }

    /// First Esc closes preview; callers handle clearing/dismissing on a later Esc.
    @discardableResult public func close() -> Bool {
        guard state != .closed else { return false }
        invalidate()
        selection = nil
        publish(.closed)
        return true
    }

    /// Use on query change or index-scope change even if selection IDs did not change.
    public func reset() { _ = close() }

    private func invalidate() {
        operation?.cancel()
        operation = nil
        generation = UUID()
    }
    private func publish(_ next: InlinePreviewState) {
        state = next
        onChange?(next)
    }
}
