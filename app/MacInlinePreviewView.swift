#if os(macOS)
import SwiftUI

/// Embed as one region below the selected row, or to the right of the same
/// results list on wider layouts. The launcher owns focus, keyboard, and selection.
public struct MacInlinePreviewView: View {
    public enum Language { case simplifiedChinese, english }
    public let state: InlinePreviewState
    private let image: NSImage?
    public let language: Language
    public init(state: InlinePreviewState, image: NSImage?, language: Language) {
        self.state = state
        self.image = image
        self.language = language
    }

    private func label(_ zh: String, _ en: String) -> String {
        switch language {
        case .simplifiedChinese: return zh
        case .english: return en
        }
    }

    public var body: some View {
        Group {
            switch state {
            case .closed:
                EmptyView()
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label("正在加载本地预览", "Loading local preview"))
                }
                .foregroundStyle(.secondary)
            case .downloading(_, let fraction):
                HStack(spacing: 8) {
                    if let fraction {
                        ZStack {
                            Circle().strokeBorder(.quaternary, lineWidth: 2)
                            Circle().inset(by: 1).trim(from: 0, to: fraction)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                        let percent = Int((fraction * 100).rounded())
                        Text(label("正在从云端同步 \(percent)%", "Downloading from cloud \(percent)%"))
                            .monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(label("正在从云端同步…", "Downloading from cloud…"))
                    }
                }
                .foregroundStyle(.secondary)
            case .unavailable(_, let error):
                Label(reason(error), systemImage: "doc.questionmark")
                    .foregroundStyle(.secondary)
            case .ready(_, let content):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let visual = content.visual {
                            switch visual {
                            case .image:
                                bitmap(caption: label("图片预览", "Image preview"), hasEvidence: content.evidence != nil)
                            case .pdf(_, let displayedPage, let isMatchPage):
                                bitmap(caption: isMatchPage
                                    ? label("命中第 \(displayedPage) 页", "Match on page \(displayedPage)")
                                    : label("预览第 \(displayedPage) 页（未定位命中页）", "Page \(displayedPage) preview (match page unknown)"),
                                       hasEvidence: content.evidence != nil)
                            }
                        }
                        if let text = content.text {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(content.isCode ? label("代码预览", "Code preview") : label("文本预览", "Text preview"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(verbatim: text)
                                    .font(content.isCode ? .system(size: 11.5, design: .monospaced) : .callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityIdentifier("lumen-inline-preview-text")
                        }
                        if let evidence = content.evidence {
                            let body = evidence.context ?? evidence.text
                            VStack(alignment: .leading, spacing: 4) {
                                Text(evidence.context != nil
                                    ? (evidence.match == .related
                                        ? label("相关段落上下文", "Related excerpt context")
                                        : label("文字匹配上下文", "Text match context"))
                                    : (evidence.match == .related
                                        ? label("相关片段", "Related excerpt")
                                        : label("文字匹配片段", "Text match excerpt")))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(highlighted(body, evidence: evidence))
                                    .font(.callout)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 380)
            }
        }
        .accessibilityIdentifier("lumen-inline-preview")
    }

    @ViewBuilder private func bitmap(caption: String, hasEvidence: Bool) -> some View {
        if let image {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: hasEvidence ? 192 : 224)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .accessibilityLabel(Text(caption))
        } else {
            Text(label("预览无法解码", "Preview could not be decoded")).foregroundStyle(.secondary)
        }
    }

    private func reason(_ error: PreviewFailure) -> String {
        switch error {
        case .notLocal:
            return label("文件尚未保存在本机", "The file is not available locally.")
        case .missing:
            return label("文件已移动、被删除或无法访问", "The file was moved, deleted, or could not be accessed.")
        case .downloadFailed:
            return label("无法从云端同步此文件", "Could not download this file from the cloud.")
        case .invalidContent:
            return label("这个文件无法内嵌预览", "This file does not support inline preview.")
        case .unavailablePage:
            return label("无法定位命中页，请打开原文件", "The match page is unavailable. Open the original file.")
        case .noExcerpt:
            return label("没有可显示的原文片段", "There is no available source excerpt.")
        }
    }

    private func highlighted(_ body: String, evidence: PreviewEvidence) -> AttributedString {
        var attributed = AttributedString(body)
        let needles: [String]
        if evidence.match == .related {
            let trimmed = (evidence.highlight ?? evidence.text)
                .trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespacesAndNewlines))
            needles = trimmed.isEmpty ? [] : [trimmed]
        } else {
            let raw = evidence.highlight ?? ""
            var terms = raw.split(whereSeparator: \.isWhitespace).map(String.init).filter { term in
                let lower = term.lowercased()
                return !lower.isEmpty && !lower.hasPrefix("kind:") && !lower.hasPrefix("path:")
                    && !lower.hasPrefix("ext:") && !term.hasPrefix("/") && !term.hasPrefix("~/")
            }
            if terms.isEmpty && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                terms = [raw.trimmingCharacters(in: .whitespacesAndNewlines)]
            }
            needles = terms.sorted { $0.count > $1.count }
        }
        for needle in needles {
            var searchStart = body.startIndex
            while searchStart < body.endIndex,
                  let range = body.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: searchStart..<body.endIndex),
                  !range.isEmpty {
                if let attrRange = Range(range, in: attributed) {
                    attributed[attrRange].backgroundColor = Color.accentColor.opacity(0.22)
                    attributed[attrRange].font = .callout.weight(.semibold)
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}
#endif
