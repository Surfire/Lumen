import Darwin
import Foundation
import os
import SwiftUI

struct SavedSnippet: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var alias: String
    var title: String
    var content: String
    var pinnedToHome: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    var rowID: String { "snippet:" + id.uuidString }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let firstLine = content
            .split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstLine
        }
        return alias
    }

    init(
        id: UUID = UUID(),
        alias: String,
        title: String = "",
        content: String,
        pinnedToHome: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.alias = alias
        self.title = title
        self.content = content
        self.pinnedToHome = pinnedToHome
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, alias, title, content, pinnedToHome, createdAt, updatedAt, lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        alias = try container.decode(String.self, forKey: .alias)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try container.decode(String.self, forKey: .content)
        pinnedToHome = try container.decodeIfPresent(Bool.self, forKey: .pinnedToHome) ?? false
        let decodedCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        createdAt = decodedCreatedAt
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? decodedCreatedAt
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

/// Persistent, user-authored snippet templates stored independently from clipboard history
/// so clipboard retention limits and `clearAll()` never evict saved snippets.
@MainActor
final class SnippetLibrary: ObservableObject {
    enum SaveResult: Equatable, Sendable {
        case saved(SavedSnippet)
        case emptyContent
        case invalidAlias
        case reservedAlias(String)
        case aliasInUse(String)
        case storageFailed
    }

    private struct Envelope: Codable, Equatable {
        var migratedLegacyClipboard: Bool
        var snippets: [SavedSnippet]
    }

    private enum StorageError: Error {
        case unavailable
    }

    nonisolated static let maximumContentBytes = 32 * 1024
    nonisolated static let reservedVerbs: Set<String> = ["qa", "tr", "translate", "img", "cb", "clip", "win"]
    nonisolated static let defaultDirectory = ClipboardStore.canonicalStorageAnchor(
        FileManager.default.homeDirectoryForCurrentUser
    ).appendingPathComponent("Library/Application Support/Lumen/Snippets", isDirectory: true)

    private nonisolated static let fileName = "snippets.json"
    private nonisolated static let maxEnvelopeReadBytes = 16 * 1024 * 1024
    private nonisolated static let log = Logger(subsystem: "io.github.surfire.lumen", category: "snippets")

    let directory: URL
    @Published private(set) var snippets: [SavedSnippet] = []
    @Published private(set) var migratedLegacyClipboard = false

    init(directory: URL = SnippetLibrary.defaultDirectory) {
        self.directory = directory
        if let loaded = try? Self.loadEnvelope(from: directory) {
            self.snippets = loaded.snippets
            self.migratedLegacyClipboard = loaded.migratedLegacyClipboard
        }
    }

    var homeItems: [SavedSnippet] {
        snippets
            .filter(\.pinnedToHome)
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastUsedAt ?? lhs.updatedAt
                let rhsDate = rhs.lastUsedAt ?? rhs.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    func save(
        id: UUID? = nil,
        alias: String,
        title: String = "",
        content: String,
        pinnedToHome: Bool = false
    ) -> SaveResult {
        guard let boundedContent = Self.boundedContent(content) else {
            return .emptyContent
        }
        guard let normalizedAlias = ClipboardStore.normalizedAlias(alias) else {
            return .invalidAlias
        }
        if Self.reservedVerbs.contains(normalizedAlias) {
            return .reservedAlias(normalizedAlias)
        }
        let targetID = id ?? UUID()
        if snippets.contains(where: { $0.alias == normalizedAlias && $0.id != targetID }) {
            return .aliasInUse(normalizedAlias)
        }

        let existingIndex = id.flatMap { candidate in snippets.firstIndex(where: { $0.id == candidate }) }
        let existing = existingIndex.map { snippets[$0] }
        let now = Date.now
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedSnippet(
            id: existing?.id ?? targetID,
            alias: normalizedAlias,
            title: trimmedTitle,
            content: boundedContent,
            pinnedToHome: pinnedToHome,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            lastUsedAt: existing?.lastUsedAt
        )

        var nextSnippets = snippets
        if let existingIndex {
            nextSnippets[existingIndex] = saved
        } else {
            nextSnippets.insert(saved, at: 0)
        }

        guard commitEnvelope(migratedLegacyClipboard: migratedLegacyClipboard, snippets: nextSnippets) else {
            return .storageFailed
        }
        return .saved(saved)
    }

    func remove(_ id: UUID) {
        var nextSnippets = snippets
        let beforeCount = nextSnippets.count
        nextSnippets.removeAll { $0.id == id }
        guard nextSnippets.count != beforeCount else { return }
        _ = commitEnvelope(migratedLegacyClipboard: migratedLegacyClipboard, snippets: nextSnippets)
    }

    func togglePinToHome(_ id: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        var nextSnippets = snippets
        nextSnippets[index].pinnedToHome.toggle()
        nextSnippets[index].updatedAt = .now
        _ = commitEnvelope(migratedLegacyClipboard: migratedLegacyClipboard, snippets: nextSnippets)
    }

    func noteUsed(_ id: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        var nextSnippets = snippets
        nextSnippets[index].lastUsedAt = .now
        _ = commitEnvelope(migratedLegacyClipboard: migratedLegacyClipboard, snippets: nextSnippets)
    }

    func migrateLegacyClipboardTemplates(from store: ClipboardStore) {
        guard !migratedLegacyClipboard else { return }
        let legacyItems = (try? store.templateItems()) ?? []
        var nextSnippets = snippets
        var usedAliases = Set(nextSnippets.map(\.alias))

        for item in legacyItems {
            guard let rawText = item.text,
                  let boundedContent = Self.boundedContent(rawText),
                  let rawAlias = item.alias,
                  let alias = ClipboardStore.normalizedAlias(rawAlias),
                  !Self.reservedVerbs.contains(alias),
                  usedAliases.insert(alias).inserted else {
                continue
            }
            nextSnippets.append(
                SavedSnippet(
                    id: UUID(),
                    alias: alias,
                    title: "",
                    content: boundedContent,
                    pinnedToHome: false,
                    createdAt: item.capturedAt,
                    updatedAt: item.capturedAt,
                    lastUsedAt: nil
                )
            )
        }

        _ = commitEnvelope(migratedLegacyClipboard: true, snippets: nextSnippets)
    }

    func matches(_ query: String) -> [(snippet: SavedSnippet, score: Int)] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return [] }
        return snippets.compactMap { snippet -> (snippet: SavedSnippet, score: Int)? in
            let score: Int
            if snippet.alias == term {
                score = 108
            } else if term.count >= 2 && snippet.alias.hasPrefix(term) {
                score = 84
            } else if term.count >= 2 && (snippet.alias.contains(term) || snippet.displayTitle.lowercased().contains(term)) {
                score = 62
            } else {
                return nil
            }
            return (snippet, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsDate = lhs.snippet.lastUsedAt ?? lhs.snippet.updatedAt
            let rhsDate = rhs.snippet.lastUsedAt ?? rhs.snippet.updatedAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.snippet.alias < rhs.snippet.alias
        }
    }

    func expand(_ snippet: SavedSnippet, liveClipboardText: String? = nil, now: Date = .now) -> String {
        ClipboardTemplateExpander.expand(snippet.content, clipboardText: liveClipboardText, now: now)
    }

    private func commitEnvelope(migratedLegacyClipboard: Bool, snippets nextSnippets: [SavedSnippet]) -> Bool {
        let envelope = Envelope(migratedLegacyClipboard: migratedLegacyClipboard, snippets: nextSnippets)
        do {
            try Self.writeEnvelope(envelope, to: directory)
            self.migratedLegacyClipboard = migratedLegacyClipboard
            self.snippets = nextSnippets
            return true
        } catch {
            Self.log.error("snippet persistence failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private nonisolated static func boundedContent(_ value: String) -> String? {
        let utf8 = value.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: maximumContentBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
        // Back up at most three bytes so a multi-byte UTF-8 scalar is never split.
        while end != utf8.endIndex, utf8[end] & 0xc0 == 0x80 {
            utf8.formIndex(before: &end)
        }
        let bounded = String(decoding: utf8[..<end], as: UTF8.self)
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bounded
    }

    // Foundation's temporaryDirectory abbreviates /private/var -> /var (and /tmp -> /private/tmp).
    // Resolve only those two OS-level root symlinks while keeping every user component strict under O_NOFOLLOW_ANY.
    private nonisolated static func storageAnchorURL(for url: URL) -> URL {
        let path = url.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: true)
        }
        return url
    }

    private nonisolated static func openDirectory(_ url: URL, create: Bool) throws -> Int32? {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        let fd = Darwin.open(url.path, flags)
        if fd >= 0 { return fd }
        guard errno == ENOENT else { throw StorageError.unavailable }
        guard create else { return nil }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, let parentFD = try openDirectory(parent, create: true) else {
            throw StorageError.unavailable
        }
        defer { Darwin.close(parentFD) }
        let name = url.lastPathComponent
        guard Darwin.mkdirat(parentFD, name, 0o700) == 0 || errno == EEXIST else {
            throw StorageError.unavailable
        }
        let child = Darwin.openat(parentFD, name, flags)
        guard child >= 0 else { throw StorageError.unavailable }
        return child
    }

    private nonisolated static func isPrivateRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
    }

    private nonisolated static func verifyTargetSlot(in directoryFD: Int32) throws -> Bool {
        var info = stat()
        if Darwin.fstatat(directoryFD, fileName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard isPrivateRegularFile(info) else { throw StorageError.unavailable }
            return true
        }
        guard errno == ENOENT else { throw StorageError.unavailable }
        return false
    }

    private nonisolated static func loadEnvelope(from directory: URL) throws -> Envelope? {
        let anchored = storageAnchorURL(for: directory)
        guard let directoryFD = try openDirectory(anchored, create: false) else { return nil }
        defer { Darwin.close(directoryFD) }
        guard try verifyTargetSlot(in: directoryFD) else { return nil }

        let fd = Darwin.openat(directoryFD, fileName, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw StorageError.unavailable }

        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              isPrivateRegularFile(info),
              info.st_size >= 0,
              info.st_size <= maxEnvelopeReadBytes else {
            Darwin.close(fd)
            throw StorageError.unavailable
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd() else {
            throw StorageError.unavailable
        }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private nonisolated static func writeEnvelope(_ envelope: Envelope, to directory: URL) throws {
        let anchored = storageAnchorURL(for: directory)
        guard let directoryFD = try openDirectory(anchored, create: true) else {
            throw StorageError.unavailable
        }
        defer { Darwin.close(directoryFD) }

        guard Darwin.fchmod(directoryFD, 0o700) == 0 else {
            throw StorageError.unavailable
        }
        _ = try verifyTargetSlot(in: directoryFD)

        var dirResourceURL = anchored
        var dirResources = URLResourceValues()
        dirResources.isExcludedFromBackup = true
        try dirResourceURL.setResourceValues(dirResources)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = try encoder.encode(envelope)

        let tempName = ".snippets-\(UUID().uuidString).tmp"
        let tempFD = Darwin.openat(
            directoryFD,
            tempName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC,
            0o600
        )
        guard tempFD >= 0 else { throw StorageError.unavailable }

        var renamed = false
        defer {
            if !renamed { _ = Darwin.unlinkat(directoryFD, tempName, 0) }
        }

        do {
            var tempInfo = stat()
            guard Darwin.fstat(tempFD, &tempInfo) == 0,
                  isPrivateRegularFile(tempInfo),
                  Darwin.fchmod(tempFD, 0o600) == 0 else {
                Darwin.close(tempFD)
                throw StorageError.unavailable
            }
            try payload.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(tempFD, base.advanced(by: offset), rawBuffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw StorageError.unavailable
                    }
                    offset += written
                }
            }
            _ = Darwin.fsync(tempFD)
            Darwin.close(tempFD)
        } catch {
            Darwin.close(tempFD)
            throw error
        }

        // Re-verify the destination slot right before rename so no link swap slips in between.
        _ = try verifyTargetSlot(in: directoryFD)
        guard Darwin.renameat(directoryFD, tempName, directoryFD, fileName) == 0 else {
            throw StorageError.unavailable
        }
        renamed = true

        var fileResourceURL = anchored.appendingPathComponent(fileName, isDirectory: false)
        var fileResources = URLResourceValues()
        fileResources.isExcludedFromBackup = true
        try? fileResourceURL.setResourceValues(fileResources)
    }
}

struct SnippetSettingsView: View {
    private static let placeholderTokens = ["{{date}}", "{{time}}", "{{datetime}}", "{{clipboard}}"]

    @ObservedObject var model: Launcher
    @ObservedObject var library: SnippetLibrary
    let clipboardPreviewText: () -> String?
    @Binding var prefillContent: String?

    @State private var editingID: UUID?
    @State private var alias = ""
    @State private var title = ""
    @State private var content = ""
    @State private var pinnedToHome = false
    @State private var errorMessage: String?

    init(
        model: Launcher,
        library: SnippetLibrary,
        clipboardPreviewText: @escaping () -> String? = { nil },
        prefillContent: Binding<String?> = .constant(nil)
    ) {
        self.model = model
        self.library = library
        self.clipboardPreviewText = clipboardPreviewText
        self._prefillContent = prefillContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTheme.spacingLG) {
            LumenSettingsHeader(
                kicker: "SNIPPETS",
                title: model.t("常用短语", "Snippets"),
                description: model.t(
                    "常用短语保存在独立短语库中永久保留，永远不会被剪贴板历史条数上限或清空操作清除。在搜索框输入别名即可直接匹配并展开动态变量。",
                    "Snippets are permanently saved in a dedicated library and are never evicted or cleared by clipboard history. Type an alias in search to match and expand variables."
                )
            )

            editorCard
            savedListCard
        }
        .onChange(of: prefillContent, initial: true) { _, incoming in
            consumePrefill(incoming)
        }
    }

    private var editorCard: some View {
        LumenSettingsCard(
            title: editingID == nil ? model.t("新建常用短语", "New Snippet") : model.t("编辑常用短语", "Edit Snippet"),
            icon: editingID == nil ? "plus.circle" : "pencil.circle"
        ) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(model.t("别名（必填）", "Alias (Required)"))
                    TextField("", text: $alias, prompt: Text(model.t("例如：fapiao / ribao", "e.g. fapiao / ribao")))
                        .lumenWellField()
                        .accessibilityIdentifier("settings.snippets.alias")
                        .onChange(of: alias) { _, _ in errorMessage = nil }
                }
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(model.t("标题（可选）", "Title (Optional)"))
                    TextField("", text: $title, prompt: Text(model.t("留空则取正文首行", "Optional; defaults to first line")))
                        .lumenWellField()
                        .accessibilityIdentifier("settings.snippets.title")
                }
            }

            Text(model.t(
                "1–32 个小写字符，不含空格或保留命令（qa、tr、translate、img、cb、clip、win）。",
                "1–32 lowercase characters with no spaces or built-in verbs (qa, tr, translate, img, cb, clip, win)."
            ))
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    fieldLabel(model.t("短语正文", "Snippet Content"))
                    Spacer(minLength: 4)
                    ForEach(Self.placeholderTokens, id: \.self) { token in
                        Button(token) {
                            content.append(token)
                            errorMessage = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(SettingsTheme.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(SettingsTheme.amber.opacity(0.12), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(SettingsTheme.amber.opacity(0.24), lineWidth: 0.75)
                                .allowsHitTesting(false)
                        )
                        .contentShape(Capsule())
                    }
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $content)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .accessibilityIdentifier("settings.snippets.content")
                        .onChange(of: content) { _, _ in errorMessage = nil }
                    if content.isEmpty {
                        Text(model.t(
                            "输入常用短语正文，支持点击上方 {{date}}、{{time}}、{{datetime}}、{{clipboard}} 插入变量",
                            "Enter snippet text. Click {{date}}, {{time}}, {{datetime}}, or {{clipboard}} above to insert variables."
                        ))
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textTertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                    }
                }
                .frame(height: 104)
                .background(
                    RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                        .fill(SettingsTheme.wellBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsTheme.cornerMD, style: .continuous)
                        .strokeBorder(SettingsTheme.wellBorder, lineWidth: 0.75)
                        .allowsHitTesting(false)
                )
            }

            if ClipboardTemplateExpander.containsVariables(content) {
                let preview = ClipboardTemplateExpander.expand(content, clipboardText: clipboardPreviewText())
                LumenSettingsWell(padding: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(model.t("实时预览", "Live Preview").uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(SettingsTheme.amber)
                        Text(verbatim: preview.isEmpty ? model.t("（展开后为空）", "(empty after expansion)") : preview)
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            LumenSettingsHairline()

            HStack(spacing: 10) {
                Toggle(model.t("在空搜索框首页置顶显示", "Pin to empty search home"), isOn: $pinnedToHome)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .accessibilityIdentifier("settings.snippets.pinToHome")
                Spacer()
                if editingID != nil {
                    Button(model.t("取消编辑", "Cancel Editing")) {
                        resetDraft()
                    }
                    .buttonStyle(LumenSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.snippets.cancel")
                }
                Button(model.t("保存", "Save")) {
                    saveDraft()
                }
                .buttonStyle(LumenPrimaryButtonStyle())
                .accessibilityIdentifier("settings.snippets.save")
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.snippets.error")
            }
        }
    }

    private var savedListCard: some View {
        LumenSettingsCard(
            title: model.t("已保存短语", "Saved Snippets"),
            icon: "text.quote",
            trailing: {
                if !library.snippets.isEmpty {
                    Text("\(library.snippets.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SettingsTheme.textTertiary)
                }
            }
        ) {
            if library.snippets.isEmpty {
                LumenSettingsWell {
                    HStack(spacing: 8) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsTheme.textTertiary)
                            .accessibilityHidden(true)
                        Text(model.t(
                            "暂无常用短语。在上方填写别名和正文即可永久保存。",
                            "No snippets saved yet. Add an alias and content above to save one permanently."
                        ))
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                LumenSettingsWell(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(Array(library.snippets.enumerated()), id: \.element.id) { index, snippet in
                            if index > 0 { LumenSettingsHairline().padding(.horizontal, 8) }
                            savedRow(snippet)
                        }
                    }
                }
            }
        }
    }

    private func savedRow(_ snippet: SavedSnippet) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: snippet.alias)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(SettingsTheme.amber)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(SettingsTheme.amber.opacity(0.12), in: Capsule())
                .lineLimit(1)
                .layoutPriority(1)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: snippet.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: singleLinePreview(snippet.content))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                library.togglePinToHome(snippet.id)
                if editingID == snippet.id {
                    pinnedToHome = library.snippets.first(where: { $0.id == snippet.id })?.pinnedToHome ?? pinnedToHome
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: snippet.pinnedToHome ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                    if snippet.pinnedToHome {
                        Text(model.t("首页置顶", "Home"))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                }
                .foregroundStyle(snippet.pinnedToHome ? SettingsTheme.amber : SettingsTheme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    (snippet.pinnedToHome ? SettingsTheme.amber.opacity(0.12) : Color.clear),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help(snippet.pinnedToHome
                ? model.t("已在空搜索框首页置顶，点击取消置顶", "Pinned to empty search home; click to unpin")
                : model.t("点击在空搜索框首页置顶显示", "Pin to empty search home"))
            .accessibilityLabel(snippet.pinnedToHome
                ? model.t("取消首页置顶", "Unpin from home")
                : model.t("在空搜索框首页置顶显示", "Pin to empty search home"))

            Button(model.t("编辑", "Edit")) {
                startEditing(snippet)
            }
            .buttonStyle(LumenSecondaryButtonStyle())
            .controlSize(.small)

            Button(model.t("删除", "Delete")) {
                library.remove(snippet.id)
                if editingID == snippet.id { resetDraft() }
            }
            .buttonStyle(LumenSecondaryButtonStyle())
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(SettingsTheme.textTertiary)
    }

    private func singleLinePreview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func consumePrefill(_ incoming: String?) {
        guard let incoming else { return }
        editingID = nil
        alias = ""
        title = ""
        content = incoming
        pinnedToHome = false
        errorMessage = nil
        prefillContent = nil
    }

    private func startEditing(_ snippet: SavedSnippet) {
        editingID = snippet.id
        alias = snippet.alias
        title = snippet.title
        content = snippet.content
        pinnedToHome = snippet.pinnedToHome
        errorMessage = nil
    }

    private func resetDraft() {
        editingID = nil
        alias = ""
        title = ""
        content = ""
        pinnedToHome = false
        errorMessage = nil
    }

    private func saveDraft() {
        switch library.save(
            id: editingID,
            alias: alias,
            title: title,
            content: content,
            pinnedToHome: pinnedToHome
        ) {
        case .saved:
            resetDraft()
        case .emptyContent:
            errorMessage = model.t("短语内容不能为空。", "Snippet content cannot be empty.")
        case .invalidAlias:
            errorMessage = model.t(
                "别名需为 1–32 个小写字符，且不能包含空格或控制字符。",
                "Alias must be 1–32 characters with no spaces or control characters."
            )
        case .reservedAlias(let verb):
            errorMessage = model.t(
                "别名不能使用保留命令「\(verb)」。",
                "Alias cannot use reserved command “\(verb)”."
            )
        case .aliasInUse(let used):
            errorMessage = model.t(
                "别名「\(used)」已被其他短语占用，请更换别名。",
                "The alias “\(used)” is already in use. Choose another alias."
            )
        case .storageFailed:
            errorMessage = model.t(
                "无法写入短语库文件，请检查 Application Support 目录权限。",
                "Could not save snippets. Check Application Support directory permissions."
            )
        }
    }
}
