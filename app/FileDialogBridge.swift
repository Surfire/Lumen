import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation

/// Active macOS Open/Save file dialog metadata captured on demand.
struct FileDialogContext: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case open
        case save
    }

    let appPID: pid_t
    let appName: String
    let appBundleID: String?
    let kind: Kind
    let servicePID: pid_t?
    let dialogElement: FileDialogAXElement?

    init(
        appPID: pid_t,
        appName: String,
        appBundleID: String?,
        kind: Kind,
        servicePID: pid_t? = nil,
        dialogElement: FileDialogAXElement? = nil
    ) {
        self.appPID = appPID
        self.appName = appName
        self.appBundleID = appBundleID
        self.kind = kind
        self.servicePID = servicePID
        self.dialogElement = dialogElement
    }
}

/// Directory currently displayed by a Finder window, verified local and non-dataless.
struct OpenFinderFolder: Equatable, Sendable, Identifiable {
    let path: String
    let name: String

    var id: String { path }
}

/// Opaque Accessibility element handle abstracting native `AXUIElement` for testing.
enum FileDialogAXElement: Hashable, @unchecked Sendable {
    case native(AXUIElement)
    case mock(String)

    var axElement: AXUIElement? {
        if case .native(let element) = self { return element }
        return nil
    }
}

/// Narrow Accessibility and synthetic keyboard adapter backing `FileDialogBridge`.
protocol FileDialogAXAdapter: Sendable {
    func isProcessTrusted() -> Bool
    func applicationElement(for pid: pid_t) -> FileDialogAXElement?
    func systemFocusedElement() -> FileDialogAXElement?
    func focusedElement(in pid: pid_t) -> FileDialogAXElement?
    func pid(of element: FileDialogAXElement) -> pid_t?
    func bundleIdentifier(for pid: pid_t) -> String?
    func runningApplicationPIDs(bundleIdentifier: String) -> [pid_t]
    func isApplicationActive(pid: pid_t) -> Bool
    func activateApplication(pid: pid_t) -> Bool
    func elementAttribute(_ attribute: String, of element: FileDialogAXElement) -> FileDialogAXElement?
    func elementsAttribute(_ attribute: String, of element: FileDialogAXElement) -> [FileDialogAXElement]
    func stringAttribute(_ attribute: String, of element: FileDialogAXElement) -> String?
    func boolAttribute(_ attribute: String, of element: FileDialogAXElement) -> Bool?
    func urlAttribute(_ attribute: String, of element: FileDialogAXElement) -> URL?
    func setStringAttribute(_ attribute: String, value: String, on element: FileDialogAXElement) -> Bool
    func performAction(_ action: String, on element: FileDialogAXElement) -> Bool
    func postKeyboardShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool
}

/// Production Accessibility adapter using bounded 0.25s timeouts and CGEvent shortcuts.
struct NativeFileDialogAXAdapter: FileDialogAXAdapter {
    private static let messagingTimeoutSeconds: Float = 0.25

    init() {}

    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func applicationElement(for pid: pid_t) -> FileDialogAXElement? {
        guard pid > 0 else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeoutSeconds)
        return .native(element)
    }

    func systemFocusedElement() -> FileDialogAXElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeoutSeconds)
        return elementAttribute(kAXFocusedUIElementAttribute as String, of: .native(systemWide))
    }

    func focusedElement(in pid: pid_t) -> FileDialogAXElement? {
        guard let app = applicationElement(for: pid) else { return nil }
        return elementAttribute(kAXFocusedUIElementAttribute as String, of: app)
    }

    func pid(of element: FileDialogAXElement) -> pid_t? {
        guard let ax = element.axElement else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(ax, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    func bundleIdentifier(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    func runningApplicationPIDs(bundleIdentifier: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
            .filter { $0 > 0 }
    }

    func isApplicationActive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return NSRunningApplication(processIdentifier: pid)?.isActive == true
    }

    func activateApplication(pid: pid_t) -> Bool {
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }

    func elementAttribute(_ attribute: String, of element: FileDialogAXElement) -> FileDialogAXElement? {
        guard let value = rawAttribute(attribute, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let child = value as! AXUIElement
        AXUIElementSetMessagingTimeout(child, Self.messagingTimeoutSeconds)
        return .native(child)
    }

    func elementsAttribute(_ attribute: String, of element: FileDialogAXElement) -> [FileDialogAXElement] {
        guard let value = rawAttribute(attribute, of: element),
              let items = value as? [AnyObject] else { return [] }
        return items.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            let child = item as! AXUIElement
            AXUIElementSetMessagingTimeout(child, Self.messagingTimeoutSeconds)
            return .native(child)
        }
    }

    func stringAttribute(_ attribute: String, of element: FileDialogAXElement) -> String? {
        guard let value = rawAttribute(attribute, of: element) else { return nil }
        return value as? String
    }

    func boolAttribute(_ attribute: String, of element: FileDialogAXElement) -> Bool? {
        guard let value = rawAttribute(attribute, of: element) else { return nil }
        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    func urlAttribute(_ attribute: String, of element: FileDialogAXElement) -> URL? {
        guard let value = rawAttribute(attribute, of: element) else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            return (value as! URL)
        }
        if let url = value as? URL {
            return url
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("/") {
                return URL(fileURLWithPath: trimmed)
            }
            return URL(string: trimmed)
        }
        return nil
    }

    func setStringAttribute(_ attribute: String, value: String, on element: FileDialogAXElement) -> Bool {
        guard let ax = element.axElement else { return false }
        return AXUIElementSetAttributeValue(ax, attribute as CFString, value as CFString) == .success
    }

    func performAction(_ action: String, on element: FileDialogAXElement) -> Bool {
        guard let ax = element.axElement else { return false }
        return AXUIElementPerformAction(ax, action as CFString) == .success
    }

    func postKeyboardShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }

    private func rawAttribute(_ attribute: String, of element: FileDialogAXElement) -> CFTypeRef? {
        guard let ax = element.axElement else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

/// On-demand Quick Switch bridge for detecting macOS Open/Save dialogs, listing open Finder
/// folders via pure Accessibility, and navigating dialogs via Go-to-Folder without clipboard mutation.
@MainActor
final class FileDialogBridge {
    private static let openAndSaveServiceBundleID = "com.apple.appkit.xpc.openAndSavePanelService"
    private static let finderBundleID = "com.apple.finder"
    private static let maxTraversalDepth = 6
    private static let maxTraversalNodes = 80
    private static let maxParentWalkHops = 16
    private static let initialFocusSettleNanoseconds: UInt64 = 80_000_000
    private static let maxFocusWaitNanoseconds: UInt64 = 500_000_000

    private static let openIdentifiers: Set<String> = ["open-panel", "NSOpenPanel"]
    private static let saveIdentifiers: Set<String> = ["save-panel", "NSSavePanel"]
    private static let saveAsFieldIdentifiers: Set<String> = [
        "saveasnametextfield",
        "saveastextfield",
        "filenametextfield",
        "namefield",
        "saveasname",
    ]
    private static let saveButtonTitles: Set<String> = [
        "save", "save as", "save as...", "save as…", "export", "export...", "export…",
        "replace", "存储", "保存", "导出", "替换", "存储为",
    ]
    private static let openButtonTitles: Set<String> = [
        "open", "choose", "choose...", "choose…", "select", "select...", "select…",
        "upload", "import", "attach", "打开", "选取", "选择", "上传", "导入",
    ]
    private static let fileListContainerRoles: Set<String> = [
        kAXScrollAreaRole as String,
        kAXOutlineRole as String,
        kAXTableRole as String,
        kAXBrowserRole as String,
        "AXCollectionView",
    ]

    private let axAdapter: FileDialogAXAdapter
    private let pollIntervalNanoseconds: UInt64
    private let pollTimeoutNanoseconds: UInt64
    private var navigationGeneration: UInt64 = 0

    convenience init(axAdapter: FileDialogAXAdapter = NativeFileDialogAXAdapter()) {
        self.init(
            axAdapter: axAdapter,
            pollIntervalNanoseconds: 25_000_000,
            pollTimeoutNanoseconds: 600_000_000
        )
    }

    init(
        axAdapter: FileDialogAXAdapter,
        pollIntervalNanoseconds: UInt64,
        pollTimeoutNanoseconds: UInt64
    ) {
        self.axAdapter = axAdapter
        self.pollIntervalNanoseconds = max(1_000_000, pollIntervalNanoseconds)
        self.pollTimeoutNanoseconds = max(self.pollIntervalNanoseconds, pollTimeoutNanoseconds)
    }

    // MARK: - Dialog Detection

    func detectActiveDialog(frontmostApp: NSRunningApplication?) -> FileDialogContext? {
        guard axAdapter.isProcessTrusted(),
              let frontmostApp,
              frontmostApp.processIdentifier > 0 else {
            return nil
        }
        let pid = frontmostApp.processIdentifier
        let appName = frontmostApp.localizedName ?? frontmostApp.bundleIdentifier ?? "App"
        let bundleID = frontmostApp.bundleIdentifier

        let focusedCandidates = [
            axAdapter.focusedElement(in: pid),
            axAdapter.systemFocusedElement(),
        ].compactMap { $0 }

        for focused in focusedCandidates {
            if let focusedPID = axAdapter.pid(of: focused),
               axAdapter.bundleIdentifier(for: focusedPID) == Self.openAndSaveServiceBundleID {
                let remote = classifyRemoteOpenAndSavePanel(focusedElement: focused, servicePID: focusedPID)
                return FileDialogContext(
                    appPID: pid,
                    appName: appName,
                    appBundleID: bundleID,
                    kind: remote.kind,
                    servicePID: focusedPID,
                    dialogElement: remote.dialogElement
                )
            }
        }

        guard let appElement = axAdapter.applicationElement(for: pid) else { return nil }
        var windowCandidates: [FileDialogAXElement] = []
        var seenWindows = Set<FileDialogAXElement>()

        func appendWindowCandidate(_ element: FileDialogAXElement?) {
            guard let element, !seenWindows.contains(element) else { return }
            seenWindows.insert(element)
            windowCandidates.append(element)
        }

        appendWindowCandidate(axAdapter.elementAttribute(kAXFocusedWindowAttribute as String, of: appElement))
        for focused in focusedCandidates {
            appendWindowCandidate(axAdapter.elementAttribute(kAXWindowAttribute as String, of: focused))
            appendWindowCandidate(axAdapter.elementAttribute(kAXTopLevelUIElementAttribute as String, of: focused))
        }
        appendWindowCandidate(axAdapter.elementAttribute(kAXMainWindowAttribute as String, of: appElement))

        for window in windowCandidates {
            for sheet in activeSheets(on: window).reversed() {
                if let inspected = inspectDialogRoot(sheet) {
                    return FileDialogContext(
                        appPID: pid,
                        appName: appName,
                        appBundleID: bundleID,
                        kind: inspected.kind,
                        servicePID: inspected.servicePID,
                        dialogElement: sheet
                    )
                }
            }
            if let inspected = inspectDialogRoot(window) {
                return FileDialogContext(
                    appPID: pid,
                    appName: appName,
                    appBundleID: bundleID,
                    kind: inspected.kind,
                    servicePID: inspected.servicePID,
                    dialogElement: window
                )
            }
        }
        return nil
    }

    private func classifyRemoteOpenAndSavePanel(
        focusedElement: FileDialogAXElement,
        servicePID: pid_t
    ) -> (kind: FileDialogContext.Kind, dialogElement: FileDialogAXElement?) {
        var roots: [FileDialogAXElement] = []
        var seen = Set<FileDialogAXElement>()

        func addRoot(_ element: FileDialogAXElement?) {
            guard let element, !seen.contains(element) else { return }
            seen.insert(element)
            roots.append(element)
        }

        addRoot(axAdapter.elementAttribute(kAXTopLevelUIElementAttribute as String, of: focusedElement))
        addRoot(axAdapter.elementAttribute(kAXWindowAttribute as String, of: focusedElement))
        if let serviceApp = axAdapter.applicationElement(for: servicePID) {
            addRoot(axAdapter.elementAttribute(kAXFocusedWindowAttribute as String, of: serviceApp))
            for win in axAdapter.elementsAttribute(kAXWindowsAttribute as String, of: serviceApp).prefix(2) {
                addRoot(win)
            }
        }

        for root in roots {
            for sheet in activeSheets(on: root).reversed() {
                if let inspected = inspectDialogRoot(sheet) {
                    return (inspected.kind, sheet)
                }
            }
            if let inspected = inspectDialogRoot(root) {
                return (inspected.kind, root)
            }
        }

        for root in roots {
            for sheet in activeSheets(on: root).reversed() {
                if let inspected = inspectDialogRoot(sheet, allowUnmarkedFallback: true) {
                    return (inspected.kind, sheet)
                }
            }
            if isDialogOwnedRoot(root, servicePID: servicePID),
               let inspected = inspectDialogRoot(root, allowUnmarkedFallback: true) {
                return (inspected.kind, root)
            }
        }

        if let first = roots.first,
           let inspected = inspectDialogRoot(first, allowUnmarkedFallback: true) {
            return (inspected.kind, nil)
        }
        return (.open, nil)
    }

    private func isDialogOwnedRoot(_ element: FileDialogAXElement, servicePID: pid_t) -> Bool {
        if axAdapter.pid(of: element) == servicePID {
            return true
        }
        let role = axAdapter.stringAttribute(kAXRoleAttribute as String, of: element)
        if role == (kAXSheetRole as String) {
            return true
        }
        if axAdapter.stringAttribute(kAXSubroleAttribute as String, of: element) == (kAXDialogSubrole as String) {
            return true
        }
        if let id = axAdapter.stringAttribute(kAXIdentifierAttribute as String, of: element) {
            return Self.openIdentifiers.contains(id) || Self.saveIdentifiers.contains(id)
        }
        return false
    }

    private func activeSheets(on window: FileDialogAXElement) -> [FileDialogAXElement] {
        var result: [FileDialogAXElement] = []
        var seen = Set<FileDialogAXElement>()

        // AXSheets is exposed by AppKit windows without a public AXAttributeConstants symbol.
        for sheet in axAdapter.elementsAttribute("AXSheets", of: window) {
            if seen.insert(sheet).inserted {
                result.append(sheet)
            }
        }
        for child in axAdapter.elementsAttribute(kAXChildrenAttribute as String, of: window) {
            if axAdapter.stringAttribute(kAXRoleAttribute as String, of: child) == (kAXSheetRole as String),
               seen.insert(child).inserted {
                result.append(child)
            }
        }
        return result
    }

    private func inspectDialogRoot(
        _ root: FileDialogAXElement,
        allowUnmarkedFallback: Bool = false
    ) -> (kind: FileDialogContext.Kind, servicePID: pid_t?)? {
        let rootRole = axAdapter.stringAttribute(kAXRoleAttribute as String, of: root)
        let rootSubrole = axAdapter.stringAttribute(kAXSubroleAttribute as String, of: root)
        let isDialogOrSheet = rootRole == (kAXSheetRole as String) || rootSubrole == (kAXDialogSubrole as String)

        var explicitOpen = false
        var explicitSave = false
        var hasFileBrowser = false
        var hasSaveAsField = false
        var hasOpenButton = false
        var hasSaveButton = false
        var detectedServicePID: pid_t?
        var checkedPIDs = Set<pid_t>()

        func noteElementPID(_ element: FileDialogAXElement) {
            guard detectedServicePID == nil,
                  let elementPID = axAdapter.pid(of: element),
                  checkedPIDs.insert(elementPID).inserted else {
                return
            }
            if axAdapter.bundleIdentifier(for: elementPID) == Self.openAndSaveServiceBundleID {
                detectedServicePID = elementPID
            }
        }

        if let defaultButton = axAdapter.elementAttribute(kAXDefaultButtonAttribute as String, of: root),
           let buttonKind = buttonDialogKind(defaultButton) {
            if buttonKind == .save { hasSaveButton = true } else { hasOpenButton = true }
        }

        var queue: [(element: FileDialogAXElement, depth: Int)] = [(root, 0)]
        var head = 0
        var visited = Set<FileDialogAXElement>()

        while head < queue.count, visited.count < Self.maxTraversalNodes {
            let current = queue[head]
            head += 1

            guard visited.insert(current.element).inserted else { continue }
            noteElementPID(current.element)

            let role = axAdapter.stringAttribute(kAXRoleAttribute as String, of: current.element)
            let subrole = axAdapter.stringAttribute(kAXSubroleAttribute as String, of: current.element)
            let identifier = axAdapter.stringAttribute(kAXIdentifierAttribute as String, of: current.element)

            let isNestedOverlay = current.depth > 0 &&
                (role == (kAXPopoverRole as String) || role == (kAXSheetRole as String))
            if isNestedOverlay {
                continue
            }

            if let identifier {
                if Self.openIdentifiers.contains(identifier) { explicitOpen = true }
                if Self.saveIdentifiers.contains(identifier) { explicitSave = true }
            }

            if role == (kAXBrowserRole as String) || role == (kAXOutlineRole as String) {
                hasFileBrowser = true
            }

            if role == (kAXTextFieldRole as String),
               subrole != (kAXSearchFieldSubrole as String),
               axAdapter.boolAttribute(kAXEnabledAttribute as String, of: current.element) != false,
               isLikelySaveAsField(current.element, identifier: identifier) {
                hasSaveAsField = true
            }

            if role == (kAXButtonRole as String), let buttonKind = buttonDialogKind(current.element) {
                if buttonKind == .save { hasSaveButton = true } else { hasOpenButton = true }
            }

            // Do not burn node budget inside file rows/cells or toolbar search items.
            let shouldSkipChildren = role == (kAXBrowserRole as String)
                || role == (kAXOutlineRole as String)
                || role == (kAXTableRole as String)
                || role == (kAXToolbarRole as String)
                || role == (kAXListRole as String)

            if !shouldSkipChildren, current.depth < Self.maxTraversalDepth {
                for child in axAdapter.elementsAttribute(kAXChildrenAttribute as String, of: current.element) {
                    queue.append((child, current.depth + 1))
                }
            }
        }

        if explicitOpen { return (.open, detectedServicePID) }
        if explicitSave { return (.save, detectedServicePID) }
        if allowUnmarkedFallback {
            let kind: FileDialogContext.Kind = (hasSaveAsField || (hasSaveButton && !hasOpenButton)) ? .save : .open
            return (kind, detectedServicePID)
        }
        guard isDialogOrSheet, hasFileBrowser else { return nil }
        if hasSaveAsField || (hasSaveButton && !hasOpenButton) { return (.save, detectedServicePID) }
        if hasOpenButton || !hasSaveAsField { return (.open, detectedServicePID) }
        return nil
    }

    private func isLikelySaveAsField(_ element: FileDialogAXElement, identifier: String?) -> Bool {
        if let id = identifier?.lowercased(), Self.saveAsFieldIdentifiers.contains(id) {
            return true
        }
        let hints = [
            axAdapter.stringAttribute(kAXTitleAttribute as String, of: element),
            axAdapter.stringAttribute(kAXDescriptionAttribute as String, of: element),
            axAdapter.stringAttribute(kAXPlaceholderValueAttribute as String, of: element),
        ].compactMap { $0?.lowercased() }
        if hints.contains(where: {
            $0.contains("save as") || $0.contains("name") || $0.contains("存储") || $0.contains("名称")
        }) {
            return true
        }
        // In AppKit NSSavePanel, non-search text fields outside the file browser and toolbar are Save-As inputs.
        return axAdapter.stringAttribute(kAXValueAttribute as String, of: element) != nil
    }

    private func buttonDialogKind(_ button: FileDialogAXElement) -> FileDialogContext.Kind? {
        if let id = axAdapter.stringAttribute(kAXIdentifierAttribute as String, of: button)?.lowercased() {
            if id == "savebutton" || id == "save" { return .save }
            if id == "openbutton" || id == "open" { return .open }
        }
        guard let title = axAdapter.stringAttribute(kAXTitleAttribute as String, of: button)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !title.isEmpty else {
            return nil
        }
        if Self.saveButtonTitles.contains(title) { return .save }
        if Self.openButtonTitles.contains(title) { return .open }
        return nil
    }

    // MARK: - Open Finder Folders

    func openFinderFolders() -> [OpenFinderFolder] {
        guard axAdapter.isProcessTrusted() else { return [] }
        let finderPIDs = axAdapter.runningApplicationPIDs(bundleIdentifier: Self.finderBundleID)
        guard !finderPIDs.isEmpty else { return [] }

        var folders: [OpenFinderFolder] = []
        var seenPaths = Set<String>()

        for pid in finderPIDs {
            guard let finderApp = axAdapter.applicationElement(for: pid) else { continue }
            let windows = axAdapter.elementsAttribute(kAXWindowsAttribute as String, of: finderApp)
            for window in windows {
                if let role = axAdapter.stringAttribute(kAXRoleAttribute as String, of: window),
                   role != (kAXWindowRole as String) {
                    continue
                }
                if axAdapter.stringAttribute(kAXSubroleAttribute as String, of: window) == "AXDesktop" {
                    continue
                }
                guard let url = extractFinderWindowURL(window),
                      let normalized = Self.verifiedLocalDirectoryPath(from: url),
                      seenPaths.insert(normalized).inserted else {
                    continue
                }
                let displayName = Self.folderDisplayName(for: normalized)
                folders.append(OpenFinderFolder(path: normalized, name: displayName))
            }
        }
        return folders
    }

    private func extractFinderWindowURL(_ window: FileDialogAXElement) -> URL? {
        if let docURL = axAdapter.urlAttribute(kAXDocumentAttribute as String, of: window) {
            return docURL
        }
        if let proxy = axAdapter.elementAttribute(kAXProxyAttribute as String, of: window),
           let proxyURL = axAdapter.urlAttribute(kAXURLAttribute as String, of: proxy) {
            return proxyURL
        }
        return extractToolbarOrPathBarURL(from: window)
    }

    private func extractToolbarOrPathBarURL(from window: FileDialogAXElement) -> URL? {
        var queue: [(element: FileDialogAXElement, depth: Int, inToolbar: Bool)] = [(window, 0, false)]
        var head = 0
        var visited = Set<FileDialogAXElement>()
        var toolbarURL: URL?

        while head < queue.count, visited.count < Self.maxTraversalNodes {
            let current = queue[head]
            head += 1
            guard visited.insert(current.element).inserted else { continue }

            let role = axAdapter.stringAttribute(kAXRoleAttribute as String, of: current.element)

            if current.depth > 0, let role, Self.fileListContainerRoles.contains(role) {
                continue
            }

            if current.inToolbar,
               let url = axAdapter.urlAttribute(kAXURLAttribute as String, of: current.element) {
                if toolbarURL == nil { toolbarURL = url }
            }

            // Finder exposes the Path Bar as an AXList outside scroll areas; its last breadcrumb URL is the folder.
            if role == (kAXListRole as String) {
                let children = axAdapter.elementsAttribute(kAXChildrenAttribute as String, of: current.element)
                let breadcrumbURLs = children.compactMap {
                    axAdapter.urlAttribute(kAXURLAttribute as String, of: $0)
                }
                if let currentFolderURL = breadcrumbURLs.last {
                    return currentFolderURL
                }
                continue
            }

            let childInToolbar = current.inToolbar || role == (kAXToolbarRole as String)
            if current.depth < Self.maxTraversalDepth {
                for child in axAdapter.elementsAttribute(kAXChildrenAttribute as String, of: current.element) {
                    queue.append((child, current.depth + 1, childInToolbar))
                }
            }
        }
        return toolbarURL
    }

    static func normalizedDirectoryPath(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else { return "" }
        var standardized = URL(fileURLWithPath: rawPath).standardized.path
        while standardized.count > 1 && standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }

    static func verifiedLocalDirectoryPath(from url: URL) -> String? {
        guard url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else {
            return nil
        }
        return (try? LocalFile.withMaterializationDisabled { () -> String? in
            let path = url.path
            guard path.hasPrefix("/"), !path.hasPrefix("/.file/id=") else { return nil }
            let normalized = normalizedDirectoryPath(path)
            guard !normalized.isEmpty,
                  !normalized.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                return nil
            }
            var info = Darwin.stat()
            guard lstat(normalized, &info) == 0 else { return nil }
            let mode = info.st_mode & S_IFMT
            if mode == S_IFLNK {
                var target = Darwin.stat()
                guard fstatat(AT_FDCWD, normalized, &target, 0) == 0,
                      isResidentLocalDirectory(stat: info, targetStat: target) else {
                    return nil
                }
                return normalized
            }
            guard isResidentLocalDirectory(stat: info) else { return nil }
            return normalized
        }) ?? nil
    }

    static func isResidentLocalDirectory(stat info: Darwin.stat, targetStat: Darwin.stat? = nil) -> Bool {
        guard (info.st_flags & UInt32(SF_DATALESS)) == 0 else { return false }
        if let targetStat {
            return (targetStat.st_mode & S_IFMT) == S_IFDIR
                && (targetStat.st_flags & UInt32(SF_DATALESS)) == 0
        }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func folderDisplayName(for path: String) -> String {
        if path == "/" { return "/" }
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? path : component
    }

    // MARK: - Target Path Resolution

    static func resolvedTargetPath(for path: String, isDirectory: Bool, in kind: FileDialogContext.Kind) -> String {
        switch kind {
        case .open:
            return path
        case .save:
            return isDirectory ? path : (path as NSString).deletingLastPathComponent
        }
    }

    // MARK: - Go-to-Folder Navigation

    private struct NavigationBaseline {
        let focusedBefore: FileDialogAXElement?
        let initialContainers: Set<FileDialogAXElement>
        let initialTextFields: Set<FileDialogAXElement>
    }

    func navigate(
        _ context: FileDialogContext,
        toPath path: String,
        isDirectory: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard axAdapter.isProcessTrusted() else {
            completion(false)
            return
        }
        let targetPath = Self.resolvedTargetPath(for: path, isDirectory: isDirectory, in: context.kind)
        guard !targetPath.isEmpty else {
            completion(false)
            return
        }

        navigationGeneration &+= 1
        let generation = navigationGeneration

        // Never call activate on an already-active host app: that can pull key focus onto a document window.
        if !axAdapter.isApplicationActive(pid: context.appPID) {
            _ = axAdapter.activateApplication(pid: context.appPID)
        }

        Task { @MainActor [weak self] in
            guard let self, self.navigationGeneration == generation else {
                completion(false)
                return
            }

            let focusReady = await self.waitForDialogFocus(context: context, generation: generation)
            guard focusReady, self.navigationGeneration == generation else {
                completion(false)
                return
            }

            let baseline = self.captureBaseline(for: context)

            guard self.axAdapter.postKeyboardShortcut(
                keyCode: CGKeyCode(kVK_ANSI_G),
                flags: [.maskCommand, .maskShift]
            ) else {
                completion(false)
                return
            }

            guard let inputField = await self.pollForGoToFolderField(
                context: context,
                baseline: baseline,
                generation: generation
            ) else {
                completion(false)
                return
            }

            guard self.navigationGeneration == generation else {
                completion(false)
                return
            }

            guard self.setPathValue(targetPath, on: inputField) else {
                completion(false)
                return
            }

            let returnPosted = self.axAdapter.postKeyboardShortcut(keyCode: CGKeyCode(kVK_Return), flags: [])
            if !returnPosted {
                let confirmed = self.axAdapter.performAction(kAXConfirmAction as String, on: inputField)
                completion(confirmed)
                return
            }

            let maxConfirmWaitNs = self.pollIntervalNanoseconds * 6
            var confirmElapsedNs: UInt64 = 0
            while confirmElapsedNs < maxConfirmWaitNs {
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                guard self.navigationGeneration == generation else {
                    completion(false)
                    return
                }
                if self.currentFocusedElement(for: context) != inputField {
                    completion(true)
                    return
                }
                confirmElapsedNs += self.pollIntervalNanoseconds
            }

            _ = self.axAdapter.performAction(kAXConfirmAction as String, on: inputField)
            completion(true)
        }
    }

    private func waitForDialogFocus(context: FileDialogContext, generation: UInt64) async -> Bool {
        let initialSettleNs: UInt64 = pollIntervalNanoseconds >= 20_000_000
            ? Self.initialFocusSettleNanoseconds
            : pollIntervalNanoseconds
        try? await Task.sleep(nanoseconds: initialSettleNs)
        guard navigationGeneration == generation else { return false }

        let maxFocusWaitNs = min(Self.maxFocusWaitNanoseconds, pollTimeoutNanoseconds)
        var elapsedNs: UInt64 = 0
        var raisedDialog = false

        while elapsedNs <= maxFocusWaitNs {
            guard navigationGeneration == generation else { return false }
            if isSystemFocusInsideDialog(context: context) {
                return true
            }
            if !raisedDialog, let dialogElement = context.dialogElement {
                raisedDialog = true
                _ = axAdapter.performAction(kAXRaiseAction as String, on: dialogElement)
            }
            if elapsedNs >= maxFocusWaitNs { break }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            elapsedNs += pollIntervalNanoseconds
        }
        return false
    }

    private func isSystemFocusInsideDialog(context: FileDialogContext) -> Bool {
        guard let focused = axAdapter.systemFocusedElement() else {
            return false
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var queue: [(element: FileDialogAXElement, hops: Int)] = [(focused, 0)]
        var head = 0
        var visited = Set<FileDialogAXElement>()

        while head < queue.count {
            let current = queue[head]
            head += 1
            guard visited.insert(current.element).inserted else { continue }

            if let dialogElement = context.dialogElement, current.element == dialogElement {
                return true
            }
            if let currentPID = axAdapter.pid(of: current.element) {
                if currentPID == ownPID, context.appPID != ownPID {
                    return false
                }
                if let servicePID = context.servicePID, currentPID == servicePID {
                    return true
                }
                if axAdapter.bundleIdentifier(for: currentPID) == Self.openAndSaveServiceBundleID {
                    return true
                }
            }
            if context.dialogElement == nil, isDialogContainerElement(current.element) {
                return true
            }

            guard current.hops < Self.maxParentWalkHops else { continue }
            for attr in [
                kAXParentAttribute as String,
                kAXTopLevelUIElementAttribute as String,
                kAXWindowAttribute as String,
            ] {
                if let ancestor = axAdapter.elementAttribute(attr, of: current.element) {
                    queue.append((ancestor, current.hops + 1))
                }
            }
        }
        return false
    }

    private func isDialogContainerElement(_ element: FileDialogAXElement) -> Bool {
        let role = axAdapter.stringAttribute(kAXRoleAttribute as String, of: element)
        let subrole = axAdapter.stringAttribute(kAXSubroleAttribute as String, of: element)
        let identifier = axAdapter.stringAttribute(kAXIdentifierAttribute as String, of: element)
        let isCandidateContainer = role == (kAXSheetRole as String)
            || role == (kAXWindowRole as String)
            || subrole == (kAXDialogSubrole as String)
            || (identifier.map { Self.openIdentifiers.contains($0) || Self.saveIdentifiers.contains($0) } ?? false)
        guard isCandidateContainer else { return false }
        return inspectDialogRoot(element) != nil
    }

    private func captureBaseline(for context: FileDialogContext) -> NavigationBaseline {
        let focusedBefore = currentFocusedElement(for: context)
        var initialContainers = Set<FileDialogAXElement>()
        var initialTextFields = Set<FileDialogAXElement>()

        var roots: [FileDialogAXElement] = []
        if let dialogElement = context.dialogElement {
            roots.append(dialogElement)
        }
        if let app = axAdapter.applicationElement(for: context.appPID) {
            if let fw = axAdapter.elementAttribute(kAXFocusedWindowAttribute as String, of: app),
               !roots.contains(fw) {
                roots.append(fw)
            }
            if let mw = axAdapter.elementAttribute(kAXMainWindowAttribute as String, of: app),
               !roots.contains(mw) {
                roots.append(mw)
            }
        }
        func appendServiceWindows(for pid: pid_t) {
            guard axAdapter.bundleIdentifier(for: pid) == Self.openAndSaveServiceBundleID,
                  let serviceApp = axAdapter.applicationElement(for: pid) else {
                return
            }
            for win in axAdapter.elementsAttribute(kAXWindowsAttribute as String, of: serviceApp).prefix(2)
                where !roots.contains(win) {
                roots.append(win)
            }
        }

        if let focusedBefore {
            if let win = axAdapter.elementAttribute(kAXWindowAttribute as String, of: focusedBefore),
               !roots.contains(win) {
                roots.append(win)
            }
            if let focusedPID = axAdapter.pid(of: focusedBefore) {
                appendServiceWindows(for: focusedPID)
            }
        }
        if let servicePID = context.servicePID {
            appendServiceWindows(for: servicePID)
        }

        for root in roots {
            var queue: [(element: FileDialogAXElement, depth: Int)] = [(root, 0)]
            var head = 0
            var visited = Set<FileDialogAXElement>()

            while head < queue.count, visited.count < Self.maxTraversalNodes {
                let current = queue[head]
                head += 1
                guard visited.insert(current.element).inserted else { continue }

                let role = axAdapter.stringAttribute(kAXRoleAttribute as String, of: current.element)
                let subrole = axAdapter.stringAttribute(kAXSubroleAttribute as String, of: current.element)

                if role == (kAXWindowRole as String)
                    || role == (kAXSheetRole as String)
                    || role == (kAXPopoverRole as String) {
                    initialContainers.insert(current.element)
                }
                if (role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String)),
                   subrole != (kAXSearchFieldSubrole as String) {
                    initialTextFields.insert(current.element)
                }

                if role == (kAXBrowserRole as String)
                    || role == (kAXOutlineRole as String)
                    || role == (kAXTableRole as String)
                    || role == (kAXToolbarRole as String) {
                    continue
                }
                if current.depth < Self.maxTraversalDepth {
                    if current.depth == 0 {
                        for sheet in activeSheets(on: current.element) {
                            queue.append((sheet, 1))
                        }
                    }
                    for child in axAdapter.elementsAttribute(kAXChildrenAttribute as String, of: current.element) {
                        queue.append((child, current.depth + 1))
                    }
                }
            }
        }

        return NavigationBaseline(
            focusedBefore: focusedBefore,
            initialContainers: initialContainers,
            initialTextFields: initialTextFields
        )
    }

    private func pollForGoToFolderField(
        context: FileDialogContext,
        baseline: NavigationBaseline,
        generation: UInt64
    ) async -> FileDialogAXElement? {
        var elapsedNs: UInt64 = 0
        while elapsedNs <= pollTimeoutNanoseconds {
            guard navigationGeneration == generation else { return nil }
            if let candidate = currentFocusedElement(for: context),
               isVerifiedGoToFolderField(candidate, baseline: baseline) {
                return candidate
            }
            if elapsedNs == pollTimeoutNanoseconds { break }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            elapsedNs += pollIntervalNanoseconds
        }
        return nil
    }

    private func currentFocusedElement(for context: FileDialogContext) -> FileDialogAXElement? {
        if let sysFocused = axAdapter.systemFocusedElement() {
            if let focusedPID = axAdapter.pid(of: sysFocused) {
                let ownPID = ProcessInfo.processInfo.processIdentifier
                if focusedPID == ownPID, context.appPID != ownPID {
                    return nil
                }
                if focusedPID == context.appPID
                    || focusedPID == context.servicePID
                    || axAdapter.bundleIdentifier(for: focusedPID) == Self.openAndSaveServiceBundleID {
                    return sysFocused
                }
            } else {
                // Allow mock elements without PIDs when systemFocusedElement returns a dialog element.
                return sysFocused
            }
        }
        return axAdapter.focusedElement(in: context.appPID)
    }

    private func isVerifiedGoToFolderField(
        _ candidate: FileDialogAXElement,
        baseline: NavigationBaseline
    ) -> Bool {
        if candidate == baseline.focusedBefore || baseline.initialTextFields.contains(candidate) {
            return false
        }

        let role = axAdapter.stringAttribute(kAXRoleAttribute as String, of: candidate)
        guard role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String) else {
            return false
        }
        let subrole = axAdapter.stringAttribute(kAXSubroleAttribute as String, of: candidate)
        guard subrole != (kAXSearchFieldSubrole as String) else {
            return false
        }
        guard axAdapter.boolAttribute(kAXEnabledAttribute as String, of: candidate) != false else {
            return false
        }

        if let id = axAdapter.stringAttribute(kAXIdentifierAttribute as String, of: candidate)?.lowercased(),
           Self.saveAsFieldIdentifiers.contains(id) {
            return false
        }

        if hasGoToFolderContextMarker(candidate) {
            return true
        }

        // Verify the field resides inside a newly opened sheet, popover, or sub-dialog.
        var cursor: FileDialogAXElement? = candidate
        for _ in 0..<Self.maxParentWalkHops {
            guard let parent = cursor.flatMap({
                axAdapter.elementAttribute(kAXParentAttribute as String, of: $0)
            }) else { break }
            let parentRole = axAdapter.stringAttribute(kAXRoleAttribute as String, of: parent)
            if parentRole == (kAXPopoverRole as String) {
                return true
            }
            if (parentRole == (kAXSheetRole as String) || parentRole == (kAXWindowRole as String)) {
                if !baseline.initialContainers.contains(parent) {
                    return true
                }
                if hasGoToFolderContextMarker(parent) {
                    return true
                }
                // Reached a pre-existing window/sheet without Go-to-Folder context -> reject Save-As field.
                return false
            }
            if hasGoToFolderContextMarker(parent) {
                return true
            }
            cursor = parent
        }
        return false
    }

    private func hasGoToFolderContextMarker(_ element: FileDialogAXElement) -> Bool {
        let texts = [
            axAdapter.stringAttribute(kAXIdentifierAttribute as String, of: element),
            axAdapter.stringAttribute(kAXPlaceholderValueAttribute as String, of: element),
            axAdapter.stringAttribute(kAXDescriptionAttribute as String, of: element),
            axAdapter.stringAttribute(kAXTitleAttribute as String, of: element),
        ].compactMap { $0?.lowercased() }

        return texts.contains { text in
            text.contains("goto")
                || text.contains("go to")
                || text.contains("前往")
        }
    }

    private func setPathValue(_ targetPath: String, on field: FileDialogAXElement) -> Bool {
        if axAdapter.setStringAttribute(kAXValueAttribute as String, value: targetPath, on: field) {
            return true
        }
        if axAdapter.stringAttribute(kAXRoleAttribute as String, of: field) == (kAXComboBoxRole as String) {
            for child in axAdapter.elementsAttribute(kAXChildrenAttribute as String, of: field) {
                if axAdapter.stringAttribute(kAXRoleAttribute as String, of: child) == (kAXTextFieldRole as String),
                   axAdapter.setStringAttribute(kAXValueAttribute as String, value: targetPath, on: child) {
                    return true
                }
            }
        }
        return false
    }
}
