import Combine
import Foundation

@MainActor
final class TranslationPanelModel: ObservableObject {
    enum Activity: Equatable { case translating, testing, listing }
    enum Status: Equatable { case saved, removedKey, connected, models(Int), canceled, failure(TranslationFailure) }

    private struct Preferences: Codable {
        var providers: [TranslationProvider]
        var selected: UUID
        var source: TranslationLanguage
        var target: TranslationLanguage
    }

    @Published private(set) var providers: [TranslationProvider]
    @Published private(set) var selected: UUID
    @Published var source: TranslationLanguage { didSet { store() } }
    @Published var target: TranslationLanguage { didSet { store() } }
    @Published var input = ""
    @Published private(set) var output = ""
    @Published var showSettings = false
    @Published var draft: TranslationProvider
    @Published var keyInput = ""
    @Published private(set) var activity: Activity?
    @Published private(set) var status: Status?
    @Published private var discovered: [String] = []
    private var discoveredEndpoint: TranslationEndpoint?

    private static let preferenceKey = "translation.preferences.v1"
    private let defaults: UserDefaults?
    private let client: TranslationClient
    private var work: Task<Void, Never>?
    private var generation = 0

    init(defaults: UserDefaults? = .standard, client: TranslationClient = .init()) {
        self.defaults = defaults
        self.client = client
        let local = TranslationProvider.localOMLX
        let saved = defaults?.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
        let available = saved.flatMap { $0.providers.isEmpty ? nil : $0.providers } ?? [local]
        let current = available.first(where: { $0.id == saved?.selected }) ?? available[0]
        providers = available
        selected = current.id
        draft = current
        source = saved?.source ?? .automatic
        let storedTarget = saved?.target ?? .simplifiedChinese
        target = storedTarget == .automatic ? .simplifiedChinese : storedTarget
    }

    var provider: TranslationProvider? { providers.first { $0.id == selected } }
    var availableModels: [String] {
        guard let endpoint = try? TranslationEndpoint(draft.endpoint), endpoint == discoveredEndpoint else { return [] }
        return discovered
    }

    var canTranslate: Bool {
        guard activity == nil, source != target, target != .automatic, let provider else { return false }
        return TranslationClient.isValidInput(input) && TranslationClient.isValidModel(provider.model)
            && (try? TranslationEndpoint(provider.endpoint)) != nil
    }

    func choose(_ id: UUID) {
        guard activity == nil, let provider = providers.first(where: { $0.id == id }) else { return }
        selected = id
        draft = provider
        resetDraftState()
        output = ""
        store()
    }

    func newProvider() {
        guard activity == nil else { return }
        draft = TranslationProvider()
        resetDraftState()
        showSettings = true
    }

    func saveProvider() {
        guard activity == nil else { return }
        do {
            var proposed = draft
            proposed.name = proposed.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !proposed.name.isEmpty, proposed.name.utf8.count <= 100,
                  !proposed.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw TranslationFailure.invalidProvider }
            let endpoint = try TranslationEndpoint(proposed.endpoint)
            proposed.endpoint = endpoint.url.absoluteString
            proposed.model = proposed.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard proposed.model.isEmpty || TranslationClient.isValidModel(proposed.model)
            else { throw TranslationFailure.missingModel }
            if !keyInput.isEmpty {
                guard TranslationClient.isValidKey(keyInput) else { throw TranslationFailure.invalidKey }
                try client.secrets.save(keyInput, provider: proposed.id, endpoint: endpoint)
            }
            if let index = providers.firstIndex(where: { $0.id == proposed.id }) {
                providers[index] = proposed
            } else {
                providers.append(proposed)
            }
            selected = proposed.id
            draft = proposed
            keyInput = ""
            output = ""
            store()
            status = .saved
        } catch { showFailure(error) }
    }

    var canRemoveKey: Bool {
        guard activity == nil,
              let provider = providers.first(where: { $0.id == draft.id }),
              let endpoint = try? TranslationEndpoint(draft.endpoint) else { return false }
        return endpoint.url.absoluteString == provider.endpoint
    }

    func removeKey() {
        guard canRemoveKey else { return }
        do {
            try client.secrets.remove(provider: draft.id)
            keyInput = ""
            status = .removedKey
        } catch { showFailure(error) }
    }

    func checkProvider(listModels: Bool) {
        guard activity == nil else { return }
        let provider = draft
        let testKey = keyInput.isEmpty ? nil : keyInput
        discoveredEndpoint = nil
        discovered = []
        start(listModels ? .listing : .testing) { [client] model in
            let models = try await client.models(provider, testKey: testKey)
            try Task.checkCancellation()
            if listModels {
                model.discoveredEndpoint = try TranslationEndpoint(provider.endpoint)
                model.discovered = models
                model.status = .models(models.count)
            } else {
                model.status = .connected
            }
        }
    }

    func translate() {
        guard canTranslate, let provider else { return }
        let (text, source, target) = (input, self.source, self.target)
        output = ""
        start(.translating) { [client] model in
            let translation = try await client.translate(text, source: source, target: target, provider: provider)
            try Task.checkCancellation()
            model.output = translation
        }
    }

    func cancel() {
        guard work != nil else { return }
        generation += 1
        work?.cancel()
        work = nil
        activity = nil
        status = .canceled
    }

    private func start(_ activity: Activity,
                       perform: @escaping @MainActor (TranslationPanelModel) async throws -> Void) {
        generation += 1
        let current = generation
        self.activity = activity
        status = nil
        work = Task { [weak self] in
            guard let self else { return }
            do { try await perform(self) }
            catch {
                if !Task.isCancelled, self.generation == current { self.showFailure(error) }
            }
            if self.generation == current {
                self.work = nil
                self.activity = nil
            }
        }
    }

    private func resetDraftState() {
        keyInput = ""
        discoveredEndpoint = nil
        discovered = []
        status = nil
    }

    private func showFailure(_ error: Error) {
        status = .failure(error as? TranslationFailure ?? .transport)
    }

    private func store() {
        let prefs = Preferences(providers: providers, selected: selected, source: source, target: target)
        if let data = try? JSONEncoder().encode(prefs) {
            defaults?.set(data, forKey: Self.preferenceKey)
        }
    }
}
