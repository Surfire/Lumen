import Combine
import Foundation
import UniformTypeIdentifiers

struct TranslationCommand: Equatable {
    let raw: String
    let text: String
    let source: TranslationLanguage
    let target: TranslationLanguage
    let unsupportedLanguage: String?

    private static let aliases: [(TranslationLanguage, [String])] = [
        (.simplifiedChinese, ["中", "中文", "汉语", "简中", "简体中文", "chinese", "mandarin", "zh", "zh-cn", "zh-hans", "zho", "chi"]),
        (.traditionalChinese, ["繁", "繁中", "繁体中文", "traditional-chinese", "zh-tw", "zh-hant"]),
        (.english, ["英", "英语", "英文", "english", "en", "eng"]),
        (.french, ["法", "法语", "法文", "french", "français", "fr", "fra"]),
        (.german, ["德", "德语", "德文", "german", "deutsch", "de", "deu"]),
        (.japanese, ["日", "日语", "日文", "japanese", "日本語", "ja", "jp", "jpn"]),
        (.russian, ["俄", "俄语", "俄文", "russian", "русский", "ru", "rus"]),
        (.korean, ["韩", "韩语", "韩文", "korean", "한국어", "ko", "kr", "kor"]),
        (.spanish, ["西", "西语", "西班牙语", "西班牙文", "spanish", "español", "es", "spa"]),
        (.portuguese, ["葡", "葡语", "葡萄牙语", "葡萄牙文", "portuguese", "português", "pt", "por"]),
        (.italian, ["意", "意语", "意大利语", "意大利文", "italian", "italiano", "it", "ita"]),
        (.arabic, ["阿", "阿拉伯语", "阿拉伯文", "arabic", "ar", "ara"]),
    ]

    static func parse(_ raw: String) -> Self? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let (head, tail) = split(input)
        let prefix = head.lowercased()
        var text = tail
        var requested: TranslationLanguage?
        var unsupported: String?
        switch prefix {
        case "翻译", "translate":
            // Keep explicit document filenames (e.g. "translate notes.pdf") searchable.
            if !tail.contains(where: \.isWhitespace),
               let type = UTType(filenameExtension: (tail as NSString).pathExtension),
               type.isDeclared, type.conforms(to: .content) { return nil }
        case "译", "tr":
            let (word, rest) = split(tail)
            // English "it" is common at the start of source text. Italian remains
            // available as tr:it, tr Italian, or tr 意.
            if word.lowercased() != "it", let language = language(for: word) {
                requested = language
                text = rest
            }
        default:
            if prefix.hasPrefix("tr:") || prefix.hasPrefix("译:") || prefix.hasPrefix("译：") {
                let word = String(head.dropFirst(prefix.hasPrefix("tr:") ? 3 : 2))
                requested = language(for: word)
                if requested == nil { unsupported = word }
            } else {
                let stem = prefix.hasPrefix("tr") ? "tr" : "译"
                guard prefix.hasPrefix(stem) else { return nil }
                let attached = String(head.dropFirst(stem.count))
                // Tight aliases must begin with an ideograph, so "tree" and
                // "translate.pdf" keep their normal search behavior.
                guard attached.unicodeScalars.first?.properties.isIdeographic == true,
                      let language = language(for: attached) else { return nil }
                requested = language
            }
        }

        let hasHan = text.unicodeScalars.contains { $0.properties.isIdeographic }
        return Self(raw: raw, text: text,
                    source: requested != nil ? .automatic : (hasHan ? .simplifiedChinese : .english),
                    target: requested ?? (hasHan ? .english : .simplifiedChinese),
                    unsupportedLanguage: unsupported)
    }

    private static func split(_ text: String) -> (String, String) {
        let boundary = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        let rest = text[boundary...].drop(while: \.isWhitespace)
        return (String(text[..<boundary]), String(rest))
    }

    private static func language(for word: String) -> TranslationLanguage? {
        let alias = word.lowercased()
        return aliases.first { $0.1.contains(alias) }?.0
    }
}

@MainActor
final class TranslationPanelModel: ObservableObject {
    enum Activity: Equatable { case translating, testing, listing }
    enum Status: Equatable { case saved, removedProvider, removedKey, connected, models(Int), canceled, failure(TranslationFailure) }

    private struct Preferences: Codable {
        var providers: [TranslationProvider]
        var selected: UUID
        var source: TranslationLanguage
        var target: TranslationLanguage
    }

    @Published private(set) var providers: [TranslationProvider]
    @Published private(set) var selected: UUID
    // Retain the old preference fields for compatibility with existing installs.
    private let source: TranslationLanguage
    private let target: TranslationLanguage
    @Published private(set) var command: TranslationCommand?
    @Published private(set) var output = ""
    @Published private(set) var copied = false
    @Published private(set) var draft: TranslationProvider
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
        let available = saved?.providers ?? [local]
        let current = available.first(where: { $0.id == saved?.selected }) ?? available.first ?? TranslationProvider()
        providers = available
        selected = current.id
        draft = current
        source = saved?.source ?? .automatic
        let storedTarget = saved?.target ?? .simplifiedChinese
        target = storedTarget == .automatic ? .simplifiedChinese : storedTarget
    }

    var provider: TranslationProvider? { providers.first { $0.id == selected } }
    func answerWithSavedProvider() -> LumenQuickAnswer.Answer? {
        guard let provider, TranslationClient.isValidModel(provider.model),
              (try? TranslationEndpoint(provider.endpoint)) != nil else { return nil }
        return { [client] question in try await client.answer(question, provider: provider) }
    }

    var availableModels: [String] {
        guard let endpoint = try? TranslationEndpoint(draft.endpoint), endpoint == discoveredEndpoint else { return [] }
        return discovered
    }

    var canTranslate: Bool {
        guard activity == nil, let command, command.unsupportedLanguage == nil, let provider else { return false }
        return TranslationClient.isValidInput(command.text) && TranslationClient.isValidModel(provider.model)
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
    }

    func editDraft(_ field: WritableKeyPath<TranslationProvider, String>, value: String) {
        guard activity == nil else { return }
        var next = draft
        next[keyPath: field] = value
        draft = next
    }

    func saveProvider() {
        guard activity == nil else { return }
        do {
            var proposed = draft
            let name = proposed.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...100).contains(name.utf8.count), !TranslationClient.containsControlCharacters(name) else {
                throw TranslationFailure.invalidProvider
            }
            proposed.name = name
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

    var canRemoveProvider: Bool {
        activity == nil && providers.contains { $0.id == draft.id }
    }

    func removeProvider() {
        guard canRemoveProvider else { return }
        do {
            try client.secrets.remove(provider: draft.id)
            providers.removeAll { $0.id == draft.id }
            let next = provider ?? providers.first ?? TranslationProvider()
            selected = next.id
            draft = next
            resetDraftState()
            output = ""
            copied = false
            store()
            status = .removedProvider
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
        guard canTranslate, let command, let provider else { return }
        output = ""
        copied = false
        start(.translating) { [client] model in
            let result = try await client.translate(command.text, source: command.source, target: command.target,
                                                    provider: provider)
            try Task.checkCancellation()
            guard model.command == command else { return }
            model.output = result
        }
    }

    func setCommand(_ next: TranslationCommand?) {
        guard command != next else { return }
        if activity == .translating { cancel() }
        command = next
        output = ""
        copied = false
        if activity == nil { status = nil }
    }

    func noteCopied() { copied = true }

    func endSettingsSession() {
        if activity == .testing || activity == .listing { cancel() }
        keyInput = ""
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
