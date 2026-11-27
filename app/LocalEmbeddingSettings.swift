import Foundation
import SwiftUI

// MARK: - Loopback Endpoint Validation & Config

/// Validates that an embedding endpoint strictly targets loopback HTTP (`127.0.0.1`, `[::1]`, `localhost`)
/// or a local absolute `unix:///path/to.sock` socket, matching Rust `local_openai::validate_loopback_url`.
func isLoopbackEndpointURL(_ raw: String) -> Bool {
    TextEmbeddingBackendConfig.isLoopbackEndpointURL(raw)
}

struct TextEmbeddingBackendConfig: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case builtin
        case localOpenAI

        var id: Self { self }
    }

    static let defaultsKey = "launcher.textEmbeddingBackend.v1"
    static let defaultBaseURL = "http://127.0.0.1:8000/v1"

    var mode: Mode
    var baseURL: String
    var model: String
    var dimensions: Int?
    var signature: String?

    init(
        mode: Mode = .builtin,
        baseURL: String = Self.defaultBaseURL,
        model: String = "",
        dimensions: Int? = nil,
        signature: String? = nil
    ) {
        self.mode = mode
        self.baseURL = baseURL
        self.model = model
        self.dimensions = dimensions
        self.signature = signature
    }

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasValidModelName: Bool {
        let m = trimmedModel
        return !m.isEmpty && m.utf8.count <= 256 && !m.contains(where: Self.isControlScalar)
    }

    var isValidLocalOpenAI: Bool {
        mode == .localOpenAI && Self.isLoopbackEndpointURL(trimmedBaseURL) && hasValidModelName
    }

    var openAICliArguments: [String] {
        guard isValidLocalOpenAI else { return [] }
        return ["--openai-url", trimmedBaseURL, "--openai-model", trimmedModel]
    }

    static func load(from defaults: UserDefaults?) -> TextEmbeddingBackendConfig {
        guard let data = defaults?.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(TextEmbeddingBackendConfig.self, from: data) else {
            return TextEmbeddingBackendConfig()
        }
        return decoded
    }

    func save(to defaults: UserDefaults?) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func isLoopbackEndpointURL(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.contains(where: isControlScalar),
              !value.contains("?"), !value.contains("#"), !value.contains("@") else {
            return false
        }

        let lower = value.lowercased()
        if lower.hasPrefix("unix://") {
            let path = String(value.dropFirst("unix://".count))
            guard path.hasPrefix("/"), path.count > 1,
                  !path.split(separator: "/").contains(where: { $0 == ".." }) else {
                return false
            }
            return true
        }

        guard let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), scheme == "http",
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let host = parts.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if let port = parts.port, !(1...65_535).contains(port) {
            return false
        }
        // Reject malformed empty ports such as "http://127.0.0.1:/v1".
        if let afterScheme = value.range(of: "://")?.upperBound {
            let authority = String(value[afterScheme...].prefix(while: { $0 != "/" }))
            if authority.hasSuffix(":") { return false }
        }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    private static func isControlScalar(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

// MARK: - Text Embedding Engine Card

struct TextEmbeddingEngineCard: View {
    @ObservedObject var model: Launcher
    @ObservedObject var assets: GemmaAssetManager
    let onGemmaInstalled: (GemmaComponent) -> Void

    @State private var draft = TextEmbeddingBackendConfig()
    @State private var discoveredModels: [String] = []
    @State private var fetchingModels = false
    @State private var testingConnection = false
    @State private var fetchError: String?
    @State private var verificationResult: VerificationResult?

    private struct VerificationResult: Equatable {
        let baseURL: String
        let model: String
        let succeeded: Bool
        let dimensions: Int?
        let signature: String?
        let message: String
    }

    private var urlValid: Bool {
        TextEmbeddingBackendConfig.isLoopbackEndpointURL(draft.baseURL)
    }

    private var activeMatchesDraft: Bool {
        let saved = model.textEmbeddingBackend
        return saved.mode == draft.mode
            && saved.trimmedBaseURL == draft.trimmedBaseURL
            && saved.trimmedModel == draft.trimmedModel
    }

    private var currentVerification: VerificationResult? {
        guard let verificationResult,
              verificationResult.baseURL == draft.trimmedBaseURL,
              verificationResult.model == draft.trimmedModel else {
            return nil
        }
        return verificationResult
    }

    private var canApplyLocalOpenAI: Bool {
        draft.isValidLocalOpenAI && !testingConnection && !fetchingModels && !activeMatchesDraft
    }

    private var canSwitchToBuiltin: Bool {
        draft.mode == .builtin && model.textEmbeddingBackend.mode != .builtin
    }

    var body: some View {
        LumenSettingsCard(
            title: model.t("文本语义引擎", "Text Embedding Engine"),
            icon: "cpu",
            trailing: { headerStatusPill }
        ) {
            modeSelector

            LumenSettingsHairline()

            switch draft.mode {
            case .builtin:
                builtinBody
            case .localOpenAI:
                localOpenAIBody
            }
        }
        .onAppear {
            syncFromModel()
        }
        .onChange(of: model.textEmbeddingBackend) { oldValue, newValue in
            if draft.mode == oldValue.mode && draft.trimmedBaseURL == oldValue.trimmedBaseURL
                && draft.trimmedModel == oldValue.trimmedModel {
                draft = newValue
            }
        }
    }

    // MARK: - Header Pill

    @ViewBuilder private var headerStatusPill: some View {
        let active = model.textEmbeddingBackend
        switch active.mode {
        case .builtin:
            switch model.localModelState {
            case .ready:
                LumenStatusPill(text: model.t("Gemma 2 就绪", "Gemma 2 Ready"), color: SettingsTheme.green)
            case .checking:
                LumenStatusPill(text: model.t("正在校验…", "Verifying…"), color: SettingsTheme.amber)
            case .available:
                LumenStatusPill(text: model.t("已安装", "Installed"), color: SettingsTheme.green)
            case .unavailable, .unchecked:
                if assets.textInstalled {
                    LumenStatusPill(text: model.t("已安装", "Installed"), color: SettingsTheme.green)
                } else {
                    LumenStatusPill(text: model.t("未安装", "Not Installed"), color: SettingsTheme.textTertiary)
                }
            }
        case .localOpenAI:
            if let verified = currentVerification, verified.succeeded {
                let label = verified.dimensions.map { model.t("已验证 · \($0)d", "Verified · \($0)d") }
                    ?? model.t("已验证", "Verified")
                LumenStatusPill(text: label, color: SettingsTheme.green)
            } else if model.localModelState == .ready {
                let label = active.dimensions.map { model.t("已连通 · \($0)d", "Ready · \($0)d") }
                    ?? model.t("已连通", "Ready")
                LumenStatusPill(text: label, color: SettingsTheme.green)
            } else if model.localModelState == .checking {
                LumenStatusPill(text: model.t("正在检测…", "Checking…"), color: SettingsTheme.amber)
            } else if case .unavailable = model.localModelState {
                LumenStatusPill(text: model.t("连接未就绪", "Unavailable"), color: SettingsTheme.red)
            } else {
                LumenStatusPill(text: model.t("本机服务", "Local Server"), color: SettingsTheme.amber)
            }
        }
    }

    // MARK: - Segmented Backend Selector

    private var modeSelector: some View {
        HStack(spacing: 3) {
            modeOption(.builtin, title: model.t("内置 Gemma 2", "Built-in Gemma 2"),
                       identifier: "settings.embedding.mode.builtin")
            modeOption(.localOpenAI, title: model.t("本机服务 (oMLX / Ollama)", "Local Server (oMLX / Ollama)"),
                       identifier: "settings.embedding.mode.localOpenAI")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                .fill(SettingsTheme.wellBackground)
        )
    }

    private func modeOption(_ mode: TextEmbeddingBackendConfig.Mode, title: String, identifier: String) -> some View {
        let selected = draft.mode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                draft.mode = mode
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? SettingsTheme.navActiveTitle : SettingsTheme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: SettingsTheme.cornerSM, style: .continuous)
                        .fill(selected ? SettingsTheme.navActiveBackground : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Built-in Gemma 2

    @ViewBuilder private var builtinBody: some View {
        GemmaAssetSettings(launcher: model, assets: assets, scope: .textOnly, installed: onGemmaInstalled)
        if canSwitchToBuiltin {
            LumenSettingsWell {
                HStack(spacing: 10) {
                    Text(model.t("当前文档索引正在使用本机服务。应用配置后将切换回内置 Gemma 2。",
                                 "Document search currently uses a local server. Apply to switch back to built-in Gemma 2."))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(model.t("应用配置", "Apply")) {
                        var next = draft
                        next.mode = .builtin
                        model.applyTextEmbeddingBackend(next)
                    }
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .accessibilityIdentifier("settings.embedding.apply")
                }
            }
        }
    }

    // MARK: - Local OpenAI Endpoint

    @ViewBuilder private var localOpenAIBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Quick presets
            HStack(spacing: 8) {
                Text(model.t("快速预设", "PRESETS").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(SettingsTheme.textTertiary)
                presetChip("oMLX (:8000)", url: "http://127.0.0.1:8000/v1")
                presetChip("Ollama (:11434)", url: "http://127.0.0.1:11434/v1")
                Spacer()
            }

            // Endpoint URL
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t("服务端点（仅本机回环）", "ENDPOINT URL (LOOPBACK ONLY)").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(SettingsTheme.textTertiary)
                HStack(spacing: 8) {
                    TextField(
                        model.t("服务端点", "Endpoint URL"),
                        text: $draft.baseURL,
                        prompt: Text(verbatim: "http://127.0.0.1:8000/v1")
                    )
                    .lumenWellField()
                    .accessibilityIdentifier("settings.embedding.openai-url")

                    Button(model.t("获取模型", "Fetch Models")) {
                        fetchModels()
                    }
                    .buttonStyle(LumenSecondaryButtonStyle())
                    .disabled(!urlValid || fetchingModels || testingConnection)
                    .accessibilityIdentifier("settings.embedding.fetch-models")
                }
                if !draft.trimmedBaseURL.isEmpty && !urlValid {
                    Text(model.t(
                        "仅允许本机回环 HTTP（127.0.0.1、localhost、[ ::1 ]）或 unix:///abs/path.sock；禁止 HTTPS 与局域网/公网地址。",
                        "Loopback HTTP only (http://127.0.0.1, localhost, [::1]) or unix:///abs/path.sock. HTTPS and remote hosts are rejected."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Model ID + discovered menu
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.t("嵌入模型 ID", "EMBEDDING MODEL ID").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(SettingsTheme.textTertiary)
                    Spacer()
                    if !discoveredModels.isEmpty {
                        Menu(model.t("已发现 \(discoveredModels.count) 个模型", "\(discoveredModels.count) Discovered")) {
                            ForEach(discoveredModels, id: \.self) { id in
                                Button {
                                    draft.model = id
                                } label: {
                                    Text(verbatim: id)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsTheme.amber)
                    }
                }
                TextField(
                    model.t("模型名称", "Model ID"),
                    text: $draft.model,
                    prompt: Text(verbatim: "text-embedding-3-small / bge-m3 / nomic-embed-text")
                )
                .lumenWellField()
                .accessibilityIdentifier("settings.embedding.openai-model")
            }

            if let fetchError {
                Text(fetchError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let verification = currentVerification {
                HStack(spacing: 8) {
                    LumenStatusPill(
                        text: verification.succeeded
                            ? (verification.dimensions.map { model.t("已验证 · \($0) 维", "Verified · \($0)d") }
                               ?? model.t("已验证", "Verified"))
                            : model.t("验证失败", "Failed"),
                        color: verification.succeeded ? SettingsTheme.green : SettingsTheme.red
                    )
                    Text(verification.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(verification.succeeded ? SettingsTheme.textSecondary : SettingsTheme.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Actions
            HStack(spacing: 8) {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 6) {
                        if testingConnection {
                            ProgressView().controlSize(.mini)
                        }
                        Text(model.t("测试连接", "Test Connection"))
                    }
                }
                .buttonStyle(LumenSecondaryButtonStyle())
                .disabled(!draft.isValidLocalOpenAI || testingConnection || fetchingModels)
                .accessibilityIdentifier("settings.embedding.test")

                if fetchingModels {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button(model.t("应用配置", "Apply")) {
                    applyDraft()
                }
                .buttonStyle(LumenPrimaryButtonStyle())
                .disabled(!canApplyLocalOpenAI && currentVerification?.succeeded != true)
                .accessibilityIdentifier("settings.embedding.apply")
            }

            // Privacy & decoupling explanation
            LumenSettingsWell(padding: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.amber)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    Text(model.t(
                        "仅连接本机回环地址（127.0.0.1 / localhost / [::1] / unix://），文档正文绝不离开本机。如需鉴权请设置环境变量 LUMEN_EMBEDDING_API_KEY。以文搜图仍独立由内置 Gemma 2 多模态模型驱动。",
                        "Strictly loopback-only (127.0.0.1, localhost, [::1], or unix://) so document text never leaves this Mac. Set LUMEN_EMBEDDING_API_KEY in the environment if your server requires auth. Image search remains independently powered by built-in Gemma 2."
                    ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func presetChip(_ title: String, url: String) -> some View {
        let selected = draft.trimmedBaseURL == url
        return Button(title) {
            draft.baseURL = url
            fetchError = nil
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? SettingsTheme.amber : SettingsTheme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(selected ? SettingsTheme.amber.opacity(0.14) : SettingsTheme.wellBackground)
        )
        .overlay(
            Capsule().strokeBorder(selected ? SettingsTheme.amber.opacity(0.35) : SettingsTheme.wellBorder, lineWidth: 0.75)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Actions

    private func syncFromModel() {
        let saved = model.textEmbeddingBackend
        draft = saved
    }

    private func fetchModels() {
        let targetURL = draft.trimmedBaseURL
        guard TextEmbeddingBackendConfig.isLoopbackEndpointURL(targetURL) else { return }
        fetchingModels = true
        fetchError = nil
        Task { @MainActor in
            let result = await model.fetchOpenAIEmbeddingModels(url: targetURL)
            fetchingModels = false
            switch result {
            case .success(let models):
                discoveredModels = models
                if draft.trimmedModel.isEmpty, let first = models.first {
                    draft.model = first
                }
                if models.isEmpty {
                    fetchError = model.t("服务未返回可用模型。", "The server returned no models.")
                }
            case .failure(let error):
                discoveredModels = []
                fetchError = error.detail
            }
        }
    }

    private func testConnection() {
        let targetURL = draft.trimmedBaseURL
        let targetModel = draft.trimmedModel
        guard draft.isValidLocalOpenAI else { return }
        testingConnection = true
        fetchError = nil
        Task { @MainActor in
            let result = await model.verifyOpenAIEmbeddingEndpoint(url: targetURL, model: targetModel)
            testingConnection = false
            switch result {
            case .success(let status):
                if status.available && status.verified {
                    draft.dimensions = status.dimensions
                    draft.signature = status.signature
                    let sigNote = status.signature ?? targetModel
                    verificationResult = VerificationResult(
                        baseURL: targetURL,
                        model: targetModel,
                        succeeded: true,
                        dimensions: status.dimensions,
                        signature: status.signature,
                        message: model.t("连通成功（\(sigNote)）。点击「应用配置」开始使用。",
                                         "Connected (\(sigNote)). Click Apply to activate.")
                    )
                } else {
                    let detail = status.diagnostic ?? model.t("端点未通过验证。", "Endpoint verification failed.")
                    verificationResult = VerificationResult(
                        baseURL: targetURL,
                        model: targetModel,
                        succeeded: false,
                        dimensions: nil,
                        signature: nil,
                        message: detail
                    )
                }
            case .failure(let error):
                verificationResult = VerificationResult(
                    baseURL: targetURL,
                    model: targetModel,
                    succeeded: false,
                    dimensions: nil,
                    signature: nil,
                    message: error.detail
                )
            }
        }
    }

    private func applyDraft() {
        guard draft.isValidLocalOpenAI else { return }
        var next = TextEmbeddingBackendConfig(
            mode: .localOpenAI,
            baseURL: draft.trimmedBaseURL,
            model: draft.trimmedModel,
            dimensions: currentVerification?.succeeded == true ? currentVerification?.dimensions : nil,
            signature: currentVerification?.succeeded == true ? currentVerification?.signature : nil
        )
        if next.dimensions == nil && model.textEmbeddingBackend.trimmedBaseURL == next.baseURL
            && model.textEmbeddingBackend.trimmedModel == next.model {
            next.dimensions = model.textEmbeddingBackend.dimensions
            next.signature = model.textEmbeddingBackend.signature
        }
        model.applyTextEmbeddingBackend(next)
    }
}
