import AppKit
import Combine
import Darwin

struct LaunchAction: Equatable, Identifiable {
    enum Destination: Equatable {
        case application(URL, stamp: String), settings(URL), system(LauncherSystemActions.Operation)
    }

    let id: String
    let english: String
    let chinese: String
    let symbol: String
    let destination: Destination
    let aliases: [String]

    func title(chinese useChinese: Bool) -> String { useChinese ? chinese : english }

    fileprivate var searchable: [String] { [english, chinese] + aliases }
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

    private let icons = ApplicationIcons()
    private var visible = Set<ApplicationIcons.Key>()
    private var tasks: [ApplicationIcons.Key: Task<Void, Never>] = [:]

    func update(for matches: [ActionMatch]) {
        let keys = Set(matches.compactMap { ApplicationIcons.Key($0.action) })
        guard keys != visible else { return }
        let added = keys.subtracting(visible)
        for removed in visible.subtracting(keys) {
            tasks.removeValue(forKey: removed)?.cancel()
            images.removeValue(forKey: removed)
        }
        visible = keys
        for key in added {
            tasks[key] = Task { [weak self, icons] in
                let image = await icons.image(for: key)
                guard !Task.isCancelled, let self else { return }
                self.tasks[key] = nil
                if let image { self.images[key] = image }
            }
        }
    }
}

struct ActionMatch: Equatable {
    let action: LaunchAction
    let score: Int
    var primary: Bool { score >= 80 }
}

enum LauncherResult: Identifiable {
    case file(SearchHit), action(LaunchAction), shortcut(SavedShortcut), calculation(CalculationResult)

    var id: String {
        switch self {
        case .file(let hit): return hit.path
        case .action(let action): return action.id
        case .shortcut(let shortcut): return shortcut.rowID
        case .calculation: return "calculation"
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
        }
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
            let initials = filename.split { !$0.isLetter && !$0.isNumber }.compactMap(\.first)
            let aliases = [filename, localized, bundle.infoDictionary?["CFBundleName"] as? String ?? filename]
                + (commonAliases[normalizedID] ?? []) + (initials.count > 1 ? [String(initials)] : [])
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

    static func matches(_ query: String, actions: [LaunchAction], boost: (String) -> Int = { _ in 0 }) -> [ActionMatch] {
        if let dictionary = dictionaryAction(query) {
            return [ActionMatch(action: dictionary, score: 110 + boost(dictionary.id))]
        }
        let term = normalized(query)
        guard !term.isEmpty, term.utf8.count <= 128, !query.contains("/") && !query.contains("\\") else { return [] }
        return actions.compactMap { action -> ActionMatch? in
            let names = [action.english, action.chinese].map(normalized)
            let score: Int
            if names.contains(term) { score = 110 }
            else if term.count == 1 && names.contains(where: { $0.hasPrefix(term) }) { score = 62 }
            else { score = action.searchable.lazy.map { match(term, in: normalized($0)) }.max() ?? 0 }
            guard score > 0 else { return nil }
            return ActionMatch(action: action, score: score + boost(action.id))
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.action.english.count != $1.action.english.count { return $0.action.english.count < $1.action.english.count }
            return $0.action.id < $1.action.id
        }.prefix(4).map { $0 }
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

    private static func match(_ term: String, in candidate: String) -> Int {
        if candidate == term { return 100 }
        if candidate.hasPrefix(term) { return term.count == 1 ? 45 : 80 }
        guard term.count >= 2 else { return 0 }
        if candidate.contains(term) { return 55 }
        var remaining = term[...]
        var gaps = 0
        for letter in candidate {
            if letter == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return max(26, 42 - gaps) }
            } else {
                gaps += 1
            }
        }
        return 0
    }
}

private func withNoDatalessMaterialization<T>(_ body: () -> T?) -> T? {
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
            // Require Apple's registered handler for these local System Settings URLs.
            guard let destination = workspace.urlForApplication(toOpen: url),
                  Bundle(url: destination)?.bundleIdentifier == LaunchCatalog.settingsBundleID else {
                completion(false)
                return
            }
            completion(workspace.open(url))
        case .system(let operation):
            LauncherSystemActions.perform(operation, chinese: chinese, completion: completion)
        }
    }
}
