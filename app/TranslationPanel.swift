import AppKit
import SwiftUI

@MainActor
struct TranslationPanel: View {
    @ObservedObject var model: TranslationPanelModel
    var chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    var back: () -> Void = {}
    var openSettings: () -> Void = {}
    var submit: () -> Void = {}
    var copyOutput: (String) -> Void = { _ in }

    private var translating: Bool { model.activity == .translating }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: back) {
                    Label(t("返回搜索", "Back to Search"), systemImage: "chevron.left")
                }
                .accessibilityIdentifier("translation-back")
                Text(t("翻译", "Translate"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .help(t("翻译设置", "Translation Settings"))
                .accessibilityLabel(t("翻译设置", "Translation Settings"))
                .accessibilityIdentifier("translation-open-settings")
            }
            Divider()
            HStack(spacing: 12) {
                Picker(t("提供商", "Provider"), selection: Binding(
                    get: { model.selected }, set: { model.choose($0) }
                )) {
                    ForEach(model.providers) { provider in
                        Text(verbatim: provider.name).tag(provider.id)
                    }
                }
                Picker(t("源语言", "Source"), selection: $model.source) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(language.name(chinese: chinese)).tag(language)
                    }
                }
                Picker(t("目标语言", "Target"), selection: $model.target) {
                    ForEach(TranslationLanguage.allCases.filter { $0 != .automatic }) { language in
                        Text(language.name(chinese: chinese)).tag(language)
                    }
                }
            }
            .disabled(model.activity != nil)
            if let provider = model.provider {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("发送至 ", "Sends to ") + provider.endpoint)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("translation-destination")
                    Text(provider.model.isEmpty
                         ? t("请在设置中选择模型。", "Choose a model in Settings.")
                         : t("模型 ", "Model ") + provider.model)
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(t("要翻译的文本", "Text to Translate")).font(.callout.weight(.semibold))
            TranslationTextEditor(model: model, label: t("要翻译的文本", "Text to Translate"))
                .frame(height: 104)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary).allowsHitTesting(false) }
            HStack {
                Button(t("翻译", "Translate"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canTranslate)
                    .accessibilityIdentifier("translation-submit")
                if translating {
                    ProgressView(t("正在翻译…", "Translating…")).controlSize(.small)
                    Button(t("取消", "Cancel"), action: model.cancel)
                        .accessibilityIdentifier("translation-cancel")
                } else if let message = statusText {
                    Text(message)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("translation-status")
                }
                Spacer()
                Text("⌘↩ " + t("翻译", "Translate") + "    esc " + t("返回", "Back"))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Divider()
            HStack {
                Text(t("译文", "Translation")).font(.callout.weight(.semibold))
                Spacer()
                Button(t("复制译文", "Copy Translation")) { copyOutput(model.output) }
                    .disabled(model.output.isEmpty)
                    .accessibilityIdentifier("translation-copy")
            }
            ScrollView {
                Text(verbatim: model.output)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("translation-output")
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
    }

    private var statusText: String? {
        if model.source == model.target {
            return t("请选择不同的源语言和目标语言。", "Choose different source and target languages.")
        }
        if model.input.utf8.count > 16_384 {
            return t("文本超过 16,384 字节。", "Text exceeds 16,384 bytes.")
        }
        switch model.status {
        case .failure(let failure): return failure.message(chinese: chinese)
        case .canceled: return t("已取消。", "Canceled.")
        default: return nil
        }
    }

    private func t(_ cn: String, _ en: String) -> String { chinese ? cn : en }
}

@MainActor
final class TranslationTextView: NSTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
    }
}

@MainActor
private struct TranslationTextEditor: NSViewRepresentable {
    let model: TranslationPanelModel
    let label: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = TranslationTextView(frame: .zero)
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 6, height: 5)
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.allowsUndo = true
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("translation-input")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? TranslationTextView else { return }
        editor.setAccessibilityLabel(label)
        if !editor.hasMarkedText(), editor.string != model.input { editor.string = model.input }
        editor.isEditable = model.activity != .translating
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: TranslationPanelModel

        init(model: TranslationPanelModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            model.input = editor.string
        }
    }
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
                ForEach(model.providers) { provider in
                    Text(verbatim: provider.name).tag(provider.id)
                }
            }
            .disabled(model.activity != nil)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(t("新建提供商", "New Provider"), action: model.newProvider)
                    Button(t("恢复已保存设置", "Restore Saved Settings")) { model.choose(model.selected) }
                        .disabled(model.draft == model.provider && model.keyInput.isEmpty)
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
        case .removedKey: t("已移除 API 密钥。", "API key removed.")
        case .connected: t("已连通模型接口。", "The model endpoint responded.")
        case .models(let count): t("发现 \(count) 个模型。", "Found \(count) models.")
        case .canceled: t("已取消。", "Canceled.")
        case .failure(let failure): failure.message(chinese: chinese)
        }
    }

    private func t(_ cn: String, _ en: String) -> String { chinese ? cn : en }
}
