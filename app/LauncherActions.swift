import AppKit
import Combine
import Darwin

struct LaunchAction: Equatable, Identifiable {
    enum Destination: Equatable {
        case application(URL, stamp: String), settings(URL), system(LauncherSystemActions.Operation), window(WindowCommand),
             executable(LauncherExecutable)
    }

    let id: String
    let english: String
    let chinese: String
    let symbol: String
    let destination: Destination
    let aliases: [String]
    let normalizedNames: [String]
    let normalizedSearchable: [String]

    init(id: String, english: String, chinese: String, symbol: String, destination: Destination, aliases: [String]) {
        self.id = id
        self.english = english
        self.chinese = chinese
        self.symbol = symbol
        self.destination = destination
        self.aliases = aliases
        let names = [english, chinese].map(LaunchCatalog.normalized)
        self.normalizedNames = names
        let derived = [english, chinese].flatMap(LaunchCatalog.initialsAliases)
            + names.flatMap(LaunchCatalog.curatedAppAliases)
        var seen = Set<String>()
        self.normalizedSearchable = (names + aliases.map(LaunchCatalog.normalized) + derived).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    func title(chinese useChinese: Bool) -> String { useChinese ? chinese : english }
}

actor ApplicationIcons {
    struct Key: Hashable, Sendable {
        let url: URL
        let stamp: String

        init?(_ action: LaunchAction) {
            guard case .application(let url, let stamp) = action.destination else { return nil }
            self.url = url
            self.stamp = stamp
        }
    }

    private enum Entry {
        case image(CGImage), unavailable
    }

    private let capacity = 64
    private var entries: [Key: Entry] = [:]
    private var recent: [Key] = []

    func image(for key: Key) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let entry = entries[key] ?? Self.readIcon(key).map(Entry.image) ?? .unavailable
        entries[key] = entry
        recent.removeAll { $0 == key }
        recent.append(key)
        if recent.count > capacity { entries.removeValue(forKey: recent.removeFirst()) }
        if case .image(let image) = entry { return image }
        return nil
    }

    private static func readIcon(_ key: Key) -> CGImage? {
        withNoDatalessMaterialization { () -> CGImage? in
            guard residentApplicationAttributes(key.url) != nil else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: key.url.path)
            var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
            return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }
}

@MainActor
final class ResultIconDisplay: ObservableObject {
    @Published private(set) var images: [ApplicationIcons.Key: CGImage] = [:]

    private let capacity = 64
    private let icons = ApplicationIcons()
    private var visible = Set<ApplicationIcons.Key>()
    private var tasks: [ApplicationIcons.Key: Task<Void, Never>] = [:]
    private var pendingImages: [ApplicationIcons.Key: CGImage] = [:]
    private var recent: [ApplicationIcons.Key] = []
    private var flushScheduled = false

    func cancelPending() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        pendingImages.removeAll()
        visible.removeAll()
    }

    func update(for matches: [ActionMatch]) {
        let keys = Set(matches.compactMap { ApplicationIcons.Key($0.action) })
        guard keys != visible else { return }
        for removed in visible.subtracting(keys) {
            tasks.removeValue(forKey: removed)?.cancel()
            pendingImages.removeValue(forKey: removed)
        }
        visible = keys
        for key in keys {
            if images[key] != nil {
                recent.removeAll { $0 == key }
                recent.append(key)
                continue
            }
            guard tasks[key] == nil else { continue }
            tasks[key] = Task { [weak self, icons] in
                let image = await icons.image(for: key)
                guard !Task.isCancelled, let self else { return }
                self.tasks[key] = nil
                guard self.visible.contains(key), let image else { return }
                self.pendingImages[key] = image
                self.scheduleFlush()
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushScheduled = false
        guard !pendingImages.isEmpty else { return }
        var next = images
        for (key, image) in pendingImages {
            next[key] = image
            recent.removeAll { $0 == key }
            recent.append(key)
        }
        pendingImages.removeAll()
        while recent.count > capacity,
              let oldestIndex = recent.firstIndex(where: { !visible.contains($0) }) {
            let evicted = recent.remove(at: oldestIndex)
            next.removeValue(forKey: evicted)
        }
        images = next
    }
}

struct ActionMatch: Equatable {
    let action: LaunchAction
    let score: Int
    var primary: Bool { score >= 80 }
}

struct DictionaryQuickResult: Equatable, Hashable, Sendable {
    let word: String
    let summary: String
    let fullText: String
    let subtitle: String
}

struct BookmarkHit: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let url: String
    let domain: String
    let browser: String
    let folderPath: String
}

struct ContactHit: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let fullName: String
    let subtitle: String
    let primaryPhone: String?
    let primaryEmail: String?
    let organization: String?
}

struct CalendarEventHit: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    let location: String?
    let meetingURL: String?
    let dateSummary: String
}

struct ReminderHit: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let dueDate: Date?
    let listTitle: String
    let notes: String?
    let priority: Int
    let dueSummary: String
    let isCompleted: Bool
}

enum LauncherResult: Identifiable, Equatable {
    case file(SearchHit), action(LaunchAction), shortcut(SavedShortcut), calculation(CalculationResult)
    case dictionary(DictionaryQuickResult), bookmark(BookmarkHit), contact(ContactHit)
    case calendarEvent(CalendarEventHit), reminder(ReminderHit)
    case snippet(SavedSnippet), finderFolder(OpenFinderFolder)

    var id: String {
        switch self {
        case .file(let hit): return hit.path
        case .action(let action): return action.id
        case .shortcut(let shortcut): return shortcut.rowID
        case .calculation: return "calculation"
        case .dictionary(let d): return "dict:\(d.word.lowercased())"
        case .bookmark(let b): return "bm:\(b.id)"
        case .contact(let c): return "contact:\(c.id)"
        case .calendarEvent(let e): return "event:\(e.id)"
        case .reminder(let r): return "rem:\(r.id)"
        case .snippet(let snippet): return snippet.rowID
        case .finderFolder(let folder): return "finder:\(folder.path)"
        }
    }
}

enum LaunchCatalog {
    static let settingsBundleID = "com.apple.systempreferences"

    static func systemActions() -> [LaunchAction] {
        let panels: [(String, String, String, String, [String])] = [
            ("", "System Settings", "系统设置", "gearshape", ["settings", "preferences", "系统偏好设置", "设置"]),
            ("com.apple.wifi-settings-extension", "Wi-Fi", "无线局域网", "wifi", ["wifi", "wireless", "无线网络", "无线", "wlan"]),
            ("com.apple.BluetoothSettings", "Bluetooth", "蓝牙", "wave.3.right", ["bt"]),
            ("com.apple.Network-Settings.extension", "Network", "网络", "network", ["network settings"]),
            ("com.apple.Displays-Settings.extension", "Displays", "显示器", "display", ["display", "screen", "显示设置", "屏幕"]),
            ("com.apple.Sound-Settings.extension", "Sound", "声音", "speaker.wave.2", ["audio", "volume", "音量", "音频"]),
            ("com.apple.Keyboard-Settings.extension", "Keyboard", "键盘", "keyboard", []),
            ("com.apple.Trackpad-Settings.extension", "Trackpad", "触控板", "trackpad", ["触摸板"]),
            ("com.apple.Notifications-Settings.extension", "Notifications", "通知", "bell", ["notification"]),
            ("com.apple.Appearance-Settings.extension", "Appearance", "外观", "circle.lefthalf.filled", []),
            ("com.apple.settings.PrivacySecurity.extension", "Privacy & Security", "隐私与安全性", "lock.shield", ["privacy", "security", "隐私", "安全"]),
            ("com.apple.Accessibility-Settings.extension", "Accessibility", "辅助功能", "accessibility", ["辅助"]),
            ("com.apple.Software-Update-Settings.extension", "Software Update", "软件更新", "arrow.down.circle", ["macos update", "系统更新"]),
            ("com.apple.settings.Storage", "Storage", "储存空间", "internaldrive", ["磁盘空间", "存储空间"]),
        ]
        let settings = panels.map { identifier, english, chinese, icon, aliases in
            // These destinations are fixed. Search text is never interpolated into a URL.
            let url = URL(string: "x-apple.systempreferences:" + identifier)!
            return LaunchAction(id: "settings:" + identifier, english: english, chinese: chinese, symbol: icon,
                                destination: .settings(url),
                                aliases: aliases + [english + " settings", chinese + "设置"] + pinyinAliases(chinese))
        }
        let operations: [(String, String, String, String, [String], LauncherSystemActions.Operation)] = [
            ("lock", "Lock Screen", "锁定屏幕", "lock", ["lock", "锁屏", "suoping"], .lock),
            ("sleep", "Sleep", "睡眠", "moon.zzz", ["sleep mac", "休眠", "xiumian"], .sleep),
            ("empty-trash", "Empty Trash", "清倒废纸篓", "trash", ["empty bin", "清空废纸篓", "qingkongfeizhilou"], .emptyTrash),
            ("dark-mode", "Toggle Dark Mode", "切换深色模式", "circle.lefthalf.filled", ["dark mode", "深色模式", "shensemoshi"], .darkMode),
            ("mute", "Mute Audio", "静音", "speaker.slash", ["mute"], .mute),
            ("unmute", "Unmute Audio", "取消静音", "speaker.wave.2", ["unmute"], .unmute),
            ("eject", "Eject External Volume", "推出外置卷", "eject", ["eject", "推出磁盘", "tuichucipan"], .eject),
        ]
        return settings + operations.map { id, english, chinese, symbol, aliases, operation in
            LaunchAction(id: "system:" + id, english: english, chinese: chinese, symbol: symbol,
                         destination: .system(operation), aliases: aliases + pinyinAliases(chinese))
        } + windowActions()
    }

    private static func windowActions() -> [LaunchAction] {
        let commands: [(WindowCommand, String, String, String, [String])] = [
            (.autoTile, "Auto-Tile Windows", "智能自动分屏", "rectangle.grid.2x2", ["auto tile", "tile all", "tile windows", "arrange windows", "auto layout", "自动平铺", "整理窗口", "自动分屏"]),
            (.leftHalf, "Left Half", "左半屏", "rectangle.lefthalf.filled", ["tile left", "window left"]),
            (.rightHalf, "Right Half", "右半屏", "rectangle.righthalf.filled", ["tile right", "window right"]),
            (.topHalf, "Top Half", "上半屏", "rectangle.tophalf.filled", ["tile top", "window top"]),
            (.bottomHalf, "Bottom Half", "下半屏", "rectangle.bottomhalf.filled", ["tile bottom", "window bottom"]),
            (.topThird, "Top Third", "上三分之一", "rectangle.topthird.inset.filled", ["third top", "tile top third", "上1/3", "上三分一"]),
            (.middleThird, "Middle Third", "中间三分之一", "rectangle.center.inset.filled", ["third middle", "tile middle third", "中1/3", "中三分一"]),
            (.bottomThird, "Bottom Third", "下三分之一", "rectangle.bottomthird.inset.filled", ["third bottom", "tile bottom third", "下1/3", "下三分一"]),
            (.topTwoThirds, "Top Two Thirds", "上三分之二", "rectangle.tophalf.inset.filled", ["two thirds top", "top 2/3", "上2/3", "上三分二"]),
            (.bottomTwoThirds, "Bottom Two Thirds", "下三分之二", "rectangle.bottomhalf.inset.filled", ["two thirds bottom", "bottom 2/3", "下2/3", "下三分二"]),
            (.maximize, "Maximize", "最大化", "arrow.up.left.and.arrow.down.right", ["max", "maximize window"]),
            (.center, "Center", "居中", "rectangle.center.inset.filled", ["centre", "center window", "窗口居中"]),
            (.almostMaximize, "Almost Maximize", "接近最大化", "arrow.up.left.and.arrow.down.right", ["almost max"]),
            (.reasonableSize, "Reasonable Size", "合适大小", "macwindow", ["reasonable", "resize window"]),
            (.nextDisplay, "Next Display", "移至下一屏幕", "arrow.right.to.line", ["next screen", "下一屏"]),
            (.previousDisplay, "Previous Display", "移至上一屏幕", "arrow.left.to.line", ["previous screen", "上一屏"]),
            (.restore, "Restore Previous Frame", "恢复原窗口大小", "arrow.uturn.backward", ["restore", "undo window move", "恢复窗口"]),
        ]
        return commands.map { command, english, chinese, symbol, aliases in
            LaunchAction(id: "window:" + command.rawValue, english: english, chinese: chinese, symbol: symbol,
                         destination: .window(command), aliases: aliases + pinyinAliases(chinese))
        }
    }

    /// Window actions for the `win` command: auto-tile first, then the splits that suit the display.
    static func windowActions(isPortrait: Bool, query: String = "") -> [LaunchAction] {
        let all = windowActions()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            return matches(term, actions: all, includeDictionary: false).map(\.action)
        }
        let portrait: [WindowCommand] = [.autoTile, .topHalf, .bottomHalf, .topThird, .middleThird, .bottomThird,
                                         .topTwoThirds, .bottomTwoThirds, .maximize, .center, .leftHalf, .rightHalf]
        let landscape: [WindowCommand] = [.autoTile, .leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .center]
        let order = (isPortrait ? portrait : landscape).map { "window:" + $0.rawValue }
        func rank(_ action: LaunchAction) -> Int { order.firstIndex(of: action.id) ?? order.count }
        return all.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func dictionaryAction(_ query: String) -> LaunchAction? {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = input.firstIndex(where: \.isWhitespace),
              ["define", "定义", "查词", "dingyi", "chaci"].contains(input[..<split].lowercased()) else { return nil }
        let word = input[split...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 100 else { return nil }
        return LaunchAction(id: "system:define", english: "Look Up in Dictionary", chinese: "在词典中查找",
                            symbol: "book", destination: .system(.define(word)), aliases: [])
    }

    private static let reservedBareDictionaryTokens: Set<String> = ["t", "tr", "f", "define", "dict", "查词"]
    private static let disallowedBareDictionaryPunctuation = CharacterSet(charactersIn: #"/\:.+-*=()[]@#$%^&?!~"'`<>"#)

    static func bareDictionaryWord(_ query: String) -> String? {
        guard !query.isEmpty,
              !query.contains(where: { $0.isWhitespace || $0.isNewline }),
              !reservedBareDictionaryTokens.contains(query.lowercased()) else { return nil }
        let canonical = query.precomposedStringWithCanonicalMapping
        for scalar in canonical.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar)
                || disallowedBareDictionaryPunctuation.contains(scalar) {
                return nil
            }
        }
        let allLatin = canonical.unicodeScalars.allSatisfy(isLatinLetterScalar)
        if allLatin {
            return (2...32).contains(canonical.count) ? query : nil
        }
        let allCJK = canonical.unicodeScalars.allSatisfy(isCJKIdeographScalar)
        if allCJK {
            return (2...8).contains(canonical.count) ? query : nil
        }
        return nil
    }

    static func compactDictionarySummary(_ definition: String, word: String) -> String {
        let normalizedNewlines = definition.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !trimmedWord.isEmpty, lines.count > 1,
           lines[0].compare(trimmedWord, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            lines.removeFirst()
        }
        var collapsed = lines.joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !trimmedWord.isEmpty,
           let range = collapsed.range(of: trimmedWord, options: [.anchored, .caseInsensitive]) {
            let tail = collapsed[range.upperBound...].drop(while: { $0.isWhitespace })
            if let first = tail.first, ["|", ":", "：", "—", "–", "-"].contains(first) {
                let stripped = tail.dropFirst().drop(while: { $0.isWhitespace })
                if !stripped.isEmpty {
                    collapsed = String(stripped)
                }
            }
        }
        let maxLength = 160
        guard collapsed.count > maxLength else { return collapsed }
        let prefix = String(collapsed.prefix(maxLength - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }

    private static func isLatinLetterScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, // A-Z
             0x0061...0x007A, // a-z
             0x00C0...0x00D6, // Latin-1 Supplement (excluding ×)
             0x00D8...0x00F6, // Latin-1 Supplement (excluding ÷)
             0x00F8...0x00FF,
             0x0100...0x024F, // Latin Extended-A & B
             0x1E00...0x1EFF: // Latin Extended Additional
            return true
        default:
            return false
        }
    }

    private static func isCJKIdeographScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2EBEF: // CJK Unified Ideographs Extensions B-F
            return true
        default:
            return false
        }
    }

    static func applicationRoots(home: URL) -> [URL] {
        ["/System/Applications", "/System/Library/CoreServices/Applications", "/Applications"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } + [home.appendingPathComponent("Applications", isDirectory: true)]
    }

    private static let chineseNames = [
        "com.tencent.xinwechat": "微信",
        "com.apple.finder": "访达", "com.apple.calculator": "计算器", "com.apple.safari": "Safari 浏览器",
        "com.apple.notes": "备忘录", "com.apple.ical": "日历", "com.apple.mail": "邮件",
        "com.apple.mobilesms": "信息", "com.apple.reminders": "提醒事项", "com.apple.preview": "预览",
        "com.apple.terminal": "终端", "com.apple.activitymonitor": "活动监视器",
        "com.apple.appstore": "App Store", "com.apple.dictionary": "词典", "com.apple.music": "音乐",
        "com.apple.photos": "照片", "com.apple.textedit": "文本编辑",
        "com.apple.maps": "地图", "com.apple.addressbook": "通讯录", "com.apple.iwork.pages": "Pages 文稿",
        "com.apple.iwork.numbers": "Numbers 表格", "com.apple.iwork.keynote": "Keynote 讲演",
    ]

    static let commonAppAliases: [String: [String]] = [
        "photoshop": ["ps"],
        "illustrator": ["ai"],
        "premiere": ["pr"],
        "premierepro": ["pr"],
        "aftereffects": ["ae"],
        "wechat": ["wx"],
        "visualstudiocode": ["code", "vscode"],
        "terminal": ["term"],
        "systemsettings": ["pref", "sys"],
        "activitymonitor": ["top", "monitor"],
    ]

    static func curatedAppAliases(_ normalizedName: String) -> [String] {
        var keys = [normalizedName]
        var trimmed = normalizedName
        while let last = trimmed.last, last.isNumber { trimmed.removeLast() }
        if !trimmed.isEmpty, trimmed != normalizedName { keys.append(trimmed) }
        if trimmed.hasPrefix("adobe"), trimmed.count > 5 {
            keys.append(String(trimmed.dropFirst(5)))
        }
        return keys.flatMap { commonAppAliases[$0] ?? [] }
    }

    static func initialsAliases(_ value: String) -> [String] {
        let words = value.split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
        var result: [String] = []
        if words.count >= 2 {
            let wordInitials = String(words.compactMap(\.first)).lowercased()
            if wordInitials.count >= 2 { result.append(wordInitials) }
        }
        var camel = ""
        for word in words {
            guard let first = word.first else { continue }
            camel.append(contentsOf: first.lowercased())
            var prev = first
            for char in word.dropFirst() {
                if prev.isLowercase && char.isUppercase {
                    camel.append(contentsOf: char.lowercased())
                }
                prev = char
            }
        }
        if camel.count >= 2, !result.contains(camel) {
            result.append(camel)
        }
        return result
    }

    private static let commonAliases = [
        "com.apple.calculator": ["calc"], "com.apple.safari": ["safari", "苹果浏览器"],
        "com.google.chrome": ["chrome", "谷歌浏览器"], "org.mozilla.firefox": ["firefox", "火狐"],
        "com.apple.ical": ["ical"], "com.microsoft.vscode": ["code", "vs code"],
        "com.apple.finder": ["finder", "文件管理器"], "com.apple.terminal": ["terminal"],
    ]

    nonisolated static func discoverApplications(roots: [URL], extraApps: [URL]) -> [LaunchAction] {
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(policy, scope)
        guard previous >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return [] }
        defer { _ = setiopolicy_np(policy, scope, previous) }

        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .localizedNameKey, .isUbiquitousItemKey]
        var seen = Set<String>()
        var actions: [LaunchAction] = []

        func add(_ url: URL) {
            guard url.pathExtension.lowercased() == "app", !url.isInCloudStorage else { return }
            let source = IndexScope.folderPath(url)
            var attributes = stat()
            guard lstat(source, &attributes) == 0, attributes.st_flags & UInt32(SF_DATALESS) == 0 else { return }
            let target: URL
            if attributes.st_mode & S_IFMT == S_IFLNK {
                guard let destination = try? manager.destinationOfSymbolicLink(atPath: source) else { return }
                let parent = url.deletingLastPathComponent()
                let resolved = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : parent.appendingPathComponent(destination)
                target = URL(fileURLWithPath: IndexScope.folderPath(resolved), isDirectory: true)
            } else {
                target = URL(fileURLWithPath: source, isDirectory: true)
            }
            // A second bundle link is not accepted.
            guard target.pathExtension.lowercased() == "app",
                  let attributes = residentApplicationAttributes(target),
                  let bundle = Bundle(url: target), let identifier = bundle.bundleIdentifier,
                  identifier != settingsBundleID, identifier != "io.github.surfire.lumen",
                  bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
                  seen.insert(identifier).inserted else { return }
            let values = target.resourceValuesIfLocal(keys)
            let filename = url.deletingPathExtension().lastPathComponent
            let localized = values?.localizedName.map { ($0 as NSString).deletingPathExtensionIfApp } ?? filename
            let english = bundle.infoDictionary?["CFBundleDisplayName"] as? String ?? filename
            let normalizedID = identifier.lowercased()
            let chinese = chineseNames[normalizedID] ?? localized
            let aliases = [filename, localized, bundle.infoDictionary?["CFBundleName"] as? String ?? filename]
                + (commonAliases[normalizedID] ?? []) + initialsAliases(filename)
                + pinyinAliases(chinese) + (localized == chinese ? [] : pinyinAliases(localized))
            actions.append(LaunchAction(id: "app:" + identifier, english: english, chinese: chinese,
                                        symbol: "app", destination: .application(target, stamp: SearchHit.filesystemStamp(attributes)),
                                        aliases: aliases))
        }

        // Limit discovery to app roots and one level of organizational folders.
        for root in roots {
            guard root.resourceValuesIfLocal(keys)?.isDirectory == true,
                  let contents = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            else { continue }
            for url in contents.sorted(by: { $0.path < $1.path }) {
                if url.pathExtension.lowercased() == "app" { add(url); continue }
                guard url.pathExtension.isEmpty, url.resourceValuesIfLocal(keys)?.isDirectory == true,
                      let children = try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                else { continue }
                for child in children.sorted(by: { $0.path < $1.path }) { add(child) }
            }
        }
        extraApps.forEach(add)
        return actions
    }

    static func matches(_ query: String, actions: [LaunchAction], includeDictionary: Bool = true,
                        boost: (String) -> Int = { _ in 0 }) -> [ActionMatch] {
        if includeDictionary, let dictionary = dictionaryAction(query) {
            return [ActionMatch(action: dictionary, score: 110 + boost(dictionary.id))]
        }
        let term = normalized(query)
        guard !term.isEmpty, term.utf8.count <= 128, !query.contains("/") && !query.contains("\\") else { return [] }
        return actions.compactMap { action -> ActionMatch? in
            let isApplication: Bool
            if case .application = action.destination { isApplication = true }
            else { isApplication = false }
            let names = action.normalizedNames
            let score: Int
            if names.contains(term) { score = 110 }
            else if term.count == 1 && names.contains(where: { $0.hasPrefix(term) }) { score = isApplication ? 86 : 62 }
            else { score = action.normalizedSearchable.lazy.map { match(term, in: $0, isApplication: isApplication) }.max() ?? 0 }
            guard score > 0 else { return nil }
            return ActionMatch(action: action, score: score + boost(action.id))
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.action.english.count != $1.action.english.count { return $0.action.english.count < $1.action.english.count }
            return $0.action.id < $1.action.id
        }.prefix(8).map { $0 }
    }

    static func pinyinAliases(_ value: String) -> [String] {
        let han = String(value.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) })
        guard !han.isEmpty,
              let latin = han.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripCombiningMarks, reverse: false)
        else { return [] }
        let syllables = latin.lowercased().split { !$0.isASCII || !$0.isLetter }
        guard !syllables.isEmpty else { return [] }
        return [syllables.joined(), String(syllables.compactMap(\.first))]
    }

    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func match(_ term: String, in candidate: String, isApplication: Bool) -> Int {
        if candidate == term { return 100 }
        if candidate.hasPrefix(term) { return term.count == 1 ? (isApplication ? 82 : 45) : 92 }
        guard term.count >= 2 else { return 0 }
        if candidate.contains(term) { return 74 }
        var remaining = term[...]
        var gaps = 0
        for letter in candidate {
            if letter == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty {
                    if isApplication && candidate.first == term.first { return max(82, 88 - gaps) }
                    return max(26, 42 - gaps)
                }
            } else {
                gaps += 1
            }
        }
        return 0
    }
}

func withNoDatalessMaterialization<T>(_ body: () -> T?) -> T? {
    let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
    let scope = IOPOL_SCOPE_THREAD
    let previous = getiopolicy_np(policy, scope)
    guard previous >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return nil }
    defer { _ = setiopolicy_np(policy, scope, previous) }
    return body()
}

private func residentApplicationAttributes(_ url: URL) -> stat? {
    // Check the resolved bundle and its ancestors, not Launch Services' internal bundle layout.
    guard !url.isInCloudStorage, let attributes = SearchHit.pathAttributes(at: url.path, kind: "directory"),
          let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey]),
          values.isUbiquitousItem != true, values.volumeIsLocal == true else { return nil }
    return attributes
}

private extension URL {
    var isInCloudStorage: Bool {
        // Launch Services and IconServices can access the bundle outside our I/O policy.
        let path = path + "/"
        return path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/")
    }

    func resourceValuesIfLocal(_ keys: Set<URLResourceKey>) -> URLResourceValues? {
        var attributes = stat()
        guard !isInCloudStorage, lstat(path, &attributes) == 0,
              attributes.st_mode & S_IFMT != S_IFLNK, attributes.st_flags & UInt32(SF_DATALESS) == 0,
              let values = try? resourceValues(forKeys: keys), values.isUbiquitousItem != true else { return nil }
        return values
    }
}

private extension NSString {
    var deletingPathExtensionIfApp: String {
        pathExtension.lowercased() == "app" ? deletingPathExtension : self as String
    }
}

@MainActor
enum LaunchDispatcher {
    static let didOpenApplication = PassthroughSubject<LaunchAction, Never>()

    static func perform(_ action: LaunchAction, activates: Bool = true, chinese: Bool = false,
                        completion: @escaping (Bool) -> Void) {
        let workspace = NSWorkspace.shared
        switch action.destination {
        case .application(let url, _):
            let started = withNoDatalessMaterialization { () -> Bool? in
                guard residentApplicationAttributes(url) != nil else { return nil }
                let options = NSWorkspace.OpenConfiguration()
                options.activates = activates
                options.addsToRecentItems = activates
                workspace.openApplication(at: url, configuration: options) { running, error in
                    DispatchQueue.main.async {
                        let opened = running != nil && error == nil
                        if opened { didOpenApplication.send(action) }
                        completion(opened)
                    }
                }
                return true
            }
            if started == nil { completion(false) }
        case .settings(let url):
            completion(openSettings(url))
        case .system(let operation):
            LauncherSystemActions.perform(operation, chinese: chinese, completion: completion)
        case .window:
            // Window commands need the target captured by AppDelegate for this presentation.
            completion(false)
        case .executable:
            // Only the command card owns consent, arguments and cancellation for these rows.
            completion(false)
        }
    }

    static func openSettings(_ url: URL) -> Bool {
        // Require Apple's registered handler for these local System Settings URLs.
        let workspace = NSWorkspace.shared
        guard let destination = workspace.urlForApplication(toOpen: url),
              Bundle(url: destination)?.bundleIdentifier == LaunchCatalog.settingsBundleID else { return false }
        return workspace.open(url)
    }
}
