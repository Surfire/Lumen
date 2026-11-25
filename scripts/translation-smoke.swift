import Foundation

private final class FixtureSecrets: TranslationSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: (String, TranslationEndpoint)] = [:]

    func key(provider: UUID, endpoint: TranslationEndpoint) -> String? {
        lock.withLock {
            guard let (key, savedEndpoint) = values[provider], savedEndpoint == endpoint else { return nil }
            return key
        }
    }

    func save(_ key: String, provider: UUID, endpoint: TranslationEndpoint) {
        lock.withLock { values[provider] = (key, endpoint) }
    }

    func remove(provider: UUID) {
        lock.withLock { _ = values.removeValue(forKey: provider) }
    }
}

@main
struct TranslationSmoke {
    @MainActor static func main() async throws {
        let base = CommandLine.arguments[1]
        let secrets = FixtureSecrets()
        let model = TranslationPanelModel(defaults: nil, client: .init(secrets: secrets, timeout: 2))
        _ = TranslationSettingsView(model: model, chinese: false)
        expect(model.provider?.endpoint == "http://127.0.0.1:8000/v1", "local preset")
        expect(!model.canTranslate && model.activity == nil, "no startup request or automatic fallback")

        let fixture = try TranslationEndpoint(base + "/fixture/v1")
        let command = TranslationCommand.parse("tr A synthetic sentence.")!
        model.setCommand(command)
        model.editDraft(\.endpoint, value: fixture.url.absoluteString)
        model.editDraft(\.name, value: "Synthetic oMLX")
        model.keyInput = "synthetic-test-key"
        model.checkProvider(listModels: false)
        try await idle(model)
        expect(model.status == .connected && model.availableModels.isEmpty, "explicit connection test")
        expect(secrets.key(provider: model.draft.id, endpoint: fixture) == nil, "testing never saves the draft key")

        model.checkProvider(listModels: true)
        try await idle(model)
        expect(model.availableModels == ["fixture-chat"], "model discovery")
        model.editDraft(\.model, value: "fixture-chat")
        model.saveProvider()
        let first = model.selected
        expect(model.status == .saved && model.keyInput.isEmpty, "save and clear the editor secret")
        model.translate()
        try await idle(model)
        expect(model.output == "一句合成示例。", "translation result")

        model.editDraft(\.endpoint, value: base + "/changed/v1")
        expect(!model.canRemoveKey && model.availableModels.isEmpty, "scope credentials and discovery to the endpoint")
        model.saveProvider()
        model.translate()
        try await idle(model)
        expect(model.output == "未发送旧密钥。", "endpoint change never forwards the old key")

        model.newProvider()
        model.editDraft(\.name, value: "Another Provider")
        model.editDraft(\.endpoint, value: base + "/other/v1")
        model.editDraft(\.model, value: "other-chat")
        model.saveProvider()
        expect(model.providers.count == 2 && model.selected != first, "independent named profiles")
        model.translate()
        try await idle(model)
        expect(model.output == "另一个模型。", "the chosen profile supplies its own model and endpoint")
        model.choose(first)
        expect(model.provider?.model == "fixture-chat", "switching preserves each provider model")

        model.editDraft(\.endpoint, value: base + "/redirect/v1")
        model.checkProvider(listModels: true)
        try await idle(model)
        expect(model.status == .failure(.redirected), "reject server redirects")
        model.editDraft(\.endpoint, value: base + "/denied/v1")
        model.checkProvider(listModels: true)
        try await idle(model)
        expect(model.status == .failure(.http(401)), "sanitized unauthorized error")

        model.editDraft(\.endpoint, value: base + "/slow/v1")
        model.saveProvider()
        model.translate()
        try await Task.sleep(nanoseconds: 120_000_000)
        model.cancel()
        try await Task.sleep(nanoseconds: 550_000_000)
        expect(model.status == .canceled && model.output.isEmpty, "cancellation ignores late replies")
        let impatient = TranslationClient(secrets: secrets, timeout: 0.15)
        do {
            _ = try await impatient.translate(command.text, source: command.source, target: command.target,
                                              provider: model.draft)
            fail("timeout should fail")
        } catch let error as TranslationFailure {
            expect(error == .timeout, "clean timeout")
        }

        for value in ["http://example.test/v1", "http://127.0.0.1:8000/v1?token=test",
                      "https://user@provider.test/v1", "https://provider.test/v1#fragment"] {
            expect((try? TranslationEndpoint(value)) == nil, "reject ambiguous or unsafe base URL")
        }
        let ipv6 = try TranslationEndpoint("http://[::1]:8000/v1")
        expect(ipv6.url.absoluteString == "http://[::1]:8000/v1", "IPv6 loopback")
        let localhost = try TranslationEndpoint("http://localhost:8000")
        expect(localhost.url.absoluteString == "http://127.0.0.1:8000/v1", "numeric loopback preset alias")
        print("PASS: translation model, provider setup, Keychain boundary, loopback API, cancel, timeout, redirects")
    }

    @MainActor private static func idle(_ model: TranslationPanelModel) async throws {
        for _ in 0..<300 {
            if model.activity == nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fail("model did not return to idle")
    }

    private static func expect(_ satisfied: Bool, _ message: String) {
        if !satisfied { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
