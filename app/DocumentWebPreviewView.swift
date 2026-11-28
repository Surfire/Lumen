#if os(macOS)
import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private final class PreviewWKWebView: WKWebView {
    var allowsFirstResponder = false
    override var acceptsFirstResponder: Bool { allowsFirstResponder }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: DocumentWebPreviewContainer?

    init(target: DocumentWebPreviewContainer) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.handleScriptMessage(message)
        }
    }
}

private final class LocalPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let maxLocalImageBytes = 16 * 1024 * 1024
    private let lock = NSLock()
    private var localResources: [String: URL] = [:]
    private var memoryResources: [String: Data] = [:]
    private var memoryMimeTypes: [String: String] = [:]
    private var activeTasks = Set<ObjectIdentifier>()

    func update(
        localResources: [String: URL],
        memoryResources: [String: Data],
        memoryMimeTypes: [String: String]
    ) {
        lock.lock()
        self.localResources = localResources
        self.memoryResources = memoryResources
        self.memoryMimeTypes = memoryMimeTypes
        lock.unlock()
    }

    func clear() {
        lock.lock()
        localResources = [:]
        memoryResources = [:]
        memoryMimeTypes = [:]
        activeTasks.removeAll()
        lock.unlock()
    }

    private func register(_ task: WKURLSchemeTask) -> ObjectIdentifier {
        let id = ObjectIdentifier(task)
        lock.lock()
        activeTasks.insert(id)
        lock.unlock()
        return id
    }

    private func isActive(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        let active = activeTasks.contains(id)
        lock.unlock()
        return active
    }

    private func takeActive(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        let existed = activeTasks.remove(id) != nil
        lock.unlock()
        return existed
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = register(urlSchemeTask)
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme?.lowercased() == "lumen-local",
              let host = requestURL.host?.lowercased() else {
            if takeActive(taskID) {
                urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            }
            return
        }

        let token = requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !token.isEmpty else {
            if takeActive(taskID) {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            }
            return
        }

        if host == "att" {
            lock.lock()
            let data = memoryResources[token]
            let mime = memoryMimeTypes[token] ?? "image/png"
            lock.unlock()
            guard takeActive(taskID) else { return }
            guard let data else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = URLResponse(
                url: requestURL,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            return
        }

        if host == "res" {
            lock.lock()
            let targetURL = localResources[token]
            lock.unlock()
            guard let targetURL else {
                if takeActive(taskID) {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                }
                return
            }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self, self.isActive(taskID) else { return }
                let result = Self.loadResidentImage(at: targetURL)
                DispatchQueue.main.async {
                    guard self.takeActive(taskID) else { return }
                    switch result {
                    case .success(let payload):
                        let response = URLResponse(
                            url: requestURL,
                            mimeType: payload.mimeType,
                            expectedContentLength: payload.data.count,
                            textEncodingName: nil
                        )
                        urlSchemeTask.didReceive(response)
                        urlSchemeTask.didReceive(payload.data)
                        urlSchemeTask.didFinish()
                    case .failure(let error):
                        urlSchemeTask.didFailWithError(error)
                    }
                }
            }
            return
        }

        if takeActive(taskID) {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        _ = takeActive(ObjectIdentifier(urlSchemeTask))
    }

    private struct ImagePayload {
        let data: Data
        let mimeType: String
    }

    private static func loadResidentImage(at url: URL) -> Result<ImagePayload, Error> {
        let ext = url.pathExtension.lowercased()
        guard let utType = UTType(filenameExtension: ext), utType.conforms(to: .image) else {
            return .failure(URLError(.cannotDecodeContentData))
        }
        let mime = utType.preferredMIMEType ?? "application/octet-stream"
        do {
            let data: Data = try LocalFile.withResidentFile(
                url,
                expectedStamp: nil,
                isPending: LocalFile.isUbiquitousPlaceholder
            ) {
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    throw URLError(.fileDoesNotExist)
                }
                defer { try? handle.close() }
                guard let bytes = try? handle.read(upToCount: maxLocalImageBytes + 1),
                      !bytes.isEmpty,
                      bytes.count <= maxLocalImageBytes else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                return bytes
            }
            return .success(ImagePayload(data: data, mimeType: mime))
        } catch {
            return .failure(URLError(.noPermissionsToReadFile))
        }
    }
}

@MainActor
final class DocumentWebPreviewContainer: NSView, WKNavigationDelegate, WKUIDelegate {
    var chinese: Bool {
        didSet { updateMatchBar() }
    }

    private let schemeHandler = LocalPreviewSchemeHandler()
    private let webView: PreviewWKWebView
    private let matchBar = NSVisualEffectView()
    private let matchLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private var matchCount = 0
    private var activeIndex = -1
    private var tornDown = false

    init(chinese: Bool = true) {
        self.chinese = chinese

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = false
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "lumen-local")
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        self.webView = PreviewWKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)

        let trampoline = WeakScriptMessageHandler(target: self)
        config.userContentController.add(trampoline, name: "lumenPreview")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(true, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        configureMatchBar()
        syncWebAppearance()

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),

            matchBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            matchBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureMatchBar() {
        matchBar.translatesAutoresizingMaskIntoConstraints = false
        matchBar.material = .popover
        matchBar.blendingMode = .withinWindow
        matchBar.state = .active
        matchBar.wantsLayer = true
        matchBar.layer?.cornerRadius = 14
        matchBar.layer?.cornerCurve = .continuous
        matchBar.layer?.masksToBounds = true
        matchBar.layer?.backgroundColor = NSColor.clear.cgColor
        matchBar.maskImage = Self.roundedMask(radius: 14)
        matchBar.layer?.borderWidth = 0.5
        matchBar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        matchBar.isHidden = true

        matchLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        matchLabel.textColor = .labelColor
        matchLabel.lineBreakMode = .byTruncatingTail

        configureNavButton(prevButton, symbolName: "chevron.up", fallback: "‹", action: #selector(jumpPrevious))
        configureNavButton(nextButton, symbolName: "chevron.down", fallback: "›", action: #selector(jumpNext))

        let stack = NSStackView(views: [matchLabel, prevButton, nextButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        matchBar.addSubview(stack)
        addSubview(matchBar)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: matchBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: matchBar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: matchBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: matchBar.bottomAnchor),
        ])
    }

    private func configureNavButton(_ button: NSButton, symbolName: String, fallback: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: fallback) {
            button.image = img
            button.imageScaling = .scaleProportionallyDown
        } else {
            button.title = fallback
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncWebAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncWebAppearance()
    }

    private func syncWebAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        webView.underPageBackgroundColor = isDark
            ? NSColor(srgbRed: 0.11, green: 0.118, blue: 0.133, alpha: 1)
            : NSColor.white
        matchBar.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    }

    func load(_ content: RichPreviewContent, interactiveFocus: Bool) {
        guard !tornDown else { return }
        syncWebAppearance()
        webView.allowsFirstResponder = interactiveFocus
        matchCount = 0
        activeIndex = -1
        updateMatchBar()
        schemeHandler.update(
            localResources: content.localResources,
            memoryResources: content.memoryResources,
            memoryMimeTypes: content.memoryMimeTypes
        )
        webView.loadHTMLString(content.html, baseURL: nil)
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lumenPreview")
        schemeHandler.clear()
        matchBar.isHidden = true
    }

    func evaluateVerificationJS(_ script: String) async -> Any? {
        guard !tornDown else { return nil }
        return try? await webView.evaluateJavaScript(script)
    }

    func captureSnapshot() async -> NSImage? {
        guard !tornDown else { return nil }
        let config = WKSnapshotConfiguration()
        if !webView.bounds.isEmpty {
            config.rect = webView.bounds
        }
        guard let webImage = try? await webView.takeSnapshot(configuration: config) else {
            return nil
        }
        layoutSubtreeIfNeeded()
        guard !matchBar.isHidden,
              !matchBar.bounds.isEmpty,
              let barRep = matchBar.bitmapImageRepForCachingDisplay(in: matchBar.bounds) else {
            return webImage
        }
        matchBar.cacheDisplay(in: matchBar.bounds, to: barRep)
        let canvasSize = bounds.isEmpty ? webImage.size : bounds.size
        let combined = NSImage(size: canvasSize)
        combined.lockFocus()
        webImage.draw(in: NSRect(origin: .zero, size: canvasSize))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: matchBar.frame, xRadius: 14, yRadius: 14).addClip()
        barRep.draw(in: matchBar.frame)
        NSGraphicsContext.restoreGraphicsState()
        combined.unlockFocus()
        return combined
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    @objc private func jumpPrevious() {
        guard !tornDown else { return }
        webView.evaluateJavaScript("window.__lumenPreview && window.__lumenPreview.jump(-1)")
    }

    @objc private func jumpNext() {
        guard !tornDown else { return }
        webView.evaluateJavaScript("window.__lumenPreview && window.__lumenPreview.jump(1)")
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        guard !tornDown, message.name == "lumenPreview",
              let body = message.body as? [String: Any] else { return }
        let count = (body["matchCount"] as? NSNumber)?.intValue ?? 0
        let index = (body["activeIndex"] as? NSNumber)?.intValue ?? -1
        matchCount = max(0, count)
        activeIndex = index
        updateMatchBar()
    }

    private func updateMatchBar() {
        guard matchCount > 0 else {
            matchBar.isHidden = true
            return
        }
        let shownIndex = min(max(activeIndex + 1, 1), matchCount)
        matchLabel.stringValue = chinese
            ? "命中 \(shownIndex) / \(matchCount)"
            : "Match \(shownIndex) / \(matchCount)"
        prevButton.isEnabled = matchCount > 1
        nextButton.isEnabled = matchCount > 1
        matchBar.isHidden = false
    }

    // MARK: WKNavigationDelegate & WKUIDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .other {
            if url.absoluteString == "about:blank" || url.scheme?.lowercased() == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
            return
        }
        if navigationAction.navigationType == .linkActivated {
            if let fragment = url.fragment, !fragment.isEmpty,
               (url.scheme?.lowercased() == "about" || url.absoluteString.hasPrefix("about:blank#")) {
                if let encoded = try? JSONSerialization.data(withJSONObject: [fragment]),
                   let json = String(data: encoded, encoding: .utf8) {
                    webView.evaluateJavaScript("window.__lumenPreview && window.__lumenPreview.scrollToHash((\(json))[0])")
                }
                decisionHandler(.cancel)
                return
            }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

struct DocumentWebPreviewRepresentable: NSViewRepresentable {
    let content: RichPreviewContent
    let chinese: Bool
    var onContainerReady: ((DocumentWebPreviewContainer?) -> Void)? = nil

    init(
        content: RichPreviewContent,
        chinese: Bool,
        onContainerReady: ((DocumentWebPreviewContainer?) -> Void)? = nil
    ) {
        self.content = content
        self.chinese = chinese
        self.onContainerReady = onContainerReady
    }

    final class Coordinator {
        var lastContent: RichPreviewContent?
        var onContainerReady: ((DocumentWebPreviewContainer?) -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DocumentWebPreviewContainer {
        let container = DocumentWebPreviewContainer(chinese: chinese)
        context.coordinator.lastContent = content
        context.coordinator.onContainerReady = onContainerReady
        container.load(content, interactiveFocus: false)
        onContainerReady?(container)
        return container
    }

    func updateNSView(_ nsView: DocumentWebPreviewContainer, context: Context) {
        nsView.chinese = chinese
        context.coordinator.onContainerReady = onContainerReady
        if context.coordinator.lastContent != content {
            context.coordinator.lastContent = content
            nsView.load(content, interactiveFocus: false)
        }
    }

    static func dismantleNSView(_ nsView: DocumentWebPreviewContainer, coordinator: Coordinator) {
        coordinator.onContainerReady?(nil)
        coordinator.onContainerReady = nil
        coordinator.lastContent = nil
        nsView.teardown()
    }
}

@MainActor
private final class EmbeddedQuickLookContainer: NSView {
    private let previewView: QLPreviewView?

    override init(frame frameRect: NSRect) {
        self.previewView = QLPreviewView(frame: frameRect, style: .normal)
        super.init(frame: frameRect)
        if let previewView {
            previewView.shouldCloseWithWindow = false
            previewView.autostarts = true
            previewView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(previewView)
            NSLayoutConstraint.activate([
                previewView.leadingAnchor.constraint(equalTo: leadingAnchor),
                previewView.trailingAnchor.constraint(equalTo: trailingAnchor),
                previewView.topAnchor.constraint(equalTo: topAnchor),
                previewView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    func setURL(_ url: URL) {
        previewView?.previewItem = url as NSURL
    }

    func teardown() {
        previewView?.previewItem = nil
        previewView?.close()
    }
}

struct EmbeddedQuickLookRepresentable: NSViewRepresentable {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    final class Coordinator {
        var lastURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = EmbeddedQuickLookContainer(frame: .zero)
        context.coordinator.lastURL = url
        container.setURL(url)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? EmbeddedQuickLookContainer else { return }
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            container.setURL(url)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.lastURL = nil
        (nsView as? EmbeddedQuickLookContainer)?.teardown()
    }
}

struct PinnedMatchBannerView: View {
    let evidence: PreviewEvidence
    let chinese: Bool

    init(evidence: PreviewEvidence, chinese: Bool) {
        self.evidence = evidence
        self.chinese = chinese
    }

    private var caption: String {
        if evidence.context != nil {
            if evidence.match == .related {
                return chinese ? "相关段落上下文" : "Related excerpt context"
            }
            return chinese ? "命中段落上下文" : "Matched excerpt context"
        }
        if evidence.match == .related {
            return chinese ? "相关片段" : "Related excerpt"
        }
        return chinese ? "命中片段" : "Matched excerpt"
    }

    var body: some View {
        let contentText = evidence.context ?? evidence.text
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "text.magnifyingglass")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(highlighted(contentText, evidence: evidence))
                    .font(.callout)
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 84)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.75)
        )
        .accessibilityIdentifier("lumen-pinned-match-banner")
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
                  let range = body.range(
                    of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<body.endIndex
                  ),
                  !range.isEmpty {
                if let attrRange = Range(range, in: attributed) {
                    attributed[attrRange].backgroundColor = Color.orange.opacity(0.26)
                    attributed[attrRange].font = .callout.weight(.semibold)
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}
#endif
