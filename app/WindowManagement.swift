import AppKit
import Combine

// Frames are in AppKit screen points (not backing pixels) unless named AX.
struct WindowLayoutPlanner {
    let displays: [Display]

    struct Display {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct Placement {
        let frame: CGRect
        // Exact restores have no single-display constraint, even after an app adjusts the size.
        let bounds: CGRect?

        // The app may enforce a minimum size; keep as much of it on screen as possible.
        func position(for size: CGSize) -> CGPoint {
            guard let bounds else { return frame.origin }
            return Self.clamp(CGRect(origin: frame.origin, size: size), to: bounds).origin
        }

        static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
            let x = min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
            let y = min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
            return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
        }
    }

    // The first screen, not NSScreen.main or the union of screens, defines AX's Y origin.
    // Reflect the far edge so the rect's origin changes from bottom-left to top-left.
    func axFrame(_ appKitFrame: CGRect) -> CGRect { flip(appKitFrame) }
    func appKitFrame(_ axFrame: CGRect) -> CGRect { flip(axFrame) }

    private func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (displays.first?.frame.maxY ?? 0) - rect.maxY,
               width: rect.width, height: rect.height)
    }

    func placement(for command: WindowCommand, currentAX: CGRect, previousAX: CGRect? = nil) -> Placement? {
        let current = appKitFrame(currentAX)
        let reference: CGRect
        if command == .restore {
            guard let previousAX else { return nil }
            reference = appKitFrame(previousAX)
            if isCoveredByVisibleFrames(reference) {
                return Placement(frame: previousAX, bounds: nil)
            }
        } else {
            reference = current
        }
        guard let index = displayIndex(for: reference) else { return nil }
        let visible = displays[index].visibleFrame
        var bounds = visible
        let frame: CGRect
        switch command {
        case .leftHalf, .rightHalf:
            let split = visible.minX + floor(visible.width / 2)
            frame = command == .leftHalf
                ? CGRect(x: visible.minX, y: visible.minY, width: split - visible.minX, height: visible.height)
                : CGRect(x: split, y: visible.minY, width: visible.maxX - split, height: visible.height)
        case .topHalf, .bottomHalf:
            let split = visible.minY + floor(visible.height / 2)
            frame = command == .topHalf
                ? CGRect(x: visible.minX, y: split, width: visible.width, height: visible.maxY - split)
                : CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: split - visible.minY)
        case .maximize: frame = visible
        case .center: frame = centered(size: fit(current.size, in: visible), in: visible)
        case .almostMaximize, .reasonableSize:
            let ratio: CGFloat = command == .almostMaximize ? 0.9 : 2.0 / 3.0
            frame = centered(size: CGSize(width: floor(visible.width * ratio), height: floor(visible.height * ratio)), in: visible)
        case .nextDisplay, .previousDisplay:
            guard displays.count > 1 else { return nil }
            let step = command == .nextDisplay ? 1 : -1
            bounds = displays[(index + step + displays.count) % displays.count].visibleFrame
            let size = fit(current.size, in: bounds)
            let x = fraction(current.minX - visible.minX, over: visible.width - current.width)
            let y = fraction(current.minY - visible.minY, over: visible.height - current.height)
            frame = CGRect(x: bounds.minX + round(x * (bounds.width - size.width)),
                           y: bounds.minY + round(y * (bounds.height - size.height)),
                           width: size.width, height: size.height)
        case .restore:
            // Recover a saved frame that is no longer fully visible on the connected displays.
            frame = CGRect(origin: reference.origin, size: fit(reference.size, in: bounds))
        }
        return Placement(frame: Placement.clamp(axFrame(frame), to: axFrame(bounds)), bounds: axFrame(bounds))
    }

    private func isCoveredByVisibleFrames(_ frame: CGRect) -> Bool {
        let intersections = displays.map { $0.visibleFrame.intersection(frame) }
            .filter { !$0.isEmpty }.sorted { $0.minY < $1.minY }
        let edges = ([frame.minX, frame.maxX] + intersections.flatMap { [$0.minX, $0.maxX] }).sorted()
        // Within each vertical strip the covering displays don't change. Merge their Y intervals
        // rather than counting overlaps twice or treating gaps inside a bounding box as visible.
        for (left, right) in zip(edges, edges.dropFirst()) where left < right {
            var coveredY = frame.minY
            for rect in intersections where rect.minX <= left && rect.maxX >= right {
                if rect.minY > coveredY { break }
                coveredY = max(coveredY, rect.maxY)
                if coveredY >= frame.maxY { break }
            }
            if coveredY < frame.maxY { return false }
        }
        return !frame.isEmpty
    }

    private func displayIndex(for rect: CGRect) -> Int? {
        // Prefer largest overlap, then nearest screen for detached/offscreen windows.
        displays.indices.min { lhs, rhs in
            func rank(_ index: Int) -> (CGFloat, CGFloat, Int) {
                let screen = displays[index].frame
                let intersection = screen.intersection(rect)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                let dx = max(screen.minX - rect.midX, rect.midX - screen.maxX, 0)
                let dy = max(screen.minY - rect.midY, rect.midY - screen.maxY, 0)
                return (-area, dx * dx + dy * dy, index)
            }
            return rank(lhs) < rank(rhs)
        }
    }

    private func fit(_ size: CGSize, in bounds: CGRect) -> CGSize {
        CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
    }

    private func centered(size: CGSize, in bounds: CGRect) -> CGRect {
        CGRect(x: round(bounds.midX - size.width / 2), y: round(bounds.midY - size.height / 2),
               width: size.width, height: size.height)
    }

    private func fraction(_ offset: CGFloat, over travel: CGFloat) -> CGFloat {
        travel > 0 ? min(max(offset / travel, 0), 1) : 0.5
    }
}

enum WindowCommand: String {
    case leftHalf = "left-half", rightHalf = "right-half", topHalf = "top-half", bottomHalf = "bottom-half"
    case maximize, center, almostMaximize = "almost-maximize", reasonableSize = "reasonable-size"
    case nextDisplay = "next-display", previousDisplay = "previous-display", restore
}

enum WindowActionIssue: Error, Equatable {
    case permissionRequired, noWindow, noPreviousFrame, noOtherDisplay, couldNotMove

    @MainActor func title(_ model: Launcher) -> String {
        switch self {
        case .permissionRequired: return model.t("窗口管理需要辅助功能权限", "Window management needs Accessibility access")
        case .noWindow: return model.t("没有可调整的窗口", "No resizable window in the previous app")
        case .noPreviousFrame: return model.t("此窗口没有可恢复的位置和大小", "No previous frame for this window")
        case .noOtherDisplay: return model.t("没有其他显示器", "No other display")
        case .couldNotMove: return model.t("此窗口无法应用所选布局", "This window could not apply the requested layout")
        }
    }
}

@MainActor
final class WindowManagement: ObservableObject {
    static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @Published private(set) var isTrusted: Bool?
    @Published var issue: WindowActionIssue?
    private(set) var targetPID: pid_t?

    private let frontmostPID: () -> pid_t?
    private let layout: () -> WindowLayoutPlanner
    private let checkTrust: () -> Bool
    private let openSettings: (URL) -> Void
    private let execute: (WindowCommand, pid_t?, WindowLayoutPlanner, @escaping (WindowActionIssue?) -> Void) -> Void

    convenience init() {
        self.init(adapter: NativeWindowAccessAdapter(), frontmostPID: {
            guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else { return nil }
            if let lumenID = Bundle.main.bundleIdentifier, app.bundleIdentifier == lumenID { return nil }
            return app.processIdentifier
        }, layout: {
            WindowLayoutPlanner(displays: NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) })
        }, openSettings: { _ = LaunchDispatcher.openSettings($0) })
    }

    init<Adapter: WindowAccessAdapter>(adapter: Adapter, frontmostPID: @escaping () -> pid_t?,
                                      layout: @escaping () -> WindowLayoutPlanner, openSettings: @escaping (URL) -> Void) {
        self.frontmostPID = frontmostPID
        self.layout = layout
        self.openSettings = openSettings
        checkTrust = { adapter.isTrusted() }
        let access = AXWindowAccess(adapter: adapter)
        // Serialize remote calls and frame history without blocking AppKit on another process.
        let queue = DispatchQueue(label: "io.github.surfire.lumen.window-access", qos: .userInitiated)
        execute = { command, pid, planner, completion in
            queue.async {
                let issue = access.perform(command, targetPID: pid, planner: planner)
                DispatchQueue.main.async { completion(issue) }
            }
        }
    }

    func captureTarget() {
        targetPID = frontmostPID().flatMap { $0 == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
    }

    func refreshTrust() {
        updateTrust(checkTrust())
    }

    func perform(_ command: WindowCommand, completion: @escaping (WindowActionIssue?) -> Void) {
        execute(command, targetPID, layout()) { [weak self] issue in
            self?.updateTrust(issue != .permissionRequired)
            completion(issue)
        }
    }

    private func updateTrust(_ trusted: Bool) {
        if isTrusted != trusted { isTrusted = trusted }
        if trusted, issue == .permissionRequired { issue = nil }
    }

    func openAccessibilitySettings() { openSettings(Self.accessibilityURL) }
}
