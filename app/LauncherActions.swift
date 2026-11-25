import AppKit
import Combine
import Darwin
import ImageIO

struct LaunchAction: Equatable, Identifiable {
    enum Destination: Equatable {
        case application(URL, stamp: String), settings(URL)
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
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let prior = getiopolicy_np(policy, scope)
        guard prior >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return nil }
        defer { _ = setiopolicy_np(policy, scope, prior) }

        // Read declared icon bytes in this process. IconServices may read the source
        // bundle on another thread or in a service without our no-download policy.
        guard SearchHit.pathStamp(at: key.url.path, kind: "directory") == key.stamp else { return nil }
        let contents = key.url.appendingPathComponent("Contents", isDirectory: true)
        guard let plist = readLocal(contents.appendingPathComponent("Info.plist"), limit: 512 * 1024),
              let info = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
        else { return nil }
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        for field in ["CFBundleIconFile", "CFBundleIconName"] {
            guard let name = info[field] as? String, !name.isEmpty,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext.isEmpty || ["icns", "png", "tiff"].contains(ext) else { continue }
            let file = resources.appendingPathComponent(ext.isEmpty ? name + ".icns" : name)
            if let bytes = readLocal(file, limit: 8 * 1024 * 1024), let image = thumbnail(bytes) { return image }
        }
        return nil
    }

    private static func readLocal(_ url: URL, limit: Int) -> Data? {
        guard let fd = LocalFile.openReadOnly(url.path) else { return nil }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var file = stat()
        var volume = statfs()
        guard fstat(fd, &file) == 0, file.st_size > 0, file.st_size <= limit,
              fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              let data = try? input.read(upToCount: limit + 1), data.count == file.st_size else { return nil }
        return data
    }

    private static func thumbnail(_ data: Data) -> CGImage? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, noCache) else { return nil }
        let count = min(CGImageSourceGetCount(source), 32)
        guard count > 0 else { return nil }
        let size = 64
        let representations = (0..<count).compactMap { index -> (Int, Int)? in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return (index, max(width, height))
        }
        let index = representations.filter { $0.1 >= size }.min(by: { $0.1 < $1.1 })?.0
            ?? representations.max(by: { $0.1 < $1.1 })?.0 ?? 0
        let options = [kCGImageSourceThumbnailMaxPixelSize: size,
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, index, options)
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
            ("com.apple.Appearance-Settings.extension", "Appearance", "外观", "circle.lefthalf.filled", ["dark mode", "深色模式"]),
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
        return settings
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
            guard url.pathExtension.lowercased() == "app",
                  let values = url.resourceValuesIfLocal(keys), values.isDirectory == true,
                  let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  identifier != settingsBundleID, identifier != "io.github.surfire.lumen",
                  bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else { return }
            let path = IndexScope.folderPath(url)
            guard let stamp = SearchHit.pathStamp(at: path, kind: "directory"),
                  seen.insert(identifier).inserted else { return }
            let target = URL(fileURLWithPath: path, isDirectory: true)
            let filename = url.deletingPathExtension().lastPathComponent
            let localized = values.localizedName.map { ($0 as NSString).deletingPathExtensionIfApp } ?? filename
            let english = bundle.infoDictionary?["CFBundleDisplayName"] as? String ?? filename
            let normalizedID = identifier.lowercased()
            let chinese = chineseNames[normalizedID] ?? localized
            let initials = filename.split { !$0.isLetter && !$0.isNumber }.compactMap(\.first)
            let aliases = [filename, localized, bundle.infoDictionary?["CFBundleName"] as? String ?? filename]
                + (commonAliases[normalizedID] ?? []) + (initials.count > 1 ? [String(initials)] : [])
                + pinyinAliases(chinese) + (localized == chinese ? [] : pinyinAliases(localized))
            actions.append(LaunchAction(id: "app:" + identifier, english: english, chinese: chinese,
                                        symbol: "app", destination: .application(target, stamp: stamp), aliases: aliases))
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

    static func matches(_ query: String, actions: [LaunchAction]) -> [ActionMatch] {
        let term = normalized(query)
        guard !term.isEmpty, term.utf8.count <= 128, !query.contains("/") && !query.contains("\\") else { return [] }
        return actions.compactMap { action -> ActionMatch? in
            let names = [action.english, action.chinese].map(normalized)
            let score = names.contains(term) ? 110 : action.searchable.lazy.map { match(term, in: normalized($0)) }.max() ?? 0
            guard score > 0 else { return nil }
            return ActionMatch(action: action, score: score)
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
        guard term.count >= 2 else { return 0 }
        if candidate.hasPrefix(term) { return 80 }
        if candidate.contains(term) { return 55 }
        return 0
    }
}

private extension URL {
    func resourceValuesIfLocal(_ keys: Set<URLResourceKey>) -> URLResourceValues? {
        guard let values = try? resourceValues(forKeys: keys), values.isSymbolicLink != true,
              values.isUbiquitousItem != true else { return nil }
        var attributes = stat()
        guard lstat(path, &attributes) == 0, attributes.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
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
    static func perform(_ action: LaunchAction, activates: Bool = true,
                        completion: @escaping (Bool) -> Void) {
        let workspace = NSWorkspace.shared
        switch action.destination {
        case .application(let url, let stamp):
            guard SearchHit.pathStamp(at: url.path, kind: "directory") == stamp else {
                completion(false)
                return
            }
            let options = NSWorkspace.OpenConfiguration()
            options.activates = activates
            options.addsToRecentItems = activates
            workspace.openApplication(at: url, configuration: options) { running, error in
                DispatchQueue.main.async { completion(running != nil && error == nil) }
            }
        case .settings(let url):
            // Require Apple's registered handler for these local System Settings URLs.
            guard let destination = workspace.urlForApplication(toOpen: url),
                  Bundle(url: destination)?.bundleIdentifier == LaunchCatalog.settingsBundleID else {
                completion(false)
                return
            }
            completion(workspace.open(url))

        }
    }
}
