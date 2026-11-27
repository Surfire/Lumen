import AppKit
import CryptoKit
import os
import SwiftUI

struct SavedShortcut: Codable, Equatable, Identifiable {
    enum Target: Codable, Equatable {
        case application(String)
        case folder(String)
        case web(URL)
    }

    let id: UUID
    var title: String
    var alias: String
    var target: Target
    var pinned: Bool
    var lastOpened: Date?
    var queryParameter: String? = nil
    var rowID: String { "shortcut:" + id.uuidString }

    var symbol: String {
        switch target {
        case .application: return "app"
        case .folder: return "folder"
        case .web: return "link"
        }
    }

    var detail: String {
        switch target {
        case .application(let identifier): return alias.isEmpty ? identifier : alias
        case .folder(let path): return (path as NSString).abbreviatingWithTildeInPath
        case .web(let url): return url.absoluteString
        }
    }

    var queryLink: LumenHTTPSQueryLink? {
        guard case .web(let url) = target, let queryParameter else { return nil }
        return .init(commandID: rowID, keyword: alias, title: title, baseURL: url, queryKey: queryParameter)
    }

    static func webURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 4096, let parts = URLComponents(string: trimmed),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
        else { return nil }
        return parts.url
    }
}

@MainActor
final class LauncherFrecency {
    private struct Entry: Codable {
        var count: Double
        var lastOpened: Date
    }

    private let defaults: UserDefaults?
    private let key = "launcher.frecency.v1"
    private let queryKey = "launcher.frecency.query.v1"
    private let capacity = 512
    private var entries: [String: Entry]
    private var queryEntries: [String: Entry]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        entries = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        queryEntries = defaults?.data(forKey: queryKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private struct FileIDCache: Sendable {
        static let maxEntries = 2048
        var values: [String: String] = [:]
        var keys: [String] = []
        var head = 0

        mutating func insert(_ id: String, for path: String) {
            if values[path] != nil { return }
            if values.count >= Self.maxEntries {
                let evicted = keys[head]
                keys[head] = path
                head = (head + 1) % Self.maxEntries
                values.removeValue(forKey: evicted)
            } else {
                keys.append(path)
            }
            values[path] = id
        }
    }

    private nonisolated static let fileIDCache = OSAllocatedUnfairLock(initialState: FileIDCache())

    nonisolated static func fileID(_ path: String) -> String {
        if let cached = fileIDCache.withLock({ $0.values[path] }) {
            return cached
        }
        // Do not keep a plaintext list of opened file paths in preferences.
        let id = "file:" + Data(SHA256.hash(data: Data(path.utf8))).base64EncodedString()
        fileIDCache.withLock { $0.insert(id, for: path) }
        return id
    }

    nonisolated static func queryEntryKey(query: String, targetID: String) -> String? {
        let normalized = LaunchCatalog.normalized(query)
        guard !normalized.isEmpty else { return nil }
        let payload = normalized + "\0" + targetID
        return "q:" + Data(SHA256.hash(data: Data(payload.utf8))).base64EncodedString()
    }

    func noteOpened(_ id: String, query: String = "", now: Date = .now) {
        let prior = entries[id].map { $0.count * decay($0.lastOpened, now: now, days: 14) } ?? 0
        entries[id] = Entry(count: min(prior + 1, 64), lastOpened: now)
        if entries.count > capacity {
            let keep = entries.sorted { $0.value.lastOpened > $1.value.lastOpened }.prefix(capacity)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) { defaults?.set(data, forKey: key) }

        if let qKey = Self.queryEntryKey(query: query, targetID: id) {
            let qPrior = queryEntries[qKey].map { $0.count * decay($0.lastOpened, now: now, days: 14) } ?? 0
            queryEntries[qKey] = Entry(count: min(qPrior + 1, 64), lastOpened: now)
            if queryEntries.count > capacity {
                let keep = queryEntries.sorted { $0.value.lastOpened > $1.value.lastOpened }.prefix(capacity)
                queryEntries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            if let data = try? JSONEncoder().encode(queryEntries) { defaults?.set(data, forKey: queryKey) }
        }
    }

    func boost(_ id: String, query: String = "", now: Date = .now) -> Int {
        let globalBoost: Int
        if let entry = entries[id] {
            let frequency = entry.count * decay(entry.lastOpened, now: now, days: 14)
            let recency = decay(entry.lastOpened, now: now, days: 3)
            globalBoost = min(12, Int(3 * log2(1 + frequency) + 4 * recency))
        } else {
            globalBoost = 0
        }
        let queryBoost: Int
        if let qKey = Self.queryEntryKey(query: query, targetID: id), let qEntry = queryEntries[qKey] {
            let frequency = qEntry.count * decay(qEntry.lastOpened, now: now, days: 14)
            let recency = decay(qEntry.lastOpened, now: now, days: 3)
            queryBoost = min(14, Int(4 * log2(1 + frequency) + 6 * recency))
        } else {
            queryBoost = 0
        }
        return globalBoost + queryBoost
    }

    private func decay(_ lastOpened: Date, now: Date, days: Double) -> Double {
        exp2(-max(0, now.timeIntervalSince(lastOpened)) / (86_400 * days))
    }

    func rankFiles(_ hits: [SearchHit], query: String = "") -> [SearchHit] {
        guard hits.count > 1, !entries.isEmpty || !queryEntries.isEmpty else { return hits }
        let now = Date.now
        return hits.enumerated().map { (index: $0.offset, hit: $0.element, rank: $0.offset - boost(Self.fileID($0.element.path), query: query, now: now)) }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.hit)
    }
}

@MainActor
final class ShortcutLibrary: ObservableObject {
    enum SaveResult: Equatable {
        case saved, invalid, aliasInUse(String)
    }

    @Published private(set) var entries: [SavedShortcut]
    @Published var includeOptionalLinks: Bool {
        didSet { defaults?.set(includeOptionalLinks, forKey: Self.optionalLinksKey) }
    }
    private static let optionalLinksKey = "launcher.includeOptionalLinks"
    private let defaults: UserDefaults?
    private let key = "launcher.savedShortcuts.v1"

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let data = defaults?.data(forKey: key)
        entries = data.flatMap { try? JSONDecoder().decode([SavedShortcut].self, from: $0) } ?? []
        includeOptionalLinks = defaults?.bool(forKey: Self.optionalLinksKey) ?? false
    }

    func save(_ shortcut: SavedShortcut) -> Bool {
        saveResult(shortcut) == .saved
    }

    func saveResult(_ shortcut: SavedShortcut) -> SaveResult {
        var shortcut = shortcut
        shortcut.title = shortcut.title.trimmingCharacters(in: .whitespacesAndNewlines)
        shortcut.alias = shortcut.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcut.title.isEmpty, shortcut.title.count <= 100, shortcut.alias.count <= 80,
              !shortcut.title.contains(where: \.isNewline), !shortcut.alias.contains(where: \.isNewline)
        else { return .invalid }
        switch shortcut.target {
        case .application(let identifier): guard identifier.hasPrefix("app:") else { return .invalid }
        case .folder(let path): guard SearchHit.existsOnDisk(at: path, kind: "directory") else { return .invalid }
        case .web(let url): guard SavedShortcut.webURL(url.absoluteString) == url else { return .invalid }
        }
        if shortcut.queryParameter != nil {
            guard let link = shortcut.queryLink else { return .invalid }
            let keepsAlias = entries.first(where: { $0.id == shortcut.id })?.queryLink?.keyword == link.keyword
            if (!keepsAlias && LumenCommandCatalog.isBuiltInAlias(link.keyword, includeOptionalLinks: includeOptionalLinks))
                || entries.contains(where: { $0.id != shortcut.id && $0.queryLink?.keyword == link.keyword }) {
                return .aliasInUse(link.keyword)
            }
        }
        if let index = entries.firstIndex(where: { $0.id == shortcut.id }) {
            entries[index] = shortcut
        } else {
            guard entries.count < 128 else { return .invalid }
            entries.append(shortcut)
        }
        persist()
        return .saved
    }

    func remove(_ shortcut: SavedShortcut) {
        entries.removeAll { $0.id == shortcut.id }
        persist()
    }

    func togglePin(_ shortcut: SavedShortcut) {
        guard let index = entries.firstIndex(where: { $0.id == shortcut.id }) else { return }
        entries[index].pinned.toggle()
        persist()
    }

    func noteOpened(_ shortcut: SavedShortcut) {
        guard case .folder = shortcut.target,
              let index = entries.firstIndex(where: { $0.id == shortcut.id }) else { return }
        entries[index].lastOpened = .now
        persist()
    }

    var home: [SavedShortcut] {
        let pins = entries.filter(\.pinned)
        let recentProjects = entries.filter {
            if case .folder = $0.target { return !$0.pinned && $0.lastOpened != nil }
            return false
        }.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        return pins + recentProjects.prefix(4)
    }

    func matches(_ query: String) -> [(record: SavedShortcut, score: Int)] {
        let term = LaunchCatalog.normalized(query)
        guard !term.isEmpty else { return [] }
        return entries.compactMap { record -> (record: SavedShortcut, score: Int)? in
            let fields = [record.title, record.alias]
            let score = fields.map { field -> Int in
                let value = LaunchCatalog.normalized(field)
                if term == value { return 105 }
                guard term.count > 1 else { return 0 }
                if value.hasPrefix(term) { return 80 }
                return value.contains(term) ? 55 : 0
            }.max() ?? 0
            return score == 0 ? nil : (record, score)
        }.sorted { $0.score > $1.score }.prefix(6).map { $0 }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults?.set(data, forKey: key) }
    }
}

@MainActor
final class ContextActions: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let perform: () -> Void
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var selected = 0
    var isOpen: Bool { !items.isEmpty }

    func show(_ items: [Item]) {
        selected = 0
        self.items = items
    }

    func close() { items = [] }
    func move(_ delta: Int) { selected = min(max(selected + delta, 0), max(items.count - 1, 0)) }

    func run(_ index: Int? = nil) {
        let index = index ?? selected
        guard items.indices.contains(index) else { return }
        let item = items[index]
        close()
        item.perform()
    }
}

struct QuicklinksView: View {
    @ObservedObject var model: Launcher
    @ObservedObject var library: ShortcutLibrary
    let chooseFolder: (@escaping (URL) -> Void) -> Void

    private enum Kind: String, CaseIterable { case application, folder, web }
    @State private var kind: Kind = .web
    @State private var editing: SavedShortcut?
    @State private var title = ""
    @State private var alias = ""
    @State private var destination = ""
    @State private var queryParameter = ""
    @State private var pinned = false
    @State private var saveResult: ShortcutLibrary.SaveResult?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTheme.spacingLG) {
            LumenSettingsCard(title: model.t("内置网页搜索", "Built-in Web Search"), icon: "globe") {
                Toggle(model.t("启用 GitHub、维基百科和 Google 地图搜索",
                               "Enable GitHub, Wikipedia, and Google Maps Search"),
                       isOn: $library.includeOptionalLinks)
                Text(model.t("输入 gh、wiki 或 map，空一格后输入搜索词，按回车在浏览器中打开。已保存的自定义查询别名优先。",
                             "Type gh, wiki, or map followed by a search term, then press Return to open it in your browser. Saved custom query aliases take precedence."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LumenSettingsCard(title: model.t("已保存", "Saved"), icon: "bookmark") {
                if library.entries.isEmpty {
                    LumenSettingsWell {
                        Text(model.t("暂无自定义快捷链接", "No Quicklinks yet"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(SettingsTheme.textSecondary)
                    }
                } else {
                    LumenSettingsWell(padding: 4) {
                        VStack(spacing: 0) {
                            ForEach(Array(library.entries.enumerated()), id: \.element.id) { index, shortcut in
                                if index > 0 { LumenSettingsHairline().padding(.horizontal, 8) }
                                HStack(spacing: 10) {
                                    Label(shortcut.title, systemImage: shortcut.pinned ? "pin.fill" : shortcut.symbol)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(SettingsTheme.textPrimary)
                                        .lineLimit(1)
                                    if !shortcut.alias.isEmpty {
                                        Text(shortcut.alias)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(SettingsTheme.amber)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(SettingsTheme.amber.opacity(0.12), in: Capsule())
                                    }
                                    Spacer(minLength: 8)
                                    Button(model.t("编辑", "Edit")) { edit(shortcut) }
                                        .buttonStyle(LumenSecondaryButtonStyle())
                                        .controlSize(.small)
                                    Button(model.t("移除", "Remove")) {
                                        library.remove(shortcut)
                                        if editing?.id == shortcut.id { reset() }
                                    }
                                    .buttonStyle(LumenSecondaryButtonStyle())
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                            }
                        }
                    }
                }
            }

            LumenSettingsCard(title: editing == nil ? model.t("添加快捷链接", "Add Quicklink") : model.t("编辑快捷链接", "Edit Quicklink"),
                              icon: editing == nil ? "plus.circle" : "pencil.circle") {
                LabeledContent(model.t("目标类型", "Destination")) {
                    Picker(model.t("目标类型", "Destination"), selection: $kind) {
                        Text(model.t("应用程序", "Application")).tag(Kind.application)
                        Text(model.t("项目文件夹", "Project Folder")).tag(Kind.folder)
                        Text(model.t("网页", "Website")).tag(Kind.web)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .onChange(of: kind) { _, value in
                    if editing.map(kindOf) != value { destination = "" }
                }

                LumenSettingsHairline()

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel(model.t("名称", "Name"))
                        TextField("", text: $title,
                                  prompt: Text(model.t("例如：GitHub 问题", "e.g. GitHub Issues")))
                            .lumenWellField()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel(model.t("搜索别名（可选）", "Search Alias (Optional)"))
                        TextField("", text: $alias,
                                  prompt: Text(model.t("例如：gh", "e.g. gh")))
                            .lumenWellField()
                    }
                }

                switch kind {
                case .application:
                    LabeledContent(model.t("应用程序", "Application")) {
                        Picker(model.t("应用程序", "Application"), selection: $destination) {
                            Text(model.t("选择应用", "Choose an App")).tag("")
                            ForEach(model.installedActions) { action in
                                Text(action.title(chinese: model.zh)).tag(action.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                case .folder:
                    LabeledContent(model.t("项目文件夹", "Project Folder")) {
                        HStack(spacing: 8) {
                            Text(destination.isEmpty ? model.t("未选择", "None selected") : (destination as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 12))
                                .foregroundStyle(SettingsTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(model.t("选择…", "Choose…")) { chooseFolder { destination = IndexScope.folderPath($0) } }
                                .buttonStyle(LumenSecondaryButtonStyle())
                                .controlSize(.small)
                        }
                    }
                case .web:
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            fieldLabel(model.t("网页地址", "Website URL"))
                            TextField("", text: $destination, prompt: Text(verbatim: "https://example.com"))
                                .lumenWellField()
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            fieldLabel(model.t("查询参数（可选）", "Query Parameter (Optional)"))
                            TextField("", text: $queryParameter, prompt: Text(verbatim: "q"))
                                .lumenWellField()
                        }
                        .frame(width: 170)
                    }
                    if !queryParameter.isEmpty {
                        Text(model.t("用「别名 搜索词」打开 HTTPS 网页。网址请填写不含查询参数的地址。",
                                     "Type the alias and a query to open an HTTPS page. Use a base URL without a query string."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LumenSettingsHairline()

                HStack(spacing: 10) {
                    Toggle(model.t("固定在空搜索页", "Pin to Empty Search"), isOn: $pinned)
                        .font(.system(size: 12.5))
                    Spacer()
                    if editing != nil {
                        Button(model.t("取消编辑", "Cancel Editing")) { reset() }
                            .buttonStyle(LumenSecondaryButtonStyle())
                    }
                    Button(model.t("保存", "Save")) { save() }
                        .buttonStyle(LumenPrimaryButtonStyle())
                }

                if case .aliasInUse(let alias) = saveResult {
                    Text(model.t("查询别名「\(alias)」已被使用。请选择其他别名。",
                                 "The query alias “\(alias)” is already in use. Choose a different alias."))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.amber)
                } else if saveResult == .invalid {
                    Text(model.t("请检查名称、别名或目标地址。", "Check the name, alias, or destination."))
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.red)
                }
            }
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(SettingsTheme.textTertiary)
    }

    private func kindOf(_ shortcut: SavedShortcut) -> Kind {
        switch shortcut.target {
        case .application: return .application
        case .folder: return .folder
        case .web: return .web
        }
    }

    private func edit(_ shortcut: SavedShortcut) {
        editing = shortcut
        kind = kindOf(shortcut)
        title = shortcut.title
        alias = shortcut.alias
        pinned = shortcut.pinned
        queryParameter = shortcut.queryParameter ?? ""
        switch shortcut.target {
        case .application(let value), .folder(let value): destination = value
        case .web(let url): destination = url.absoluteString
        }
        saveResult = nil
    }

    private func reset() {
        editing = nil
        title = ""
        alias = ""
        destination = ""
        queryParameter = ""
        pinned = false
        saveResult = nil
    }

    private func save() {
        let target: SavedShortcut.Target
        switch kind {
        case .application:
            guard model.installedActions.contains(where: { $0.id == destination }) else { saveResult = .invalid; return }
            target = .application(destination)
        case .folder: target = .folder(destination)
        case .web:
            guard let url = SavedShortcut.webURL(destination) else { saveResult = .invalid; return }
            target = .web(url)
        }
        let parameter = queryParameter.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortcut = SavedShortcut(id: editing?.id ?? UUID(), title: title, alias: alias,
                                     target: target, pinned: pinned, lastOpened: editing?.lastOpened,
                                     queryParameter: kind == .web && !parameter.isEmpty ? parameter : nil)
        let result = library.saveResult(shortcut)
        if result == .saved { reset() } else { saveResult = result }
    }
}
