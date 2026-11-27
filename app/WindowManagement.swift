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

    enum AutoTileLayout: Equatable {
        case single(CGRect)
        case columns([CGRect])
        case rows([CGRect])
        case masterStack(master: CGRect, stack: [CGRect])
        case grid(columns: Int, rows: Int, cells: [CGRect])

        var cells: [CGRect] {
            switch self {
            case .single(let rect): return [rect]
            case .columns(let rects), .rows(let rects): return rects
            case .masterStack(let master, let stack): return [master] + stack
            case .grid(_, _, let cells): return cells
            }
        }
    }

    // Cells for `windowCount` windows on one display, in AX coordinates, ordered top-to-bottom then
    // left-to-right (and master-first for 3-window master+stack).
    func autoTilePlan(windowCount: Int, on displayIndex: Int) -> [CGRect] {
        autoTileLayout(windowCount: windowCount, on: displayIndex)?.cells ?? []
    }

    func autoTileLayout(windowCount: Int, on displayIndex: Int) -> AutoTileLayout? {
        guard windowCount > 0, displays.indices.contains(displayIndex) else { return nil }
        let visible = displays[displayIndex].visibleFrame
        let bounds = axFrame(visible)
        let isPortrait = visible.height > visible.width
        let clamp: ([CGRect]) -> [CGRect] = { rects in
            rects.map { Placement.clamp(self.axFrame($0), to: bounds) }
        }
        switch windowCount {
        case 1:
            let rect = visible.width >= 1700
                ? centered(size: CGSize(width: floor(visible.width * 0.9), height: floor(visible.height * 0.9)), in: visible)
                : visible
            return .single(Placement.clamp(axFrame(rect), to: bounds))
        case 2:
            if isPortrait {
                return .rows(clamp(Self.rows(2, in: visible)))
            }
            return .columns(clamp(Self.columns(2, in: visible)))
        case 3:
            if isPortrait {
                return .rows(clamp(Self.rows(3, in: visible)))
            } else if visible.width >= 2200 || visible.width / max(visible.height, 1) >= 2.0 {
                return .columns(clamp(Self.columns(3, in: visible)))
            } else {
                let split = visible.minX + floor(visible.width * 0.55)
                let left = CGRect(x: visible.minX, y: visible.minY, width: split - visible.minX, height: visible.height)
                let right = CGRect(x: split, y: visible.minY, width: visible.maxX - split, height: visible.height)
                return .masterStack(master: Placement.clamp(axFrame(left), to: bounds),
                                    stack: clamp(Self.rows(2, in: right)))
            }
        case 4:
            // Four stacked bands keep a narrow portrait display usable; otherwise a 2x2 grid.
            if isPortrait && visible.width < 1000 {
                return .rows(clamp(Self.rows(4, in: visible)))
            }
            return .grid(columns: 2, rows: 2, cells: clamp(Self.grid(columns: 2, rows: 2, in: visible)))
        default:
            guard visible.width >= 2000 && !isPortrait else { return autoTileLayout(windowCount: 4, on: displayIndex) }
            let cells = Array(Self.grid(columns: 3, rows: 2, in: visible).prefix(windowCount))
            return .grid(columns: 3, rows: 2, cells: clamp(cells))
        }
    }

    /// Rebalances flexible window slots in AX coordinates when any app enforces a larger minimum size.
    /// Returns `nil` when all windows already fit within `<= 4pt` of their initial cells.
    func reflow(_ layout: AutoTileLayout, actualSizes: [CGSize], bounds: CGRect) -> [CGRect]? {
        switch layout {
        case .single:
            return nil
        case .columns(let cells):
            guard actualSizes.count == cells.count,
                  let widths = Self.distribute1D(total: bounds.width, initial: cells.map(\.width),
                                                 actual: actualSizes.map(\.width), minFlexible: 240) else { return nil }
            var x = bounds.minX
            return widths.map { width in
                let rect = Placement.clamp(CGRect(x: x, y: bounds.minY, width: width, height: bounds.height), to: bounds)
                x = min(x + width, bounds.maxX)
                return rect
            }
        case .rows(let cells):
            guard actualSizes.count == cells.count,
                  let heights = Self.distribute1D(total: bounds.height, initial: cells.map(\.height),
                                                  actual: actualSizes.map(\.height), minFlexible: 180) else { return nil }
            var y = bounds.minY
            return heights.map { height in
                let rect = Placement.clamp(CGRect(x: bounds.minX, y: y, width: bounds.width, height: height), to: bounds)
                y = min(y + height, bounds.maxY)
                return rect
            }
        case .masterStack(let master, let stack):
            guard stack.count == 2, actualSizes.count == 3 else { return nil }
            let colW = Self.distribute1D(total: bounds.width,
                                          initial: [master.width, stack[0].width],
                                          actual: [actualSizes[0].width, max(actualSizes[1].width, actualSizes[2].width)],
                                          minFlexible: 280)
            let rowH = Self.distribute1D(total: bounds.height,
                                          initial: [stack[0].height, stack[1].height],
                                          actual: [actualSizes[1].height, actualSizes[2].height],
                                          minFlexible: 180)
            guard colW != nil || rowH != nil else { return nil }
            let w0 = colW?[0] ?? master.width
            let w1 = colW?[1] ?? stack[0].width
            let h1 = rowH?[0] ?? stack[0].height
            let h2 = rowH?[1] ?? stack[1].height
            let rightX = min(bounds.minX + w0, max(bounds.minX, bounds.maxX - w1))
            let bottomY = min(bounds.minY + h1, max(bounds.minY, bounds.maxY - h2))
            return [
                Placement.clamp(CGRect(x: bounds.minX, y: bounds.minY, width: w0, height: bounds.height), to: bounds),
                Placement.clamp(CGRect(x: rightX, y: bounds.minY, width: w1, height: h1), to: bounds),
                Placement.clamp(CGRect(x: rightX, y: bottomY, width: w1, height: h2), to: bounds),
            ]
        case .grid(let columns, let rows, let cells):
            guard columns > 0, rows > 0, !actualSizes.isEmpty, actualSizes.count <= cells.count else { return nil }
            let initColW = (0..<columns).map { cells[$0].width }
            let actColW = (0..<columns).map { col in
                (0..<rows).compactMap { row -> CGFloat? in
                    let idx = row * columns + col
                    return idx < actualSizes.count ? actualSizes[idx].width : nil
                }.max() ?? initColW[col]
            }
            let initRowH = (0..<rows).map { cells[$0 * columns].height }
            let actRowH = (0..<rows).map { row in
                (0..<columns).compactMap { col -> CGFloat? in
                    let idx = row * columns + col
                    return idx < actualSizes.count ? actualSizes[idx].height : nil
                }.max() ?? initRowH[row]
            }
            let colW = Self.distribute1D(total: bounds.width, initial: initColW, actual: actColW, minFlexible: 240)
            let rowH = Self.distribute1D(total: bounds.height, initial: initRowH, actual: actRowH, minFlexible: 180)
            guard colW != nil || rowH != nil else { return nil }
            let finalW = colW ?? initColW
            let finalH = rowH ?? initRowH
            var result: [CGRect] = []
            var y = bounds.minY
            for row in 0..<rows {
                var x = bounds.minX
                let h = finalH[row]
                for col in 0..<columns {
                    if result.count == actualSizes.count { return result }
                    let w = finalW[col]
                    result.append(Placement.clamp(CGRect(x: x, y: y, width: w, height: h), to: bounds))
                    x = min(x + w, bounds.maxX)
                }
                y = min(y + h, bounds.maxY)
            }
            return result
        }
    }

    private static func distribute1D(total: CGFloat, initial: [CGFloat], actual: [CGFloat], minFlexible: CGFloat) -> [CGFloat]? {
        guard initial.count == actual.count, !initial.isEmpty else { return nil }
        var constrained = Set<Int>()
        for index in initial.indices where actual[index] > initial[index] + 4 {
            constrained.insert(index)
        }
        guard !constrained.isEmpty else { return nil }

        var result = Array(repeating: CGFloat(0), count: initial.count)
        var lockedSum: CGFloat = 0
        for index in constrained {
            let clamped = min(actual[index], total)
            result[index] = clamped
            lockedSum += clamped
        }
        let flexible = initial.indices.filter { !constrained.contains($0) }
        guard !flexible.isEmpty else { return result }

        let remaining = max(total - lockedSum, 0)
        if remaining > 0 {
            let floorMin = min(minFlexible, floor(remaining / CGFloat(flexible.count)))
            let weightSum = flexible.reduce(CGFloat(0)) { $0 + max(initial[$1], 1) }
            var allocated: CGFloat = 0
            for (pos, index) in flexible.enumerated() {
                let share: CGFloat
                if pos == flexible.count - 1 {
                    share = max(floor(remaining - allocated), floorMin)
                } else {
                    share = max(floor(remaining * max(initial[index], 1) / weightSum), floorMin)
                }
                result[index] = share
                allocated += share
            }
        } else {
            for index in flexible { result[index] = minFlexible }
        }
        return result
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
