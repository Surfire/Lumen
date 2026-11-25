import AppKit
import SwiftUI

private struct SearchHit: Decodable, Identifiable {
    let path: String
    let name: String
    let kind: String
    let availability: String
    let matched_by: String
    let snippet: String?
    var id: String { path }
}
private struct SearchReply: Decodable {
    let id: UInt64?
    let hits: [SearchHit]?
    let error: String?
}
private struct SearchRequest: Encodable {
    let id: UInt64
    let query: String
    let mode: String
    let limit = 60
}

@MainActor
private final class Launcher: ObservableObject {
    @Published var hits: [SearchHit] = []
    @Published var message: String?
    @Published var indexing = false
    @Published var query = ""
    @Published var lexicalMode = "all"
    @Published var semanticBusy = false
    @Published var disclosure = false
    @Published var confirm = false
    @Published var scanReport = ""
    @Published var selection: String?
    var text = ""
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var request: UInt64 = 0
    private var generation: UInt64 = 0
    private var debounce: Task<Void, Never>?

    private var engine: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("lumen")
    }
    func update(_ q: String) {
        text = q
        request &+= 1
        debounce?.cancel()
        if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hits = []
            selection = nil
            message = nil
            return
        }
        let current = request
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000)
            if !Task.isCancelled, let self, self.request == current { self.send(q, current) }
        }
    }
    private func send(_ text: String, _ id: UInt64) {
        guard !indexing, !semanticBusy else { return }
        do {
            if process?.isRunning != true { try start() }
            var data = try JSONEncoder().encode(SearchRequest(id: id, query: text, mode: lexicalMode))
            data.append(10)
            try input?.write(contentsOf: data)
        } catch {
            hits = []
            message = error.localizedDescription
            stop()
        }
    }
    private func start() throws {
        stop()
        guard let engine else { return }
        let p = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = engine
        p.arguments = ["serve"]
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        let token = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            if data.isEmpty { file.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.accept(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            if data.isEmpty { file.readabilityHandler = nil; return }
            let error = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.message = error.trimmingCharacters(in: .whitespacesAndNewlines)
                self.hits = []
            }
        }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
    }
    private func accept(_ bytes: Data) {
        buffer.append(bytes)
        while let index = buffer.firstIndex(of: 10) {
            let line = Data(buffer.prefix(upTo: index))
            buffer.removeSubrange(buffer.startIndex...index)
            guard let reply = try? JSONDecoder().decode(SearchReply.self, from: line), reply.id == request else { continue }
            hits = reply.hits ?? []
            selection = hits.first?.path
            message = reply.error
        }
    }
    private func stop() {
        generation &+= 1
        if process?.isRunning == true { process?.terminate() }
        try? input?.close()
        process = nil
        input = nil
        buffer = Data()
    }
    // Semantic work is explicit, never triggered during typeahead.
    func buildEmbeddings(language: String) {
        guard !indexing, !semanticBusy, let engine else { return }
        let helper = engine.deletingLastPathComponent().appendingPathComponent("LumenLocalEmbedding")
        runLocal(arguments: ["embed", "--helper", helper.path, "--language", language, "--max", "32"]) { [weak self] ok, data in
            guard let self else { return }
            self.scanReport = String(decoding: data, as: UTF8.self)
            if !ok { self.message = self.scanReport }
        }
    }
    func semantic(language: String) {
        guard !indexing, !semanticBusy, !query.isEmpty, let engine else { return }
        let helper = engine.deletingLastPathComponent().appendingPathComponent("LumenLocalEmbedding")
        request &+= 1
        let id = request
        let text = query
        runLocal(arguments: ["query", "--mode", "semantic", "--helper", helper.path, "--language", language, "--", text]) { [weak self] ok, data in
            guard let self else { return }
            if self.request != id || self.query != text { self.update(self.query); return }
            if ok, let results = try? JSONDecoder().decode([SearchHit].self, from: data) {
                self.hits = results
                self.selection = results.first?.path
                self.message = nil
            } else {
                self.hits = []
                self.message = String(decoding: data, as: UTF8.self)
            }
        }
    }
    private func runLocal(arguments: [String], complete: @escaping (Bool, Data) -> Void) {
        guard let engine else { return }
        debounce?.cancel()
        stop()
        semanticBusy = true
        message = nil
        let p = Process()
        let output = Pipe()
        p.executableURL = engine
        p.arguments = arguments
        p.standardOutput = output
        p.standardError = output
        // Drain before waiting for termination: a long result can exceed pipe capacity.
        do {
            try p.run()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                p.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.semanticBusy = false
                    complete(p.terminationStatus == 0, data)
                }
            }
        } catch {
            semanticBusy = false
            complete(false, Data(error.localizedDescription.utf8))
        }
    }
    func index(allow: String, deny: String, documents: Bool, complete: @escaping (Bool, String) -> Void) {
        guard !indexing, !semanticBusy, let engine else { return }
        stop()
        indexing = true
        hits = []
        message = nil
        let p = Process()
        let output = Pipe()
        p.executableURL = engine
        func paths(_ text: String) -> [String] {
            text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        p.arguments = ["index"] + paths(allow).flatMap { ["--allow", $0] } + paths(deny).flatMap { ["--deny", $0] } + (documents ? ["--documents", "--pdf-helper", engine.deletingLastPathComponent().appendingPathComponent("LumenPdfExtractor").path] : [])
        p.standardOutput = output
        p.standardError = output
        p.terminationHandler = { [weak self] p in
            let s = String(decoding: (try? output.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            let ok = p.terminationStatus == 0
            Task { @MainActor in
                guard let self else { return }
                self.indexing = false
                complete(ok, s)
                if ok { self.update(self.text) }
            }
        }
        do { try p.run() }
        catch {
            indexing = false
            complete(false, error.localizedDescription)
        }
    }
}

@main
struct LumenApp: App {
    var body: some Scene {
        WindowGroup("Lumen") { SearchWindow() }
            .defaultSize(width: 780, height: 580)
    }
}

private struct SearchWindow: View {
    @StateObject private var model = Launcher()
    @AppStorage("language") private var language = "system"
    @AppStorage("allow") private var allow = ""
    @AppStorage("deny") private var deny = ""
    @AppStorage("documents") private var documents = false
    @AppStorage("semanticLanguage") private var semanticLanguage = "zh"
    @FocusState private var focus: Bool
    private var zh: Bool {
        language == "zh" || (language == "system" && (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false))
    }
    private func t(_ cn: String, _ en: String) -> String { zh ? cn : en }
    private func open(_ hit: SearchHit) {
        guard hit.availability == "local" else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
    }
    private func label(_ hit: SearchHit) -> String {
        switch hit.matched_by {
        case "semantic": return t("语义", "Semantic")
        case "pinyin": return t("拼音", "Pinyin")
        case "text": return t("全文", "Text")
        case "path": return t("路径", "Path")
        default: return t("名称", "Name")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField(t("搜索名称、拼音、路径和全文", "Search names, pinyin, paths, and text"), text: $model.query)
                    .textFieldStyle(.plain).font(.title2).focused($focus)
                    .onChange(of: model.query) { _, value in model.update(value) }
                    .onSubmit {
                        if let hit = model.hits.first(where: { $0.path == model.selection }) { open(hit) }
                    }
                Button(t("建索引", "Build Index")) { model.confirm = true }.disabled(model.indexing || model.semanticBusy)
                    .confirmationDialog(t("建立本地索引？", "Build the local index?"), isPresented: $model.confirm) {
                        Button(t("开始", "Start")) {
                            model.scanReport = ""
                            model.index(allow: allow, deny: deny, documents: documents) { ok, report in
                                model.scanReport = (ok ? t("本轮已完成", "Scan completed") : t("本轮失败", "Scan failed")) + "\n" + report
                            }
                        }
                    } message: {
                        Text(t("默认扫描启动盘可访问目录的元数据。不下载网盘文件；全文默认关闭。", "By default scans readable startup disk metadata. No cloud downloads. Full text is off by default."))
                    }
            }
            HStack {
                Picker(t("搜索范围", "Search lane"), selection: $model.lexicalMode) {
                    Text(t("名称和全文", "Names and text")).tag("all")
                    Text(t("名称/拼音", "Names and Pinyin")).tag("name")
                    Text(t("只搜全文", "Text only")).tag("text")
                }
                .pickerStyle(.segmented).frame(maxWidth: 380)
                .onChange(of: model.lexicalMode) { _, _ in model.update(model.query) }
                Button(t("搜语义", "Semantic Search")) { model.semantic(language: semanticLanguage) }
                    .disabled(model.query.isEmpty || model.indexing || model.semanticBusy)
            }
            Divider()
            if model.semanticBusy { ProgressView(t("正在使用本机模型…", "Using the local model…")) }
            if model.indexing { ProgressView(t("正在建立索引…", "Building index…")) }
            if let message = model.message, !model.query.isEmpty {
                Text(t("如果还没有索引，请先点击「建索引」。", "If there is no index yet, choose Build Index first.")).foregroundStyle(.secondary)
                Text(message).font(.caption).textSelection(.enabled)
            } else if !model.indexing && !model.query.isEmpty && model.hits.isEmpty {
                Text(t("没有匹配结果", "No matches")).foregroundStyle(.secondary)
            }
            List(selection: $model.selection) {
                ForEach(model.hits) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: hit.kind == "directory" ? "folder" : "doc")
                            Text(hit.name).fontWeight(.medium)
                            Spacer()
                            Text(label(hit)).foregroundStyle(.secondary).font(.caption)
                            if hit.availability != "local" {
                                Image(systemName: "icloud").accessibilityLabel(t("仅元数据", "Metadata only"))
                            }
                        }
                        Text(hit.path).foregroundStyle(.secondary).font(.caption).lineLimit(1).truncationMode(.middle)
                        if let snippet = hit.snippet { Text(snippet).font(.caption).lineLimit(2) }
                    }
                    .tag(hit.path)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(hit) }
                }
            }.listStyle(.plain)
            DisclosureGroup(t("设置与索引状态", "Settings and index status"), isExpanded: $model.disclosure) {
                VStack(alignment: .leading) {
                    Picker(t("语言", "Language"), selection: $language) {
                        Text(t("跟随系统", "System")).tag("system")
                        Text("简体中文").tag("zh")
                        Text("English").tag("en")
                    }
                    Toggle(t("同时索引本地 TXT、Markdown 和 PDF 文本层", "Include local TXT, Markdown and PDF text"), isOn: $documents)
                    HStack {
                        Picker(t("语义模型语种", "Semantic model language"), selection: $semanticLanguage) {
                            Text("简体中文").tag("zh")
                            Text("English").tag("en")
                        }
                        Button(t("生成下一批语义索引（最多 32 份）", "Embed next batch (up to 32)")) {
                            model.buildEmbeddings(language: semanticLanguage)
                        }.disabled(model.indexing || model.semanticBusy)
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(t("白名单绝对路径（每行一个；空为默认范围）", "Allow paths (absolute, one per line; blank = default)")).font(.caption)
                            TextEditor(text: $allow).frame(height: 54)
                        }
                        VStack(alignment: .leading) {
                            Text(t("黑名单绝对路径（每行一个，优先于白名单）", "Deny paths (absolute, one per line; takes precedence)")).font(.caption)
                            TextEditor(text: $deny).frame(height: 54)
                        }
                    }
                    if !model.scanReport.isEmpty {
                        ScrollView { Text(model.scanReport).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 110)
                    }
                }.padding(.top, 6)
            }
        }
        .padding(18).frame(minWidth: 610, minHeight: 380).onAppear { focus = true }
    }
}
