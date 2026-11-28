import AppKit
import ApplicationServices
import Foundation

/// On-demand context captured from the frontmost application or pasteboard when opening Lumen.
enum CapturedContext: Equatable, Sendable {
    case selectedText(text: String, appName: String?, canReplace: Bool)
    case selectedFiles(paths: [String], appName: String?)
    case clipboardText(text: String)

    var textPayload: String? {
        switch self {
        case .selectedText(let text, _, _), .clipboardText(let text):
            return text
        case .selectedFiles:
            return nil
        }
    }

    var filePaths: [String] {
        switch self {
        case .selectedFiles(let paths, _):
            return paths
        case .selectedText, .clipboardText:
            return []
        }
    }

    var canReplaceInPlace: Bool {
        switch self {
        case .selectedText(_, _, let canReplace):
            return canReplace
        case .selectedFiles, .clipboardText:
            return false
        }
    }

    var characterCount: Int {
        textPayload?.count ?? 0
    }

    func badgeTitle(chinese: Bool) -> String {
        switch self {
        case .selectedText(let text, _, _):
            let count = text.count
            return chinese
                ? "已选 \(count) 字"
                : "Selected \(count) \(count == 1 ? "char" : "chars")"
        case .selectedFiles(let paths, _):
            let count = paths.count
            return chinese
                ? "已选 \(count) 个文件"
                : "\(count) \(count == 1 ? "file" : "files") selected"
        case .clipboardText(let text):
            let count = text.count
            return chinese
                ? "剪贴板 \(count) 字"
                : "Clipboard \(count) \(count == 1 ? "char" : "chars")"
        }
    }
}

/// Snapshot of the frontmost focused Accessibility element for text selection inspection.
struct SelectionAXElementState: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let selectedText: String?
    let isSelectedTextSettable: Bool
    let isEditable: Bool
}

/// Abstraction over macOS Accessibility APIs for single-shot selection capture and testing.
protocol SelectionAXAdapter: Sendable {
    func isTrusted() -> Bool
    func focusedElementState(in pid: pid_t) -> SelectionAXElementState?
    func selectedFileURLs(in pid: pid_t, limit: Int) -> [URL]
}

/// Live macOS Accessibility adapter with a bounded 0.15s IPC timeout.
struct NativeSelectionAXAdapter: SelectionAXAdapter {
    static let messagingTimeoutSeconds: Float = 0.15
    private static let secureTextFieldIdentifier = "AXSecureTextField"
    private static let webAreaRole = "AXWebArea"
    private static let editableAttribute = "AXEditable"

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func focusedElementState(in pid: pid_t) -> SelectionAXElementState? {
        guard pid > 0, let focused = focusedElement(in: pid) else { return nil }
        let (role, subrole) = roleAndSubrole(of: focused)
        // Hard privacy boundary: abort before touching kAXSelectedTextAttribute on password fields.
        if role == Self.secureTextFieldIdentifier || subrole == Self.secureTextFieldIdentifier {
            return SelectionAXElementState(
                role: role,
                subrole: subrole,
                selectedText: nil,
                isSelectedTextSettable: false,
                isEditable: false
            )
        }
        guard let selectedText = copyStringAttribute(kAXSelectedTextAttribute as String, of: focused),
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SelectionAXElementState(
                role: role,
                subrole: subrole,
                selectedText: nil,
                isSelectedTextSettable: false,
                isEditable: false
            )
        }
        let settable = isAttributeSettable(kAXSelectedTextAttribute as String, of: focused)
        let editable = role == Self.webAreaRole ? (copyBoolAttribute(Self.editableAttribute, of: focused) ?? false) : false
        return SelectionAXElementState(
            role: role,
            subrole: subrole,
            selectedText: selectedText,
            isSelectedTextSettable: settable,
            isEditable: editable
        )
    }

    func selectedFileURLs(in pid: pid_t, limit: Int) -> [URL] {
        guard pid > 0, limit > 0, let focused = focusedElement(in: pid) else { return [] }
        let selectedChildren = copyElementArrayAttribute(kAXSelectedChildrenAttribute as String, of: focused) ?? []
        let items = selectedChildren.isEmpty
            ? (copyElementArrayAttribute(kAXSelectedRowsAttribute as String, of: focused) ?? [])
            : selectedChildren
        var urls: [URL] = []
        urls.reserveCapacity(min(items.count, limit))
        for item in items.prefix(limit) {
            AXUIElementSetMessagingTimeout(item, Self.messagingTimeoutSeconds)
            if let url = copyURLAttribute(kAXURLAttribute as String, of: item) {
                urls.append(url)
            }
        }
        return urls
    }

    private func focusedElement(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeoutSeconds)
        return element
    }

    private func roleAndSubrole(of element: AXUIElement) -> (String?, String?) {
        let names = [kAXRoleAttribute as String, kAXSubroleAttribute as String]
        var result: CFArray?
        if AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success,
           let values = result as? [CFTypeRef], values.count == 2 {
            return (values[0] as? String, values[1] as? String)
        }
        return (
            copyStringAttribute(kAXRoleAttribute as String, of: element),
            copyStringAttribute(kAXSubroleAttribute as String, of: element)
        )
    }

    private func copyStringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func copyBoolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func copyURLAttribute(_ attribute: String, of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private func copyElementArrayAttribute(_ attribute: String, of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let objects = value as? [AnyObject] else { return nil }
        let typeID = AXUIElementGetTypeID()
        return objects.compactMap { item in
            let ref = item as CFTypeRef
            guard CFGetTypeID(ref) == typeID else { return nil }
            return (ref as! AXUIElement)
        }
    }

    private func isAttributeSettable(_ attribute: String, of element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }
}

/// Captures active selection, Finder file selection, or non-sensitive clipboard text on demand,
/// and resolves command payloads against the captured context.
@MainActor
final class SelectionContextBridge {
    static let maximumTextBytes = LumenCommandCatalog.maximumQuestionBytes
    static let maximumSelectedFiles = 32
    static let finderBundleID = "com.apple.finder"

    static let excludedPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
        .init("com.apple.is-sensitive"),
        .init("com.agilebits.onepassword"),
    ]

    private static let secureTextFieldRole = "AXSecureTextField"
    private static let secureTextFieldSubrole = kAXSecureTextFieldSubrole as String
    private static let webAreaRole = "AXWebArea"
    private static let editableRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXComboBoxRole as String,
    ]

    private let axAdapter: SelectionAXAdapter

    init(axAdapter: SelectionAXAdapter = NativeSelectionAXAdapter()) {
        self.axAdapter = axAdapter
    }

    /// Single-shot on-demand capture in strict priority order:
    /// 1) Focused selected text (hard-aborting without clipboard fallback on secure fields)
    /// 2) Selected Finder file URLs (local `file://` paths only, never materializing or reading bytes)
    /// 3) Non-sensitive plain-text clipboard fallback
    func capture(frontmostApp: NSRunningApplication?, pasteboard: NSPasteboard = .general) -> CapturedContext? {
        capture(
            pid: frontmostApp.flatMap { $0.processIdentifier > 0 ? $0.processIdentifier : nil },
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            appName: frontmostApp?.localizedName,
            pasteboard: pasteboard
        )
    }

    /// Testable entry point allowing deterministic mock testing for arbitrary bundle IDs and PIDs.
    func capture(
        pid: pid_t?,
        bundleIdentifier: String?,
        appName: String?,
        pasteboard: NSPasteboard = .general
    ) -> CapturedContext? {
        if let pid, pid > 0, axAdapter.isTrusted() {
            if let focused = axAdapter.focusedElementState(in: pid) {
                if focused.role == Self.secureTextFieldRole || focused.subrole == Self.secureTextFieldSubrole {
                    return nil
                }
                if let rawSelected = focused.selectedText,
                   let bounded = Self.boundedNonEmptyText(rawSelected, maxBytes: Self.maximumTextBytes) {
                    return .selectedText(
                        text: bounded,
                        appName: appName,
                        canReplace: Self.canReplace(focused)
                    )
                }
            }

            if bundleIdentifier == Self.finderBundleID {
                let urls = axAdapter.selectedFileURLs(in: pid, limit: Self.maximumSelectedFiles)
                var paths: [String] = []
                var seen = Set<String>()
                for url in urls {
                    guard let path = Self.localFilePath(from: url), seen.insert(path).inserted else { continue }
                    paths.append(path)
                    if paths.count >= Self.maximumSelectedFiles { break }
                }
                if !paths.isEmpty {
                    return .selectedFiles(paths: paths, appName: appName)
                }
            }
        }

        return captureClipboardText(from: pasteboard)
    }

    private func captureClipboardText(from pasteboard: NSPasteboard) -> CapturedContext? {
        let count = pasteboard.changeCount
        guard let types = pasteboard.types,
              Self.excludedPasteboardTypes.isDisjoint(with: types),
              types.contains(.string),
              pasteboard.changeCount == count,
              let rawText = pasteboard.string(forType: .string),
              pasteboard.changeCount == count,
              let bounded = Self.boundedNonEmptyText(rawText, maxBytes: Self.maximumTextBytes) else {
            return nil
        }
        return .clipboardText(text: bounded)
    }

    // MARK: - Command Pass-Through Helpers

    static func resolvedTranslation(_ command: TranslationCommand, with context: CapturedContext?) -> TranslationCommand {
        guard command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawPayload = context?.textPayload,
              let payload = boundedNonEmptyText(rawPayload, maxBytes: LumenCommandCatalog.maximumQuestionBytes) else {
            return command
        }
        // `TranslationCommand.parse` sets `source == .automatic` iff a target language was explicitly requested.
        let hasExplicitTarget = command.source == .automatic
        let hasHan = payload.unicodeScalars.contains { $0.properties.isIdeographic }
        let source: TranslationLanguage = hasExplicitTarget ? .automatic : (hasHan ? .simplifiedChinese : .english)
        let target: TranslationLanguage = hasExplicitTarget ? command.target : (hasHan ? .english : .simplifiedChinese)
        return TranslationCommand(
            raw: command.raw,
            text: payload,
            source: source,
            target: target,
            unsupportedLanguage: command.unsupportedLanguage
        )
    }

    static func resolvedQuestion(rawPayload: String, with context: CapturedContext?) -> String? {
        let trimmedRaw = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contextPayload = context?.textPayload,
              let payload = boundedNonEmptyText(contextPayload, maxBytes: LumenCommandCatalog.maximumQuestionBytes) else {
            return trimmedRaw.isEmpty ? nil : rawPayload
        }
        if trimmedRaw.isEmpty {
            return payload
        }
        let open = "\(trimmedRaw)\n\n\"\"\"\n"
        let close = "\n\"\"\""
        let overheadBytes = open.utf8.count + close.utf8.count
        if overheadBytes < LumenCommandCatalog.maximumQuestionBytes {
            let budget = LumenCommandCatalog.maximumQuestionBytes - overheadBytes
            let fittedPayload = truncateUTF8(payload, maxBytes: budget)
            return truncateUTF8(open + fittedPayload + close, maxBytes: LumenCommandCatalog.maximumQuestionBytes)
        }
        return truncateUTF8(open + payload + close, maxBytes: LumenCommandCatalog.maximumQuestionBytes)
    }

    static func resolvedWebPayload(_ payload: String, with context: CapturedContext?) -> String? {
        if !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return payload
        }
        guard let contextPayload = context?.textPayload else { return nil }
        let singleLine = contextPayload
            .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        let bounded = truncateUTF8(singleLine, maxBytes: LumenCommandCatalog.maximumURLArgumentBytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }

    static func defaultExecutableArgument(for context: CapturedContext?) -> String? {
        guard let context else { return nil }
        switch context {
        case .selectedFiles(let paths, _):
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        case .selectedText(let text, _, _), .clipboardText(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }

    // MARK: - Internal Helpers

    static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var byteCount = 0
        for index in text.unicodeScalars.indices {
            let scalarBytes = text.unicodeScalars[index].utf8.count
            if byteCount + scalarBytes > maxBytes {
                return String(text.unicodeScalars[..<index])
            }
            byteCount += scalarBytes
        }
        return text
    }

    private static func boundedNonEmptyText(_ text: String, maxBytes: Int) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let truncated = truncateUTF8(text, maxBytes: maxBytes)
        guard !truncated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return truncated
    }

    private static func canReplace(_ state: SelectionAXElementState) -> Bool {
        if state.isSelectedTextSettable { return true }
        guard let role = state.role else { return false }
        if editableRoles.contains(role) { return true }
        return role == webAreaRole && state.isEditable
    }

    private static func localFilePath(from url: URL) -> String? {
        guard url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else {
            return nil
        }
        let rawPath = url.path
        guard !rawPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        let path = url.standardized.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return path
    }
}
