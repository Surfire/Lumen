import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ClipboardHistoryView: View {
    static let height: CGFloat = 320

    @ObservedObject var commands: LauncherCommands
    @ObservedObject var clipboard: ClipboardManager
    let chinese: Bool
    let select: (Int64) -> Void
    let copy: () -> Void
    let openSettings: () -> Void
    /// Optional hook for opening a full-size preview of an image or file clip.
    var onOpenPreview: ((ClipboardItem) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(t("剪贴板历史", "Clipboard History"), systemImage: "clipboard").font(.headline)
                Spacer()
                if !clipboard.enabled && !commands.clipboardRows.isEmpty {
                    Button(t("开启剪贴板历史", "Enable Clipboard History")) {
                        clipboard.setEnabled(true)
                    }
                    .buttonStyle(.borderless)
                }
                ClipboardClearButton(clipboard: clipboard, chinese: chinese, short: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            if clipboard.failed {
                Text(t("无法访问剪贴板历史。", "Could not access clipboard history."))
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            if commands.clipboardRows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
                    if !clipboard.enabled {
                        HStack(spacing: 10) {
                            Button(t("开启剪贴板历史", "Enable Clipboard History")) {
                                clipboard.setEnabled(true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button(t("剪贴板设置…", "Clipboard Settings…"), action: openSettings)
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(16)
                Spacer(minLength: 0)
            } else {
                Divider()
                HStack(spacing: 0) {
                    rows.frame(maxWidth: .infinity)
                    Divider()
                    if let item = commands.selectedClipboardItem {
                        ClipboardItemPreview(item: item, clipboard: clipboard, chinese: chinese, copy: copy,
                                             onOpenPreview: onOpenPreview)
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
            ? t("暂无记录。复制文本、图片或文件后会出现在这里。", "No clips yet. Text, images, or files you copy will appear here.")
            : t("剪贴板记录已关闭。", "Clipboard capture is off.")
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(commands.clipboardRows) { item in
                        let selected = item.id == commands.clipboardSelection
                        HStack(spacing: 9) {
                            if let path = item.filePath {
                                Image(nsImage: Self.typeIcon(path))
                                    .resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: (path as NSString).lastPathComponent).lineLimit(1)
                                    Text(t("文件", "File")).font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Image(systemName: item.text == nil ? "photo" : "text.alignleft")
                                    .frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
                                Text(verbatim: item.text.map { String($0.drop(while: \.isWhitespace).prefix(120)) } ?? t("图片", "Image"))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 8).frame(height: 34)
                        .background(selected ? Color.accentColor.opacity(0.17) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { clickRow(item.id) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityAction { select(item.id) }
                        .accessibilityAction(named: Text(t("复制", "Copy"))) {
                            select(item.id)
                            copy()
                        }
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

    /// Type-based icon: no filesystem access, so cloud-only paths are never touched.
    static func typeIcon(_ path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private func clickRow(_ id: Int64) {
        select(id)
        // Select on mouseUp without waiting to see if it becomes a double click.
        let event = NSApp.currentEvent
        if event?.type == .leftMouseUp, event?.clickCount == 2 { copy() }
    }

    private func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

@MainActor
private struct ClipboardItemPreview: View {
    let item: ClipboardItem
    let clipboard: ClipboardManager
    let chinese: Bool
    let copy: () -> Void
    var onOpenPreview: ((ClipboardItem) -> Void)? = nil
    @State private var thumbnail: NSImage?
    @State private var loadingThumbnail = true
    @State private var imageCaption: String?
    @State private var filePreview: ClipboardFilePreviewResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.isFile ? t("文件", "File") : (item.isImage ? t("图片", "Image") : t("文本", "Text"))).font(.headline)
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
            } else if let path = item.filePath {
                filePreviewBody(path)
            } else {
                VStack(spacing: 4) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                                .accessibilityLabel(t("图片预览", "Image Preview"))
                        } else if !loadingThumbnail {
                            Text(t("无法预览", "Preview unavailable")).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let imageCaption {
                        Text(verbatim: imageCaption).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .task {
                    thumbnail = await clipboard.loadThumbnail(id: item.id)
                    loadingThumbnail = false
                    // Upgrade the 240 px thumbnail to a crisp preview sized for this pane.
                    if let full = await Self.loadFullImage(store: clipboard.store, id: item.id) {
                        thumbnail = full.image
                        imageCaption = full.caption
                    }
                }
            }
            HStack {
                Button(t("复制", "Copy"), action: copy)
                if item.text == nil, let onOpenPreview {
                    Button(t("预览", "Preview")) { onOpenPreview(item) }
                }
                Button(item.pinned ? t("取消固定", "Unpin") : t("固定", "Pin")) { clipboard.togglePin(id: item.id) }
                Button(t("删除", "Delete"), role: .destructive) { clipboard.remove(id: item.id) }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    @ViewBuilder private func filePreviewBody(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        VStack(alignment: .leading, spacing: 6) {
            Group {
                switch filePreview {
                case nil:
                    ProgressView().controlSize(.small)
                case .image(let image, let sizeLabel, _)?:
                    VStack(spacing: 4) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .accessibilityLabel(t("图片预览", "Image Preview"))
                        Text(verbatim: sizeLabel).font(.caption).foregroundStyle(.secondary)
                    }
                case .text(let text, let isCode, _)?:
                    ScrollView {
                        Text(verbatim: text)
                            .font(isCode ? .system(size: 11.5, design: .monospaced) : .callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel(isCode ? t("代码预览", "Code preview") : t("文本预览", "Text preview"))
                case .thumbnail(let image, let typeName, _)?:
                    VStack(spacing: 4) {
                        Image(nsImage: image ?? ClipboardHistoryView.typeIcon(path)).resizable().interpolation(.high)
                            .scaledToFit().frame(maxHeight: 160)
                        Text(verbatim: typeName).font(.caption).foregroundStyle(.secondary)
                    }
                case .cloudPlaceholder?:
                    notice("icloud.and.arrow.down", t("文件仍在云端，未下载，无法预览", "This file is cloud-only and has not been downloaded"))
                case .missing?:
                    notice("doc.questionmark", t("文件已移动、被删除或无法访问", "The file was moved, deleted, or could not be accessed"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(verbatim: path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let size = fileSize {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: path) {
            filePreview = await MacPreviewRenderer.clipboardFilePreview(at: url)
        }
    }

    private func notice(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2)
            Text(message).font(.callout).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }

    private var fileSize: Int64? {
        switch filePreview {
        case .image(_, _, let bytes)?, .text(_, _, let bytes)?, .thumbnail(_, _, let bytes)?: return bytes > 0 ? bytes : nil
        default: return nil
        }
    }

    nonisolated private static func loadFullImage(store: ClipboardStore, id: Int64) async -> (image: NSImage, caption: String)? {
        await Task.detached(priority: .utility) { () -> (image: NSImage, caption: String)? in
            guard !Task.isCancelled, let data = try? store.image(id: id), let source = ClipboardStore.imageSource(data),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: 800,
                  ] as CFDictionary) else { return nil }
            var caption = "PNG"
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                caption = "\(w) × \(h) · PNG"
            }
            return (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), caption)
        }.value
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
        Text(t("文本、图片和文件路径仅保存在本机。关闭记录不会删除已有历史。",
               "Text, images, and file paths are kept on this Mac. Turning off capture does not delete existing history."))
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
