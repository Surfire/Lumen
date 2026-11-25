import SwiftUI

@MainActor
struct TranslationPanel: View {
    @AppStorage("language") private var language = "system"
    @StateObject private var model: TranslationPanelModel

    init() { self.init(model: TranslationPanelModel()) }

    init(model: TranslationPanelModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("翻译", "Translate")).font(.title2.weight(.semibold))
                Spacer()
                Picker(t("提供商", "Provider"), selection: Binding(
                    get: { model.selected }, set: { model.choose($0) }
                )) {
                    ForEach(model.providers) { provider in
                        Text(verbatim: provider.name).tag(provider.id)
                    }
                }
                .disabled(model.activity != nil)
            }
            if let provider = model.provider {
                destination(provider)
                    .accessibilityIdentifier("translation-destination")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editor
                    DisclosureGroup(t("模型和提供商设置", "Model & Provider Settings"),
                                    isExpanded: $model.showSettings) {
                        settings
                            .padding(.top, 10)
                    }
                }
                .padding(.trailing, 4)
            }
            if let activity = model.activity {
                HStack {
                    ProgressView(activityLabel(activity)).controlSize(.small)
                    Button(t("取消", "Cancel"), action: model.cancel)
                        .accessibilityIdentifier("translation-cancel")
                }
            } else if let status = model.status {
                Text(statusMessage(status))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("translation-status")
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 495)
        .onDisappear {
            model.cancel()
            model.keyInput = ""
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 15) {
                Picker(t("源语言", "Source"), selection: $model.source) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(language.name(chinese: zh)).tag(language)
                    }
                }
                Picker(t("目标语言", "Target"), selection: $model.target) {
                    ForEach(TranslationLanguage.allCases.filter { $0 != .automatic }) { language in
                        Text(language.name(chinese: zh)).tag(language)
                    }
                }
            }
            .disabled(model.activity != nil)
            Text(t("要翻译的文本", "Text to translate")).font(.callout.weight(.semibold))
            TextEditor(text: $model.input)
                .font(.body)
                .frame(height: 112)
                .border(.quaternary)
                .disabled(model.activity != nil)
                .accessibilityLabel(t("要翻译的文本", "Text to translate"))
                .accessibilityIdentifier("translation-input")
            HStack {
                Button(t("翻译", "Translate"), action: model.translate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canTranslate)
                    .accessibilityIdentifier("translation-submit")
                Spacer()
                if model.source == model.target {
                    Text(t("请选择不同的源语言和目标语言。", "Choose different source and target languages."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.input.utf8.count > 16_384 {
                    Text(t("文本超过 16,384 字节。", "Text exceeds 16,384 bytes."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.output.isEmpty {
                GroupBox(t("译文", "Translation")) {
                    Text(verbatim: model.output)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("translation-output")
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(t("新建提供商", "New Provider"), action: model.newProvider)
                Button(t("恢复已保存设置", "Restore Saved Settings")) { model.choose(model.selected) }
                    .disabled(model.draft == model.provider && model.keyInput.isEmpty)
            }
            field(t("名称", "Name"), text: $model.draft.name, identifier: "translation-provider-name")
            field(t("API 基址", "API Base URL"), text: $model.draft.endpoint,
                  identifier: "translation-provider-url")
            field(t("模型 ID", "Model ID"), text: $model.draft.model, identifier: "translation-provider-model")
            if !model.availableModels.isEmpty {
                Menu(t("使用发现的模型", "Use a Discovered Model")) {
                    ForEach(model.availableModels, id: \.self) { name in
                        Button { model.draft.model = name } label: { Text(verbatim: name) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(t("API 密钥（可选）", "API Key (optional)"))
                SecureField(t("留空保留已保存密钥", "Leave blank to keep the saved key"), text: $model.keyInput)
                    .accessibilityIdentifier("translation-provider-key")
            }
            if let endpoint = try? TranslationEndpoint(model.draft.endpoint) {
                Text(t("连接测试和模型列表将请求 ", "Test and model discovery will contact ")
                     + endpoint.url.absoluteString)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button(t("测试连接", "Test Connection")) { model.checkProvider(listModels: false) }
                    .accessibilityIdentifier("translation-test-connection")
                Button(t("列出模型", "List Models")) { model.checkProvider(listModels: true) }
                    .accessibilityIdentifier("translation-list-models")
                Spacer()
                Button(t("移除 API 密钥", "Remove API Key"), action: model.removeKey)
                    .disabled(!model.canRemoveKey)
                Button(t("保存提供商", "Save Provider"), action: model.saveProvider)
                    .accessibilityIdentifier("translation-save-provider")
            }
        }
        .disabled(model.activity != nil)
    }

    private func field(_ title: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(title, text: text)
                .accessibilityIdentifier(identifier)
        }
    }

    private func destination(_ provider: TranslationProvider) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t("发送至", "Sends To")).font(.callout.weight(.semibold))
            Text(verbatim: provider.endpoint).textSelection(.enabled)
            Text(provider.model.isEmpty ? t("未选择模型。请在设置中填写模型或列出模型。", "Set a model or list models in settings.")
                 : t("模型 ", "Model ") + provider.model)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func activityLabel(_ activity: TranslationPanelModel.Activity) -> String {
        switch activity {
        case .translating: t("正在翻译…", "Translating…")
        case .testing: t("正在测试连接…", "Testing connection…")
        case .listing: t("正在获取模型…", "Listing models…")
        }
    }

    private func statusMessage(_ status: TranslationPanelModel.Status) -> String {
        switch status {
        case .saved: t("已保存提供商。", "Provider saved.")
        case .removedKey: t("已移除 API 密钥。", "API key removed.")
        case .connected: t("已连通模型接口。", "The model endpoint responded.")
        case .models(let count): t("发现 \(count) 个模型。", "Found \(count) models.")
        case .canceled: t("已取消。", "Canceled.")
        case .failure(let failure): failure.message(chinese: zh)
        }
    }

    private var zh: Bool {
        language == "zh" || (language == "system" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    }

    private func t(_ cn: String, _ en: String) -> String { zh ? cn : en }
}
