import ApplicationServices
import Foundation

protocol WindowAccessAdapter: Sendable {
    associatedtype Window: Hashable

    // A non-prompting local query, callable independently of remote AX operations.
    func isTrusted() -> Bool
    func windows(in pid: pid_t) -> (focused: Window?, main: Window?)
    func inspect(_ window: Window) -> WindowAttributes?
    func frame(of window: Window) -> CGRect?
    func setPosition(_ position: CGPoint, of window: Window) -> Bool
    func setSize(_ size: CGSize, of window: Window) -> Bool
}

struct WindowAttributes {
    let role: String?
    let subrole: String?
    let minimized: Bool
    let fullScreen: Bool
    let positionSettable: Bool
    let sizeSettable: Bool
    let frame: CGRect

    var isEligible: Bool {
        // Sheets, drawers, popovers and dialogs are not standard windows.
        role == kAXWindowRole as String && subrole == kAXStandardWindowSubrole as String
            && !minimized && !fullScreen && positionSettable && sizeSettable && Self.isValid(frame)
    }

    static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }
}

// History is confined to WindowManagement's serial worker (or one synchronous unit test).
final class AXWindowAccess<Adapter: WindowAccessAdapter>: @unchecked Sendable {
    private let adapter: Adapter
    // AXUIElement hashes/compares by element identity, not by title or Swift object identity.
    private var history: [(window: Adapter.Window, frame: CGRect)] = []
    private let capacity = 32

    init(adapter: Adapter) { self.adapter = adapter }

    func perform(_ command: WindowCommand, targetPID: pid_t?, planner: WindowLayoutPlanner) -> WindowActionIssue? {
        guard adapter.isTrusted() else { return .permissionRequired }
        guard let targetPID, let (window, original) = eligibleWindow(in: targetPID) else { return .noWindow }
        var previous: CGRect?
        if command == .restore {
            guard let index = history.firstIndex(where: { $0.window == window }) else { return .noPreviousFrame }
            let entry = history.remove(at: index)
            history.append(entry)
            previous = entry.frame
        }
        if command == .nextDisplay || command == .previousDisplay, planner.displays.count < 2 { return .noOtherDisplay }
        guard let placement = planner.placement(for: command, currentAX: original, previousAX: previous) else {
            return .couldNotMove
        }
        if approximatelyEqual(original, placement.frame) {
            if command == .restore { forget(window) }
            return nil
        }

        // Move first so the destination display constrains the resize, then correct any
        // origin shift from the app or WindowServer when the new size was applied.
        let moved = adapter.setPosition(placement.frame.origin, of: window)
        let resized = adapter.setSize(placement.frame.size, of: window)
        let size = validFrame(of: window)?.size ?? placement.frame.size
        let positioned = adapter.setPosition(placement.position(for: size), of: window)
        let actual = validFrame(of: window)
        let applied = actual.map { approximatelyEqual($0, placement.frame) } ?? false
        if command == .restore {
            if applied { forget(window) }
        } else if actual.map({ $0 != original }) ?? (moved || resized || positioned) {
            // Even if the app refused part of the layout, a partial move can be undone.
            forget(window)
            history.append((window, original))
            if history.count > capacity { history.removeFirst() }
        }
        return applied ? nil : .couldNotMove
    }

    private func eligibleWindow(in pid: pid_t) -> (Adapter.Window, CGRect)? {
        let (focused, main) = adapter.windows(in: pid)
        if let focused, let attributes = adapter.inspect(focused), attributes.isEligible { return (focused, attributes.frame) }
        if let main, main != focused, let attributes = adapter.inspect(main), attributes.isEligible { return (main, attributes.frame) }
        return nil
    }

    private func validFrame(of window: Adapter.Window) -> CGRect? {
        guard let frame = adapter.frame(of: window), WindowAttributes.isValid(frame) else { return nil }
        return frame
    }

    private func forget(_ window: Adapter.Window) {
        history.removeAll { $0.window == window }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }
}

struct NativeWindowAccessAdapter: WindowAccessAdapter {
    private static let position = kAXPositionAttribute as String
    private static let size = kAXSizeAttribute as String

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func windows(in pid: pid_t) -> (focused: AXUIElement?, main: AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let values = attributes([kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String], of: app) else {
            return (nil, nil)
        }
        return (element(values[0]), element(values[1]))
    }

    func inspect(_ window: AXUIElement) -> WindowAttributes? {
        // AXFullScreen is used by AppKit but has no public attribute constant.
        guard let values = attributes([kAXRoleAttribute as String, kAXSubroleAttribute as String,
                                       kAXMinimizedAttribute as String, "AXFullScreen", Self.position, Self.size], of: window),
              let frame = rect(position: values[4], size: values[5]) else { return nil }
        let role = values[0] as? String
        let subrole = values[1] as? String
        let minimized = values[2] as? Bool ?? false
        let fullScreen = values[3] as? Bool ?? false
        guard role == kAXWindowRole as String, subrole == kAXStandardWindowSubrole as String,
              !minimized, !fullScreen else { return nil }
        return WindowAttributes(role: role, subrole: subrole, minimized: minimized, fullScreen: fullScreen,
                                positionSettable: isSettable(Self.position, of: window),
                                sizeSettable: isSettable(Self.size, of: window), frame: frame)
    }

    func frame(of window: AXUIElement) -> CGRect? {
        guard let values = attributes([Self.position, Self.size], of: window) else { return nil }
        return rect(position: values[0], size: values[1])
    }

    func setPosition(_ position: CGPoint, of window: AXUIElement) -> Bool {
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, Self.position as CFString, value) == .success
    }

    func setSize(_ size: CGSize, of window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, Self.size as CFString, value) == .success
    }

    private func isSettable(_ attribute: String, of element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private func attributes(_ names: [String], of element: AXUIElement) -> [CFTypeRef]? {
        var result: CFArray?
        // Without StopOnError, unsupported attributes are returned as AXValue errors in their slots.
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success,
              let values = result as? [CFTypeRef], values.count == names.count else { return nil }
        return values
    }

    private func element(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 1.0)
        return element
    }

    private func rect(position: CFTypeRef, size: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var sizeValue = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &sizeValue) else { return nil }
        return CGRect(origin: point, size: sizeValue)
    }
}
