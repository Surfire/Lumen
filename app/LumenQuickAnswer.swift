import Foundation

/// Transient presentation state. UI must send only from its explicit submit action.
/// This object knows no keys, HTTP endpoints, files, history, clipboard, or tools.
@MainActor
public final class LumenQuickAnswer {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case answer(String)
        case failed
    }

    public typealias Answer = @MainActor (String) async throws -> String
    private var task: Task<Void, Never>?
    private var generation = UUID()
    public var onChange: ((State) -> Void)?
    public private(set) var state: State = .idle

    public init() {}

    public func submit(question: String, askConfiguredProvider: @escaping Answer) {
        let input = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= LumenCommandCatalog.maximumQuestionBytes else { return }
        task?.cancel()
        let ticket = UUID()
        generation = ticket
        task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let text = try await askConfiguredProvider(input).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled else { return }
                self?.finish(ticket, state: text.isEmpty ? .failed : .answer(text))
            } catch {
                guard !Task.isCancelled else { return }
                // Do not surface raw transport errors; they may contain request material.
                self?.finish(ticket, state: .failed)
            }
        }
        set(.loading)
    }

    /// Call on any query/provider change, Esc, or dismissal. Even a backend that
    /// disregards cancellation cannot overwrite a newer result.
    public func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        set(.idle)
    }

    private func finish(_ ticket: UUID, state: State) {
        guard ticket == generation else { return }
        task = nil
        set(state)
    }

    private func set(_ state: State) {
        self.state = state
        onChange?(state)
    }
}
