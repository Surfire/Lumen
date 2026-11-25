import SwiftUI

@MainActor
struct TranslationResultCard: View {
    @ObservedObject var model: TranslationPanelModel
    let command: TranslationCommand
    let chinese: Bool
    let activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "translate").foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(heading)
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityIdentifier("translation-target")
                Spacer()
                if model.activity == .translating {
                    ProgressView().controlSize(.small)
                    Button(t("取消", "Cancel"), action: model.cancel)
                } else if !model.output.isEmpty {
                    Button(t("复制", "Copy"), action: activate)
                        .accessibilityIdentifier("translation-copy")
                } else if model.canTranslate {
                    Button(t("翻译", "Translate"), action: activate)
                        .accessibilityIdentifier("translation-submit")
                }
            }
            if !model.output.isEmpty {
                ScrollView {
                    Text(verbatim: model.output)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("translation-output")
                }
            } else {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("translation-status")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
    }

    private var heading: String {
        if command.unsupportedLanguage != nil || command.text.isEmpty {
            return t("翻译", "Translate")
        }
        let target = command.target.name(chinese: chinese)
        return t("翻译为\(target)", "Translate to \(target)")
    }

    private var message: String {
        if let alias = command.unsupportedLanguage {
            if alias.isEmpty { return t("请指定目标语言，例如 tr:it 你好。", "Specify a target language, for example tr:it 你好.") }
            return t("无法识别目标语言「\(alias)」。请修改语言，或去掉 tr: 后的语言标记来自动判断。",
                     "Unrecognized target “\(alias)”. Edit the language or use tr with your source text for automatic direction.")
        }
        if command.text.isEmpty {
            return t("例如「译 今天下午三点开会」「tr see you tomorrow」或「tr 法 谢谢」。",
                     "Try “译 今天下午三点开会”, “tr see you tomorrow”, or “tr French 谢谢”.")
        }
        if command.text.utf8.count > 16_384 {
            return t("文本超过 16,384 字节。", "Text exceeds 16,384 bytes.")
        }
        if model.activity == .translating { return t("正在翻译…", "Translating…") }
        if model.activity != nil { return t("提供商设置操作进行中。", "A provider settings operation is in progress.") }
        switch model.status {
        case .failure(let failure): return failure.message(chinese: chinese)
        case .canceled: return t("已取消。按回车可重试。", "Canceled. Press Return to retry.")
        default: break
        }
        guard let provider = model.provider, model.canTranslate else {
            return t("请在翻译设置中选择提供商和模型。", "Choose a provider and model in Translation Settings.")
        }
        return t("按回车发送至 \(provider.name)。", "Press Return to send to \(provider.name).")
    }

    private func t(_ cn: String, _ en: String) -> String { chinese ? cn : en }
}

@MainActor
struct TranslationSettingsView: View {
    @ObservedObject var model: TranslationPanelModel
    let chinese: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(t("已保存的提供商", "Saved Provider"), selection: Binding(
                get: { model.selected }, set: { model.choose($0) }
            )) {
                if model.providers.isEmpty { Text(t("暂无提供商", "No Saved Providers")).tag(model.selected) }
                ForEach(model.providers) { provider in
                    Text(verbatim: provider.name).tag(provider.id)
                }
            }
            .disabled(model.activity != nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(t("新建提供商", "New Provider"), action: model.newProvider)
                    Button(t("恢复已保存设置", "Restore Saved Settings")) { model.choose(model.selected) }
                        .disabled(model.provider == nil || (model.draft == model.provider && model.keyInput.isEmpty))
                    Button(t("删除提供商", "Delete Provider"), role: .destructive, action: model.removeProvider)
                        .disabled(!model.canRemoveProvider)
                        .accessibilityIdentifier("translation-delete-provider")
                }
                field(t("名称", "Name"), field: \.name, identifier: "translation-provider-name")
                field(t("API 基址", "API Base URL"), field: \.endpoint,
                      identifier: "translation-provider-url")
                field(t("模型 ID", "Model ID"), field: \.model, identifier: "translation-provider-model")
                if !model.availableModels.isEmpty {
                    Menu(t("使用发现的模型", "Use a Discovered Model")) {
                        ForEach(model.availableModels, id: \.self) { name in
                            Button { model.editDraft(\.model, value: name) } label: { Text(verbatim: name) }
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
            if let activity = model.activity, activity != .translating {
                HStack {
                    ProgressView(activityLabel(activity)).controlSize(.small)
                    Button(t("取消", "Cancel"), action: model.cancel)
                }
            } else if let status = model.status, model.activity == nil {
                Text(statusMessage(status))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("translation-settings-status")
            }
        }
    }

    private func field(_ title: String, field: WritableKeyPath<TranslationProvider, String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(title, text: Binding(
                get: { model.draft[keyPath: field] },
                set: { model.editDraft(field, value: $0) }
            ))
                .accessibilityIdentifier(identifier)
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
        case .removedProvider: t("已删除提供商。", "Provider deleted.")
        case .removedKey: t("已移除 API 密钥。", "API key removed.")
        case .connected: t("已连通模型接口。", "The model endpoint responded.")
        case .models(let count): t("发现 \(count) 个模型。", "Found \(count) models.")
        case .canceled: t("已取消。", "Canceled.")
        case .failure(let failure): failure.message(chinese: chinese)
        }
    }

    private func t(_ cn: String, _ en: String) -> String { chinese ? cn : en }
}
