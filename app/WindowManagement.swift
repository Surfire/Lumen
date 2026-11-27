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
        case .topThird, .middleThird, .bottomThird, .topTwoThirds, .bottomTwoThirds:
            let split1 = visible.minY + floor(visible.height / 3)
            let split2 = visible.minY + floor(visible.height * 2 / 3)
            let band: (CGFloat, CGFloat)
            switch command {
            case .topThird: band = (split2, visible.maxY)
            case .middleThird: band = (split1, split2)
            case .bottomThird: band = (visible.minY, split1)
            case .topTwoThirds: band = (split1, visible.maxY)
            default: band = (visible.minY, split2)
            }
            frame = CGRect(x: visible.minX, y: band.0, width: visible.width, height: band.1 - band.0)
        case .autoTile:
            // Multi-window layout: see autoTilePlan(windowCount:on:).
            return nil
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

    // Cells for `windowCount` windows on one display, in AX coordinates, ordered top-to-bottom then
    // left-to-right. Fewer cells than windows means the extra windows are left alone.
    func autoTilePlan(windowCount: Int, on displayIndex: Int) -> [CGRect] {
        guard windowCount > 0, displays.indices.contains(displayIndex) else { return [] }
        let visible = displays[displayIndex].visibleFrame
        let isPortrait = visible.height > visible.width
        let cells: [CGRect]
        switch windowCount {
        case 1:
            cells = [visible.width >= 1700
                ? centered(size: CGSize(width: floor(visible.width * 0.9), height: floor(visible.height * 0.9)), in: visible)
                : visible]
        case 2:
            cells = isPortrait ? Self.rows(2, in: visible) : Self.columns(2, in: visible)
        case 3:
            if isPortrait {
                cells = Self.rows(3, in: visible)
            } else if visible.width >= 2200 || visible.width / max(visible.height, 1) >= 2.0 {
                cells = Self.columns(3, in: visible)
            } else {
                let split = visible.minX + floor(visible.width * 0.55)
                let right = CGRect(x: split, y: visible.minY, width: visible.maxX - split, height: visible.height)
                cells = [CGRect(x: visible.minX, y: visible.minY, width: split - visible.minX, height: visible.height)]
                    + Self.rows(2, in: right)
            }
        case 4:
            // Four stacked bands keep a narrow portrait display usable; otherwise a 2x2 grid.
            cells = isPortrait && visible.width < 1000 ? Self.rows(4, in: visible) : Self.grid(columns: 2, rows: 2, in: visible)
        default:
            guard visible.width >= 2000 && !isPortrait else { return autoTilePlan(windowCount: 4, on: displayIndex) }
            cells = Array(Self.grid(columns: 3, rows: 2, in: visible).prefix(windowCount))
        }
        let bounds = axFrame(visible)
        return cells.map { Placement.clamp(axFrame($0), to: bounds) }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    // AppKit-coordinate slices of `rect`; the last slice absorbs the rounding remainder.
    private static func columns(_ count: Int, in rect: CGRect) -> [CGRect] {
        (0..<count).map { index in
            let minX = rect.minX + floor(rect.width * CGFloat(index) / CGFloat(count))
            let maxX = index == count - 1 ? rect.maxX : rect.minX + floor(rect.width * CGFloat(index + 1) / CGFloat(count))
            return CGRect(x: minX, y: rect.minY, width: maxX - minX, height: rect.height)
        }
    }

    // Top to bottom (AppKit's Y grows upward).
    private static func rows(_ count: Int, in rect: CGRect) -> [CGRect] {
        (0..<count).map { index in
            let maxY = index == 0 ? rect.maxY : rect.maxY - floor(rect.height * CGFloat(index) / CGFloat(count))
            let minY = index == count - 1 ? rect.minY : rect.maxY - floor(rect.height * CGFloat(index + 1) / CGFloat(count))
            return CGRect(x: rect.minX, y: minY, width: rect.width, height: maxY - minY)
        }
    }

    private static func grid(columns: Int, rows: Int, in rect: CGRect) -> [CGRect] {
        Self.rows(rows, in: rect).flatMap { Self.columns(columns, in: $0) }
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

    func displayIndex(for rect: CGRect) -> Int? {
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
    case autoTile = "auto-tile"
    case topThird = "top-third", middleThird = "middle-third", bottomThird = "bottom-third"
    case topTwoThirds = "top-two-thirds", bottomTwoThirds = "bottom-two-thirds"
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
    private let detectPortrait: (pid_t?) -> Bool
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
                                      layout: @escaping () -> WindowLayoutPlanner, openSettings: @escaping (URL) -> Void,
                                      detectPortrait: @escaping (pid_t?) -> Bool = WindowManagement.activeDisplayIsPortrait(for:)) {
        self.frontmostPID = frontmostPID
        self.layout = layout
        self.openSettings = openSettings
        self.detectPortrait = detectPortrait
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

    /// Orientation of the display a window command would act on: the target app's front window,
    /// else the display under the mouse, else the main display.
    nonisolated static func activeDisplayIsPortrait(for targetPID: pid_t?) -> Bool {
        let screens = NSScreen.screens
        var screen: NSScreen?
        if let targetPID, let primary = screens.first,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == targetPID
                && (info[kCGWindowLayer as String] as? Int) == 0 {
                guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dictionary), !bounds.isEmpty else { continue }
                let appKit = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
                screen = screens.max { overlap($0.frame, appKit) < overlap($1.frame, appKit) }
                break
            }
        }
        if screen == nil {
            let mouse = NSEvent.mouseLocation
            screen = screens.first { $0.frame.contains(mouse) }
        }
        guard let visible = (screen ?? NSScreen.main ?? screens.first)?.visibleFrame else { return false }
        return visible.height > visible.width
    }

    private nonisolated static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    func activeDisplayIsPortrait(for targetPID: pid_t?) -> Bool { detectPortrait(targetPID) }

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
