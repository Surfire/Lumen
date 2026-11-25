import AppKit
import SwiftUI

struct LumenExtensionCatalog: Decodable, Sendable {
    let title: String
    let version: String?
    let snapshot: String
    let commands: [Command]

    struct Command: Decodable, Identifiable, Sendable {
        let name: String
        let title: String
        let description: String
        let arguments: [Argument]
        let unsupportedReason: String?
        var id: String { name }

        struct Argument: Decodable, Identifiable, Sendable {
            let name: String
            let placeholder: String
            var id: String { name }
        }
    }
}

enum LumenExtensionFailure: Error, Sendable {
    case hostUnavailable
    case nonlocalPackage
    case snapshotChanged
    case process(String)
    case invalidResponse
}

struct LumenExtensionHost: Sendable {
    enum CommandOutput: Sendable {
        case hud(String)
        case clipboard(String)
    }

    private let executable: URL?

    init(bundle: Bundle = .main) {
        executable = bundle.url(forResource: "lumen-extensions", withExtension: nil)
    }

    func list(package: URL) async throws -> LumenExtensionCatalog {
        try await request(package: package, arguments: ["list"])
    }

    func run(
        package: URL, snapshot: String, command: LumenExtensionCatalog.Command, values: [String: String]
    ) async throws -> CommandOutput {
        let arguments = command.arguments.flatMap { argument in
            ["--arg", "\(argument.name)=\(values[argument.name, default: ""])"]
        }
        let reply: RunReply = try await request(
            package: package, arguments: ["run", command.name] + arguments, snapshot: snapshot
        )
        switch (reply.hud, reply.clipboard) {
        case (.some(let message), nil): return .hud(message)
        case (nil, .some(let intent)): return .clipboard(intent.text)
        default: throw LumenExtensionFailure.invalidResponse
        }
    }

    private struct RunReply: Decodable, Sendable {
        let hud: String?
        let clipboard: ClipboardIntent?

        struct ClipboardIntent: Decodable, Sendable {
            let text: String
        }
    }

    private struct Termination: Sendable {
        let exited: Bool
        let status: Int32
    }

    private func request<Reply: Decodable & Sendable>(
        package: URL, arguments: [String], snapshot: String? = nil
    ) async throws -> Reply {
        guard let executable else { throw LumenExtensionFailure.hostUnavailable }
        var command = ["--package", package.path] + arguments
        if let snapshot { command += ["--expect-snapshot", snapshot] }
        let data = try await Task.detached(priority: .userInitiated) { [command] in
            guard package.isFileURL,
                  (try? package.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else {
                throw snapshot == nil ? LumenExtensionFailure.nonlocalPackage : .snapshotChanged
            }
            return try await Self.invoke(executable: executable, arguments: command)
        }.value
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Reply.self, from: data)
        } catch {
            throw LumenExtensionFailure.invalidResponse
        }
    }

    private static func invoke(executable: URL, arguments: [String]) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LumenExtensionFailure.hostUnavailable
        }
        let process = Process()
        let output = Pipe()
        let diagnostics = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = diagnostics
        let (termination, notification) = AsyncStream<Termination>.makeStream()
        process.terminationHandler = { process in
            notification.yield(Termination(exited: process.terminationReason == .exit,
                                           status: process.terminationStatus))
            notification.finish()
        }
        defer { process.terminationHandler = nil }
        do {
            try process.run()
            // Drain both pipes during execution. The termination callback avoids
            // relying on a run loop on the thread that resumes this task.
            async let stdout = read(output.fileHandleForReading)
            async let stderr = read(diagnostics.fileHandleForReading)
            var events = termination.makeAsyncIterator()
            let exit = await events.next()
            let (data, errors) = try await (stdout, stderr)
            if exit?.exited == true && exit?.status == 3 {
                throw LumenExtensionFailure.snapshotChanged
            }
            guard exit?.exited == true && exit?.status == 0 else {
                let message = String(decoding: errors, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LumenExtensionFailure.process(message)
            }
            return data
        } catch let failure as LumenExtensionFailure {
            throw failure
        } catch {
            throw LumenExtensionFailure.process(error.localizedDescription)
        }
    }

    private static func read(_ input: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try input.readToEnd() ?? Data() })
            }
        }
    }
}

@MainActor
final class LumenExtensionPanelModel: ObservableObject {
    enum Operation: Equatable {
        case list, run
    }

    enum Outcome {
        case hud(String)
        case clipboardPreview(text: String, copyFailed: Bool)
        case clipboardCopied
        case failure(Operation, LumenExtensionFailure)
    }

    @Published private(set) var package: URL?
    @Published private(set) var catalog: LumenExtensionCatalog?
    @Published private(set) var selection: String?
    @Published private(set) var values: [String: String] = [:]
    @Published private(set) var busy: Operation?
    @Published private(set) var outcome: Outcome?
    @Published var choosingPackage = false

    private let host: LumenExtensionHost

    init(host: LumenExtensionHost = LumenExtensionHost()) {
        self.host = host
    }

    var selectedCommand: LumenExtensionCatalog.Command? {
        catalog?.commands.first { $0.id == selection }
    }

    var canRun: Bool {
        guard busy == nil, let command = selectedCommand, command.unsupportedReason == nil else {
            return false
        }
        return command.arguments.allSatisfy { argument in
            let value = values[argument.name, default: ""]
            return !value.isEmpty && !hasInvalidText(value)
        }
    }

    func hasInvalidText(_ value: String) -> Bool {
        value.utf8.count > 1_024 || value.utf8.contains(0)
    }

    func load(_ directory: URL) async {
        guard busy == nil else { return }
        busy = .list
        defer { busy = nil }
        package = directory
        catalog = nil
        selection = nil
        values = [:]
        outcome = nil
        do {
            let catalog = try await host.list(package: directory)
            self.catalog = catalog
            selection = catalog.commands.first(where: { $0.unsupportedReason == nil })?.id
                ?? catalog.commands.first?.id
        } catch {
            outcome = .failure(.list, failure(from: error))
        }
    }

    func select(_ id: String?) {
        guard busy == nil, selection != id else { return }
        selection = id
        values = [:]
        outcome = nil
    }

    func setArgument(_ name: String, value: String) {
        guard busy == nil, selectedCommand?.arguments.contains(where: { $0.name == name }) == true else {
            return
        }
        values[name] = value
        outcome = nil
    }

    func runSelection() async {
        guard canRun, let package, let catalog, let command = selectedCommand else { return }
        busy = .run
        defer { busy = nil }
        outcome = nil
        do {
            let result = try await host.run(
                package: package, snapshot: catalog.snapshot, command: command, values: values
            )
            switch result {
            case .hud(let message):
                outcome = .hud(message)
            case .clipboard(let text):
                outcome = .clipboardPreview(text: text, copyFailed: false)
            }
        } catch {
            let problem = failure(from: error)
            if case .snapshotChanged = problem {
                self.catalog = nil
                selection = nil
                values = [:]
            }
            outcome = .failure(.run, problem)
        }
    }

    func confirmCopy(using write: (String) -> Bool) {
        guard busy == nil, !choosingPackage, case .clipboardPreview(let text, _) = outcome else { return }
        outcome = write(text) ? .clipboardCopied : .clipboardPreview(text: text, copyFailed: true)
    }

    private func failure(from error: Error) -> LumenExtensionFailure {
        (error as? LumenExtensionFailure) ?? .process(error.localizedDescription)
    }
}

struct LumenExtensionPanel: View {
    @AppStorage("language") private var language = "system"
    @ObservedObject var model: LumenExtensionPanelModel
    var chinese: (() -> Bool)?
    var parentWindow: () -> NSWindow? = { nil }

    init() { self.init(model: LumenExtensionPanelModel()) }

    init(model: LumenExtensionPanelModel,
         chinese: (() -> Bool)? = nil, parentWindow: @escaping () -> NSWindow? = { nil }) {
        self.model = model
        self.chinese = chinese
        self.parentWindow = parentWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let operation = model.busy {
                ProgressView(operation == .list
                             ? t("正在读取扩展包…", "Inspecting package…")
                             : t("正在运行命令…", "Running command…"))
                    .controlSize(.small)
            }
            if let catalog = model.catalog {
                Divider()
                commands(catalog)
            } else if let outcome = model.outcome {
                outcomeView(outcome)
                Spacer(minLength: 0)
            } else if model.busy == nil {
                Text(t("选择含有 package.json 和 src 目录的本地 Raycast 源码包。",
                       "Choose a local Raycast source package containing package.json and a src folder."))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer(minLength: 0)
                if let package = model.package {
                    Button(t("刷新", "Refresh")) { Task { await model.load(package) } }
                        .disabled(model.choosingPackage || model.busy != nil)
                        .accessibilityIdentifier("extension-refresh")
                }
                Button(t("选择本地扩展包…", "Choose Local Package…"), action: choosePackage)
                    .disabled(model.choosingPackage || model.busy != nil)
                    .accessibilityIdentifier("extension-choose-package")
            }
            if let package = model.package {
                Text(verbatim: package.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(package.path)
            }
            if let catalog = model.catalog {
                HStack {
                    Text(verbatim: catalog.title).fontWeight(.medium)
                    if let version = catalog.version {
                        Text(verbatim: version).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func commands(_ catalog: LumenExtensionCatalog) -> some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(catalog.commands) { command in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: command.title).lineLimit(2)
                        if command.unsupportedReason != nil {
                            Text(t("不支持", "Unsupported"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(command.id)
                    .accessibilityIdentifier("extension-command-\(command.id)")
                }
            }
            .listStyle(.plain)
            .accessibilityLabel(t("扩展命令", "Extension Commands"))
            .frame(width: 200)
            .disabled(model.choosingPackage || model.busy != nil)
            Divider()
            ScrollView {
                if let command = model.selectedCommand {
                    details(command)
                } else {
                    Text(t("选择一条命令。", "Select a command."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func details(_ command: LumenExtensionCatalog.Command) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: command.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: command.description)
            if let reason = command.unsupportedReason {
                Label(t("此命令不可运行", "This command cannot run"), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(verbatim: reason)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                if !command.arguments.isEmpty {
                    Text(t("必填参数", "Required Arguments"))
                        .font(.callout.weight(.semibold))
                }
                ForEach(command.arguments) { argument in
                    argumentField(argument)
                        .disabled(model.choosingPackage || model.busy != nil)
                }
                Button(t("运行命令", "Run Command")) {
                    Task { await model.runSelection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.choosingPackage || !model.canRun)
                .accessibilityIdentifier("extension-run")
                if let outcome = model.outcome {
                    Divider()
                    outcomeView(outcome)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
    }

    private func argumentField(_ argument: LumenExtensionCatalog.Command.Argument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: argument.placeholder).font(.callout)
            TextField(argument.placeholder, text: Binding(
                get: { model.values[argument.name, default: ""] },
                set: { model.setArgument(argument.name, value: $0) }
            ))
            .labelsHidden()
            .accessibilityIdentifier("extension-argument-\(argument.name)")
            if model.hasInvalidText(model.values[argument.name, default: ""]) {
                Text(t("请输入最多 1,024 字节的 UTF-8 文本，且不要包含空字符。",
                       "Enter at most 1,024 UTF-8 bytes with no null characters."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func outcomeView(_ outcome: LumenExtensionPanelModel.Outcome) -> some View {
        switch outcome {
        case .hud(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(t("命令消息", "Command Message")).font(.headline)
                Text(verbatim: message)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("extension-hud")
            }
        case .clipboardPreview(let text, let copyFailed):
            VStack(alignment: .leading, spacing: 6) {
                Text(t("复制预览", "Copy Preview")).font(.headline)
                Text(verbatim: text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("extension-clipboard-preview")
                Button(t("复制到剪贴板", "Copy to Clipboard"), action: copyPreview)
                    .disabled(model.choosingPackage || model.busy != nil)
                    .accessibilityIdentifier("extension-confirm-copy")
                if copyFailed {
                    Label(t("复制失败，请重试。", "Copy failed. Try again."),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        case .clipboardCopied:
            Label(t("已复制到剪贴板", "Copied to Clipboard"), systemImage: "checkmark")
                .accessibilityIdentifier("extension-clipboard-copied")
        case .failure(let operation, let failure):
            VStack(alignment: .leading, spacing: 4) {
                Label(operation == .list
                      ? t("读取扩展包失败", "Could Not Read Package")
                      : t("运行命令失败", "Command Failed"),
                      systemImage: "exclamationmark.circle")
                    .font(.headline)
                Text(verbatim: diagnostic(failure))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("extension-error")
            }
        }
    }

    private func copyPreview() {
        model.confirmCopy { text in
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string) else { return false }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])
        }
    }

    private func diagnostic(_ failure: LumenExtensionFailure) -> String {
        switch failure {
        case .hostUnavailable:
            t("当前 Lumen 构建缺少可运行的扩展宿主。", "This Lumen build is missing the extension host.")
        case .nonlocalPackage:
            t("请选择本机磁盘上的扩展包。", "Choose a package on a local disk.")
        case .snapshotChanged:
            t("扩展包在列出命令后已变更或无法验证。请刷新后重新选择命令。",
              "The package changed or could not be verified. Refresh and select the command again.")
        case .invalidResponse:
            t("扩展宿主返回了无法读取的结果。", "The extension host returned an unreadable response.")
        case .process(let message):
            message.isEmpty
                ? t("扩展宿主提前退出。", "The extension host exited early.")
                : message
        }
    }

    private func choosePackage() {
        guard !model.choosingPackage, model.busy == nil else { return }
        model.choosingPackage = true
        let panel = NSOpenPanel()
        panel.title = t("选择本地 Raycast 源码包", "Choose a Local Raycast Source Package")
        panel.prompt = t("选择", "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.canDownloadUbiquitousContents = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            model.choosingPackage = false
            guard response == .OK, let package = panel.url else { return }
            Task { await model.load(package) }
        }
        if let window = parentWindow() { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    private func t(_ cn: String, _ en: String) -> String {
        let useChinese = chinese?() ?? (language == "zh"
            || (language == "system" && Locale.preferredLanguages.first?.hasPrefix("zh") == true))
        return useChinese ? cn : en
    }
}
