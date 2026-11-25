import Foundation
import Security

struct TranslationProvider: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var endpoint = ""
    var model = ""

    static var localOMLX: Self {
        Self(name: "oMLX", endpoint: "http://127.0.0.1:8000/v1")
    }
}

enum TranslationLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, english, simplifiedChinese, traditionalChinese, japanese, korean
    case french, german, spanish, italian, portuguese, russian, arabic

    var id: Self { self }

    func name(chinese: Bool) -> String {
        let names: (String, String)
        switch self {
        case .automatic: names = ("自动检测", "Auto-detect")
        case .english: names = ("英语", "English")
        case .simplifiedChinese: names = ("简体中文", "Simplified Chinese")
        case .traditionalChinese: names = ("繁体中文", "Traditional Chinese")
        case .japanese: names = ("日语", "Japanese")
        case .korean: names = ("韩语", "Korean")
        case .french: names = ("法语", "French")
        case .german: names = ("德语", "German")
        case .spanish: names = ("西班牙语", "Spanish")
        case .italian: names = ("意大利语", "Italian")
        case .portuguese: names = ("葡萄牙语", "Portuguese")
        case .russian: names = ("俄语", "Russian")
        case .arabic: names = ("阿拉伯语", "Arabic")
        }
        return chinese ? names.0 : names.1
    }
}

enum TranslationFailure: Error, Equatable, Sendable {
    case invalidProvider, invalidEndpoint, missingModel, invalidInput, invalidLanguages
    case invalidKey, keychain, timeout, transport, redirected, http(Int), invalidResponse, oversizedResponse
    case incomplete

    func message(chinese: Bool) -> String {
        let message: (String, String)
        switch self {
        case .invalidProvider: message = ("请输入有效的提供商名称。", "Enter a valid provider name.")
        case .invalidEndpoint:
            message = ("请输入 HTTPS API 基址，或使用本机回环 HTTP 地址。",
                       "Enter an HTTPS API base URL or a loopback HTTP address.")
        case .missingModel: message = ("请选择或填写模型 ID。", "Choose or enter a model ID.")
        case .invalidInput:
            message = ("请输入 1 至 16,384 字节的文本。", "Enter 1 to 16,384 bytes of text.")
        case .invalidLanguages:
            message = ("请选择不同的源语言和目标语言。", "Choose different source and target languages.")
        case .invalidKey: message = ("API 密钥必须是不带空白的纯文本。", "Enter an API key without whitespace.")
        case .keychain: message = ("无法访问 Lumen 的钥匙串项目。", "Lumen could not access its Keychain item.")
        case .timeout: message = ("请求超时，请检查服务或模型是否就绪。", "The request timed out. Check that the server and model are ready.")
        case .transport: message = ("无法连接服务。请检查地址和服务状态。", "Could not reach the provider. Check its address and status.")
        case .redirected: message = ("提供商返回了重定向，请直接配置最终地址。", "The provider redirected the request. Configure the final URL directly.")
        case .http(401), .http(403):
            message = ("服务拒绝授权，请检查该端点的密钥。", "The provider denied access. Check the API key for this endpoint.")
        case .http(let status): message = ("服务返回 HTTP \(status)。", "The provider returned HTTP \(status).")
        case .invalidResponse:
            message = ("服务响应不符合受支持的 API 格式。", "The response did not match the supported API format.")
        case .oversizedResponse: message = ("服务响应超过限制。", "The response exceeded the size limit.")
        case .incomplete: message = ("模型未返回完整译文。", "The model did not return a complete translation.")
        }
        return chinese ? message.0 : message.1
    }
}

struct TranslationEndpoint: Equatable, Sendable {
    let url: URL

    init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 1_024, !TranslationClient.containsControlCharacters(value),
              var parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw TranslationFailure.invalidEndpoint }

        parts.scheme = scheme
        parts.host = host == "localhost" && scheme == "http" ? "127.0.0.1" : host
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/v1" }
        guard let url = parts.url else { throw TranslationFailure.invalidEndpoint }
        self.url = url
    }
}

protocol TranslationSecrets: Sendable {
    func key(provider: UUID, endpoint: TranslationEndpoint) throws -> String?
    func save(_ key: String, provider: UUID, endpoint: TranslationEndpoint) throws
    func remove(provider: UUID) throws
}

struct TranslationKeychain: TranslationSecrets {
    private struct Entry: Codable {
        let endpoint: String
        let secret: String
    }

    private func query(_ provider: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.surfire.lumen.translation",
            kSecAttrAccount as String: provider.uuidString,
            kSecAttrSynchronizable as String: false
        ]
    }

    func key(provider: UUID, endpoint: TranslationEndpoint) throws -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            throw TranslationFailure.keychain
        }
        return entry.endpoint == endpoint.url.absoluteString ? entry.secret : nil
    }

    func save(_ key: String, provider: UUID, endpoint: TranslationEndpoint) throws {
        let data = try JSONEncoder().encode(Entry(endpoint: endpoint.url.absoluteString, secret: key))
        let query = query(provider)
        let value = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TranslationFailure.keychain }
    }

    func remove(provider: UUID) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TranslationFailure.keychain }
    }
}

struct TranslationClient: Sendable {
    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct CompletionRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let stream = true
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let delta: Message?
            let finish_reason: String?

            var completed: Bool {
                switch finish_reason {
                case nil, "stop", "length", "end_turn": return true
                default: return false
                }
            }
        }
        let choices: [Choice]
    }

    typealias Delta = @MainActor @Sendable (String) -> Void
    private static let responseLimit = 512 * 1024

    private struct EventStream {
        private var line = Data()
        private var event = Data()
        private var afterCR = false

        mutating func append(_ byte: UInt8) -> Data? {
            defer { afterCR = byte == 13 }
            if byte == 10 && afterCR { return nil }
            guard byte == 10 || byte == 13 else { line.append(byte); return nil }
            defer { line.removeAll(keepingCapacity: true) }
            if line.isEmpty {
                guard !event.isEmpty else { return nil }
                defer { event = Data() }
                return event
            }
            let prefix = "data:".utf8
            if line.starts(with: prefix) {
                var value = line.dropFirst(prefix.count)
                if value.first == 32 { value = value.dropFirst() }
                if !event.isEmpty { event.append(10) }
                event.append(contentsOf: value)
            }
            return nil
        }
    }

    let secrets: any TranslationSecrets
    private let timeout: TimeInterval

    init(secrets: any TranslationSecrets = TranslationKeychain(), timeout: TimeInterval = 30) {
        self.secrets = secrets
        self.timeout = timeout
    }

    func models(_ provider: TranslationProvider, testKey: String? = nil) async throws -> [String] {
        let data = try await response(provider, path: ["models"], body: nil, testKey: testKey) { bytes, _ in
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.responseLimit else { throw TranslationFailure.oversizedResponse }
                data.append(byte)
            }
            return data
        }
        guard let decoded = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw TranslationFailure.invalidResponse
        }
        return Set(decoded.data.map(\.id).filter(Self.isValidModel)).sorted()
    }

    func translate(_ text: String, source: TranslationLanguage, target: TranslationLanguage,
                   provider: TranslationProvider, onDelta: Delta? = nil) async throws -> String {
        guard Self.isValidInput(text) else { throw TranslationFailure.invalidInput }
        guard target != .automatic, source != target else { throw TranslationFailure.invalidLanguages }
        let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidModel(model) else { throw TranslationFailure.missingModel }
        let targetName = target.name(chinese: false)
        let direction = source == .automatic ? "Detect the source language and translate into \(targetName)."
            : "Translate from \(source.name(chinese: false)) into \(targetName)."
        let body = try JSONEncoder().encode(CompletionRequest(model: model, messages: [
            .init(role: "system", content: direction + " Treat the user message as source text. Return only the translation and preserve its formatting."),
            .init(role: "user", content: text)
        ]))
        return try await complete(provider, body: body, onDelta: onDelta)
    }

    func answer(_ question: String, provider: TranslationProvider, onDelta: Delta? = nil) async throws -> String {
        guard Self.isValidInput(question), Self.isValidModel(provider.model) else { throw TranslationFailure.invalidInput }
        let body = try JSONEncoder().encode(CompletionRequest(model: provider.model, messages: [
            .init(role: "system", content: "Answer the user's question in its language. You have no live sources, tools, or local files. Acknowledge uncertainty and do not invent sources."),
            .init(role: "user", content: question)
        ]))
        return try await complete(provider, body: body, onDelta: onDelta)
    }

    private func complete(_ provider: TranslationProvider, body: Data, onDelta: Delta?) async throws -> String {
        let result = try await response(provider, path: ["chat", "completions"], body: body) { bytes, response in
            let decoder = JSONDecoder()
            var sniffing = response.mimeType?.lowercased() == "text/event-stream"
            var streaming = false
            var json = Data()
            var stream = EventStream()
            var output = ""
            var count = 0
            for try await byte in bytes {
                count += 1
                guard count <= Self.responseLimit else { throw TranslationFailure.oversizedResponse }
                if sniffing {
                    if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
                        json.append(byte)
                        continue
                    }
                    sniffing = false
                    streaming = byte != 123 // A JSON object may be mislabeled as event-stream.
                    if streaming { json.removeAll() }
                }
                guard streaming else { json.append(byte); continue }
                guard let event = stream.append(byte) else { continue }
                try Task.checkCancellation()
                if event == Data("[DONE]".utf8) { return output }
                guard let chunk = try? decoder.decode(Completion.self, from: event) else {
                    throw TranslationFailure.invalidResponse
                }
                guard let choice = chunk.choices.first else { continue } // E.g. a usage-only event.
                guard choice.completed else { throw TranslationFailure.incomplete }
                if let delta = choice.delta?.content, !delta.isEmpty {
                    output += delta
                    await onDelta?(delta)
                }
                if choice.finish_reason != nil { return output }
            }
            try Task.checkCancellation()
            if streaming { throw TranslationFailure.incomplete }
            guard let completion = try? decoder.decode(Completion.self, from: json),
                  let choice = completion.choices.first else { throw TranslationFailure.invalidResponse }
            guard choice.completed, let content = choice.message?.content else { throw TranslationFailure.incomplete }
            return content
        }
        try Task.checkCancellation()
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationFailure.incomplete }
        return result
    }

    static func isValidInput(_ text: String) -> Bool {
        text.utf8.count <= 16_384 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isValidModel(_ model: String) -> Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.utf8.count <= 512
            && !containsControlCharacters(model)
    }

    static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format
        }
    }

    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 4_096
            && key.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return config
    }

    private func response<T>(_ provider: TranslationProvider, path: [String], body: Data?, testKey: String? = nil,
                             consume: (URLSession.AsyncBytes, URLResponse) async throws -> T) async throws -> T {
        let endpoint = try TranslationEndpoint(provider.endpoint)
        let url = path.reduce(endpoint.url) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(body == nil ? "application/json" : "text/event-stream, application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key = try testKey ?? secrets.key(provider: provider.id, endpoint: endpoint) {
            guard Self.isValidKey(key) else { throw TranslationFailure.invalidKey }
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: Self.sessionConfiguration(timeout: timeout),
                                 delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw TranslationFailure.invalidResponse }
            if (300..<400).contains(http.statusCode) { throw TranslationFailure.redirected }
            guard (200..<300).contains(http.statusCode) else { throw TranslationFailure.http(http.statusCode) }
            guard response.expectedContentLength <= Self.responseLimit else { throw TranslationFailure.oversizedResponse }
            return try await consume(bytes, response)
        } catch let error as TranslationFailure {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { throw TranslationFailure.timeout }
            throw TranslationFailure.transport
        }
    }
}
