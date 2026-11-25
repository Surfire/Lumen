import Foundation

public enum PreviewResidency: Sendable, Equatable {
    /// The index owner affirmatively identifies the path as resident on a local,
    /// non-provider-managed volume and in an opted-in preview scope.
    case provenLocal
    case placeholderOrManaged
    case unknown
}

public struct PreviewEvidence: Sendable, Equatable {
    public enum Match: Sendable, Equatable { case literal, related }
    public let text: String
    public let match: Match
    public let page: Int?
    public init(text: String, match: Match, page: Int? = nil) {
        self.text = String(text.prefix(400))
        self.match = match
        self.page = page.flatMap { $0 > 0 ? $0 : nil }
    }
}

public enum PreviewKind: Sendable, Equatable {
    case image
    /// nil means no match page is known. It must not be labelled a hit.
    case pdf(matchPage: Int?)
    case excerpt
}

public struct PreviewSelection: Sendable, Equatable {
    public let id: String
    /// Compare even when result identity is stable and the backing file is replaced.
    public let revision: String
    public let url: URL
    public let kind: PreviewKind
    public let residency: PreviewResidency
    public let evidence: PreviewEvidence?
    public init(id: String, revision: String, url: URL, kind: PreviewKind,
                residency: PreviewResidency, evidence: PreviewEvidence? = nil) {
        self.id = id
        self.revision = revision
        self.url = url
        self.kind = kind
        self.residency = residency
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
    public init(visual: Visual? = nil, evidence: PreviewEvidence? = nil) {
        self.visual = visual
        self.evidence = evidence
    }
}

public enum PreviewFailure: Error, Sendable, Equatable {
    case notLocal, missing, overLimit, invalidContent, unavailablePage, noExcerpt
}
public enum InlinePreviewState: Sendable, Equatable {
    case closed
    case loading(PreviewSelection)
    case ready(PreviewSelection, PreviewDocument)
    case unavailable(PreviewSelection, PreviewFailure)
}

@MainActor
public final class InlinePreviewCoordinator {
    public typealias Loader = @Sendable (PreviewSelection) async throws -> PreviewDocument
    private let load: Loader
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var selection: PreviewSelection?
    /// Delivery callback; bind it to the launcher's observable view model.
    public var onChange: ((InlinePreviewState) -> Void)?
    public private(set) var state: InlinePreviewState = .closed

    public init(load: @escaping Loader) { self.load = load }
    deinit { operation?.cancel() }

    public func show(_ item: PreviewSelection) {
        if item == selection { return }
        invalidate()
        selection = item
        guard item.residency == .provenLocal, item.url.isFileURL,
              item.url.host == nil || item.url.host == "" || item.url.host == "localhost" else {
            publish(.unavailable(item, .notLocal))
            return
        }
        let current = generation
        let loader = load
        operation = Task { [weak self] in
            let next: InlinePreviewState
            do {
                try Task.checkCancellation()
                next = .ready(item, try await loader(item))
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
