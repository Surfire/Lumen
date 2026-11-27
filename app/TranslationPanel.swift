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
                        .accessibilityLabel(t("正在翻译", "Translating"))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("已保存的提供商", "SAVED PROVIDER").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(TranslationTheme.textTertiary)
                    Picker(t("已保存的提供商", "Saved Provider"), selection: Binding(
                        get: { model.selected }, set: { model.choose($0) }
                    )) {
                        if model.providers.isEmpty { Text(t("暂无提供商", "No Saved Providers")).tag(model.selected) }
                        ForEach(model.providers) { provider in
                            Text(verbatim: provider.name).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.activity != nil)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button(t("新建提供商", "New Provider"), action: model.newProvider)
                        .buttonStyle(TranslationSecondaryButtonStyle())
                    Button(t("恢复已保存设置", "Restore")) { model.choose(model.selected) }
                        .buttonStyle(TranslationSecondaryButtonStyle())
                        .disabled(model.provider == nil || (model.draft == model.provider && model.keyInput.isEmpty))
                    Button(t("删除提供商", "Delete"), role: .destructive, action: model.removeProvider)
                        .buttonStyle(TranslationSecondaryButtonStyle(isDestructive: true))
                        .disabled(!model.canRemoveProvider)
                        .accessibilityIdentifier("translation-delete-provider")
                }
                .padding(.top, 14)
            }

            Rectangle()
                .fill(TranslationTheme.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    field(t("名称", "Name"), field: \.name, identifier: "translation-provider-name")
                        .frame(maxWidth: .infinity)
                    field(t("模型 ID", "Model ID"), field: \.model, identifier: "translation-provider-model")
                        .frame(maxWidth: .infinity)
                }

                field(t("API 基址", "API Base URL"), field: \.endpoint, identifier: "translation-provider-url")

                if !model.availableModels.isEmpty {
                    HStack {
                        Menu(t("使用发现的模型 (\(model.availableModels.count))",
                               "Use Discovered Model (\(model.availableModels.count))")) {
                            ForEach(model.availableModels, id: \.self) { name in
                                Button { model.editDraft(\.model, value: name) } label: { Text(verbatim: name) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TranslationTheme.amber)
                        Spacer()
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(t("API 密钥（可选）", "API KEY (OPTIONAL)").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(TranslationTheme.textTertiary)
                    SecureField(t("留空保留已保存密钥", "Leave blank to keep the saved key"), text: $model.keyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(TranslationTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TranslationTheme.well)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TranslationTheme.wellBorder, lineWidth: 0.75)
                                .allowsHitTesting(false)
                        )
                        .accessibilityIdentifier("translation-provider-key")
                }

                if let endpoint = try? TranslationEndpoint(model.draft.endpoint) {
                    Text(t("连接测试和模型列表将请求 ", "Test and model discovery will contact ")
                         + endpoint.url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(TranslationTheme.textTertiary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button(t("测试连接", "Test Connection")) { model.checkProvider(listModels: false) }
                        .buttonStyle(TranslationSecondaryButtonStyle())
                        .accessibilityIdentifier("translation-test-connection")
                    Button(t("列出模型", "List Models")) { model.checkProvider(listModels: true) }
                        .buttonStyle(TranslationSecondaryButtonStyle())
                        .accessibilityIdentifier("translation-list-models")
                    Spacer()
                    Button(t("移除 API 密钥", "Remove Key"), action: model.removeKey)
                        .buttonStyle(TranslationSecondaryButtonStyle())
                        .disabled(!model.canRemoveKey)
                    Button(t("保存提供商", "Save Provider"), action: model.saveProvider)
                        .buttonStyle(TranslationPrimaryButtonStyle())
                        .accessibilityIdentifier("translation-save-provider")
                }
                .padding(.top, 2)
            }
            .disabled(model.activity != nil)

            if let activity = model.activity, activity != .translating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activityLabel(activity))
                        .font(.system(size: 12))
                        .foregroundStyle(TranslationTheme.textSecondary)
                    Spacer()
                    Button(t("取消", "Cancel"), action: model.cancel)
                        .buttonStyle(TranslationSecondaryButtonStyle())
                }
            } else if let status = model.status, model.activity == nil {
                Text(statusMessage(status))
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor(status))
                    .accessibilityIdentifier("translation-settings-status")
            }
        }
    }

    private func field(_ title: String, field: WritableKeyPath<TranslationProvider, String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TranslationTheme.textTertiary)
            TextField(title, text: Binding(
                get: { model.draft[keyPath: field] },
                set: { model.editDraft(field, value: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(TranslationTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TranslationTheme.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(TranslationTheme.wellBorder, lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .accessibilityIdentifier(identifier)
        }
    }

    private func statusColor(_ status: TranslationPanelModel.Status) -> Color {
        switch status {
        case .saved, .connected, .models: return TranslationTheme.green
        case .failure: return TranslationTheme.red
        case .removedProvider, .removedKey, .canceled: return TranslationTheme.textSecondary
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

// Keep TranslationPanel self-contained so smoke-translation.py builds without SettingsDesignSystem.swift.
private enum TranslationTheme {
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        }))
    }

    static let well = dynamic(light: (0.9373, 0.9255, 0.9020, 1.0), dark: (0.1686, 0.1686, 0.1882, 1.0))
    static let wellBorder = dynamic(light: (0.0, 0.0, 0.0, 0.06), dark: (1.0, 1.0, 1.0, 0.065))
    static let amber = dynamic(light: (0.7686, 0.4824, 0.1608, 1.0), dark: (0.8784, 0.5961, 0.2627, 1.0))
    static let green = dynamic(light: (0.1765, 0.5412, 0.3059, 1.0), dark: (0.3216, 0.7686, 0.4824, 1.0))
    static let red = dynamic(light: (0.7882, 0.2314, 0.1961, 1.0), dark: (0.9176, 0.4157, 0.3765, 1.0))
    static let textPrimary = dynamic(light: (0.1098, 0.0980, 0.0902, 1.0), dark: (0.9569, 0.9569, 0.9647, 1.0))
    static let textSecondary = dynamic(light: (0.3412, 0.3255, 0.3059, 1.0), dark: (0.6902, 0.6902, 0.7294, 1.0))
    static let textTertiary = dynamic(light: (0.4706, 0.4431, 0.4235, 1.0), dark: (0.5176, 0.5176, 0.5647, 1.0))
    static let hairline = dynamic(light: (0.0, 0.0, 0.0, 0.075), dark: (1.0, 1.0, 1.0, 0.08))
}

private struct TranslationPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TranslationTheme.amber.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1.0) : 0.42))
            )
            .contentShape(Rectangle())
    }
}

private struct TranslationSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle((isDestructive ? TranslationTheme.red : TranslationTheme.textPrimary).opacity(isEnabled ? 1.0 : 0.45))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TranslationTheme.well.opacity(configuration.isPressed ? 0.72 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(TranslationTheme.wellBorder, lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
    }
}
