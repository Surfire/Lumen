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

private final class CountingLegacySecrets: TranslationSecrets, @unchecked Sendable {
    private let lock = NSLock()
    var calls = 0
    var result: Result<String?, Error>

    init(result: Result<String?, Error>) {
        self.result = result
    }

    func key(provider: UUID, endpoint: TranslationEndpoint) throws -> String? {
        lock.withLock { calls += 1 }
        return try result.get()
    }

    func save(_ key: String, provider: UUID, endpoint: TranslationEndpoint) {}
    func remove(provider: UUID) {}
}

private func posixPermissions(at url: URL) throws -> UInt16 {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
}

private func verifyLocalTranslationSecrets() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-local-secrets-\(UUID().uuidString)", isDirectory: true)
    let appDir = tempDir.appendingPathComponent("Lumen", isDirectory: true)
    let fileURL = appDir.appendingPathComponent("provider-keys.json")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let endpointA = try TranslationEndpoint("https://api.example.test/v1")
    let endpointB = try TranslationEndpoint("https://other.example.test/v1")
    let providerA = UUID()
    let store = LocalTranslationSecrets(fileURL: fileURL, legacy: nil)
    try store.save("secret-a", provider: providerA, endpoint: endpointA)
    if (try posixPermissions(at: appDir)) & 0o777 != 0o700 { fail("expected 0700 parent directory permissions") }
    if (try posixPermissions(at: fileURL)) & 0o777 != 0o600 { fail("expected 0600 key file permissions") }
    if (try store.key(provider: providerA, endpoint: endpointA)) != "secret-a" { fail("saved local secret not returned") }
    if (try store.key(provider: providerA, endpoint: endpointB)) != nil { fail("endpoint mismatch leaked local secret") }
    let reloaded = LocalTranslationSecrets(fileURL: fileURL, legacy: nil)
    if (try reloaded.key(provider: providerA, endpoint: endpointA)) != "secret-a" { fail("reloaded local secret mismatch") }
    try store.remove(provider: providerA)
    if (try store.key(provider: providerA, endpoint: endpointA)) != nil { fail("removed local secret still present") }

    let providerMigrated = UUID()
    let legacyHit = CountingLegacySecrets(result: .success("legacy-migrated-key"))
    let migratingStore = LocalTranslationSecrets(fileURL: fileURL, legacy: legacyHit)
    if (try migratingStore.key(provider: providerMigrated, endpoint: endpointA)) != "legacy-migrated-key" {
        fail("did not migrate legacy key on first read")
    }
    if legacyHit.calls != 1 { fail("expected exactly 1 legacy lookup during migration") }
    if (try posixPermissions(at: fileURL)) & 0o777 != 0o600 { fail("expected 0600 permissions after migration") }
    let postRestartLegacy = CountingLegacySecrets(result: .failure(TranslationFailure.keychain))
    let restartedStore = LocalTranslationSecrets(fileURL: fileURL, legacy: postRestartLegacy)
    if (try restartedStore.key(provider: providerMigrated, endpoint: endpointA)) != "legacy-migrated-key" {
        fail("migrated key lost after restart")
    }
    if postRestartLegacy.calls != 0 { fail("restarted store must not re-query legacy keychain") }

    let providerDenied = UUID()
    let legacyDenied = CountingLegacySecrets(result: .failure(TranslationFailure.keychain))
    let deniedStore = LocalTranslationSecrets(fileURL: fileURL, legacy: legacyDenied)
    if (try deniedStore.key(provider: providerDenied, endpoint: endpointA)) != nil {
        fail("legacy error should downgrade to nil instead of throwing")
    }
    if (try deniedStore.key(provider: providerDenied, endpoint: endpointA)) != nil || legacyDenied.calls != 1 {
        fail("denied legacy provider re-prompted on second read")
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
        try verifyLocalTranslationSecrets()
        print("PASS: translation model, local 0600 secret store & migration, loopback API, cancel, timeout, redirects")
    }

    @MainActor private static func idle(_ model: TranslationPanelModel) async throws {
        for _ in 0..<300 {
            if model.activity == nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fail("model did not return to idle")
    }
}

private func expect(_ satisfied: Bool, _ message: String) {
    if !satisfied { fail(message) }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
