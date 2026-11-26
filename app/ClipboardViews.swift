import AppKit
import SwiftUI

@MainActor
struct ClipboardHistoryView: View {
    static let height: CGFloat = 320

    @ObservedObject var commands: LauncherCommands
    @ObservedObject var clipboard: ClipboardManager
    let chinese: Bool
    let select: (Int64) -> Void
    let copy: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(t("剪贴板历史", "Clipboard History"), systemImage: "clipboard").font(.headline)
                Spacer()
                if !clipboard.enabled {
                    Button(t("启用记录…", "Enable Capture…"), action: openSettings).buttonStyle(.borderless)
                }
                ClipboardClearButton(clipboard: clipboard, chinese: chinese, short: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            if clipboard.failed {
                Text(t("无法访问剪贴板历史。", "Could not access clipboard history."))
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            if commands.clipboardRows.isEmpty {
                Text(emptyMessage).font(.callout).foregroundStyle(.secondary).padding(16)
                Spacer(minLength: 0)
            } else {
                Divider()
                HStack(spacing: 0) {
                    rows.frame(maxWidth: .infinity)
                    Divider()
                    if let item = commands.selectedClipboardItem {
                        ClipboardItemPreview(item: item, clipboard: clipboard, chinese: chinese, copy: copy)
                            .id(item.id)
                            .frame(width: 330)
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if !clipboard.items.isEmpty { return t("没有匹配的记录。", "No matching clips.") }
        return clipboard.enabled
            ? t("暂无记录。复制文本或图片后会出现在这里。", "No clips yet. Text or images you copy will appear here.")
            : t("剪贴板记录已关闭。", "Clipboard capture is off.")
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(commands.clipboardRows) { item in
                        let selected = item.id == commands.clipboardSelection
                        Button { select(item.id) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.text == nil ? "photo" : "text.alignleft")
                                    .frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
                                Text(verbatim: item.text.map { String($0.drop(while: \.isWhitespace).prefix(120)) } ?? t("图片", "Image"))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 8).frame(height: 34)
                            .background(selected ? Color.accentColor.opacity(0.17) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(item.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: commands.clipboardSelection, initial: true) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

@MainActor
private struct ClipboardItemPreview: View {
    let item: ClipboardItem
    let clipboard: ClipboardManager
    let chinese: Bool
    let copy: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.text == nil ? t("图片", "Image") : t("文本", "Text")).font(.headline)
                Spacer()
                Text(item.capturedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: item.sourceAppName ?? item.sourceBundleID ?? t("未知来源", "Unknown source"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(item.sourceBundleID ?? "")
            if let text = item.text {
                LauncherScrollableText(text: text, label: t("剪贴板预览", "Clipboard Preview"),
                                       identifier: "clipboard-text-preview")
                    .frame(maxHeight: .infinity)
            } else {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .accessibilityLabel(t("图片预览", "Image Preview"))
                    } else {
                        Text(t("无法预览", "Preview unavailable")).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { thumbnail = clipboard.thumbnail(id: item.id) }
            }
            HStack {
                Button(t("复制", "Copy"), action: copy)
                Button(item.pinned ? t("取消固定", "Unpin") : t("固定", "Pin")) { clipboard.togglePin(id: item.id) }
                Button(t("删除", "Delete"), role: .destructive) { clipboard.remove(id: item.id) }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

@MainActor
struct ClipboardSettingsView: View {
    @ObservedObject var clipboard: ClipboardManager
    let chinese: Bool

    var body: some View {
        Toggle(t("启用剪贴板历史", "Enable Clipboard History"), isOn: Binding(
            get: { clipboard.enabled }, set: { clipboard.setEnabled($0) }
        ))
        Text(t("文本和图片仅保存在本机。关闭记录不会删除已有历史。",
               "Text and images are kept on this Mac. Turning off capture does not delete existing history."))
            .font(.callout).foregroundStyle(.secondary)
        LabeledContent(t("保留条数", "Retention Limit")) {
            Picker(t("保留条数", "Retention Limit"), selection: Binding(get: { clipboard.limit }, set: { clipboard.setLimit($0) })) {
                ForEach(Array(Set([50, 100, 200, 500, clipboard.limit])).sorted(), id: \.self) { limit in
                    Text(limit.formatted()).tag(limit)
                }
            }
            .labelsHidden()
        }
        Text(t("固定项目不会被自动删除，并计入保留条数。",
               "Pinned clips are never pruned and count toward the limit."))
            .font(.callout).foregroundStyle(.secondary)
        ClipboardClearButton(clipboard: clipboard, chinese: chinese)
        if clipboard.failed {
            Text(t("无法更新剪贴板历史。", "Could not update clipboard history."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

@MainActor
private struct ClipboardClearButton: View {
    @ObservedObject var clipboard: ClipboardManager
    let chinese: Bool
    var short = false
    @State private var confirm = false

    var body: some View {
        Button(short ? t("全部清除…", "Clear All…") : t("清除剪贴板历史…", "Clear Clipboard History…")) { confirm = true }
            .disabled(clipboard.items.isEmpty && !clipboard.failed)
            .confirmationDialog(t("清除全部剪贴板历史（包括固定项目）？", "Clear all clipboard history, including pinned clips?"),
                                isPresented: $confirm, titleVisibility: .visible) {
                Button(t("全部清除", "Clear All"), role: .destructive, action: clipboard.clearAll)
            }
    }

    private func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}
