import Combine
import Darwin
import Foundation
import os

struct LauncherExecutable: Equatable, Sendable {
    enum Mode: String, Sendable { case compact, fullOutput, silent, inline }
    enum Source: Equatable, Sendable {
        case script(folder: String, identity: String, name: String, stamp: String)
        case shortcut(String)
    }

    let source: Source
    var title: String
    var alias = ""
    var description = ""
    var mode: Mode = .compact
    var argument: String?

    var action: LaunchAction {
        let id: String, symbol: String
        switch source {
        case .script(let folder, _, let name, _): id = "script:\(folder)/\(name)"; symbol = "terminal"
        case .shortcut(let name): id = "apple-shortcut:" + name; symbol = "square.stack"
        }
        return LaunchAction(id: id, english: title, chinese: title, symbol: symbol,
                            destination: .executable(self), aliases: [alias, description].filter { !$0.isEmpty })
    }

    static func parse(_ prefix: Data, eof: Bool, source: Source, fallback: String) -> Self {
        var command = Self(source: source, title: fallback)
        let bytes = [UInt8](prefix.prefix(LauncherScriptFiles.headerLimit))
        var seen = Set<String>()
        var start = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
        while start < bytes.count {
            var end = start
            while end < bytes.count && bytes[end] != 10 && bytes[end] != 13 { end += 1 }
            let line = bytes[start..<end]
            start = end + 1
            if end == bytes.count && (!eof || prefix.count > LauncherScriptFiles.headerLimit) { break }
            guard line.count <= 1024, !line.contains(0), let text = String(bytes: line, encoding: .utf8) else { continue }
            let trimmed = text.drop(while: \.isWhitespace)
            let comment: Substring
            if trimmed.hasPrefix("#") { comment = trimmed.dropFirst() }
            else if trimmed.hasPrefix("//") { comment = trimmed.dropFirst(2) }
            else { continue }
            let header = comment.drop(while: \.isWhitespace)
            guard header.hasPrefix("@lumen."),
                  let split = header.firstIndex(where: { $0.isWhitespace || $0 == "=" }) else { continue }
            let key = String(header[..<split])
            var value = header[split...].drop(while: \.isWhitespace)
            if value.first == "=" { value = value.dropFirst().drop(while: \.isWhitespace) }
            guard let last = value.lastIndex(where: { !$0.isWhitespace }) else { continue }
            let rest = String(value[...last])
            guard !rest.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  seen.insert(key).inserted else { continue }
            switch key {
            case "@lumen.title": command.title = rest
            case "@lumen.alias": command.alias = rest
            case "@lumen.description": command.description = rest
            case "@lumen.mode": command.mode = Mode(rawValue: rest) ?? .compact
            case "@lumen.argument1": command.argument = rest
            default: break
            }
        }
        return command
    }
}

enum LauncherScriptFiles {
    static let headerLimit = 8 * 1024
    // Darwin rejects combining O_NOFOLLOW_ANY with O_NOFOLLOW; ANY includes the leaf.
    private static let noLinks = O_NOFOLLOW_ANY | O_CLOEXEC
    private static let stageLimit = 64 * 1024 * 1024

    static func isResident(_ attributes: stat) -> Bool { attributes.st_flags & UInt32(SF_DATALESS) == 0 }

    // Accept only the two fixed macOS aliases also used by IndexScope. Don't resolve user symlinks.
    static func path(_ url: URL) -> String? {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return IndexScope.folderPath(url)
    }

    private static func identity(_ attributes: stat) -> String { "\(attributes.st_dev):\(attributes.st_ino)" }

    private static func directory(_ path: String) -> (Int32, String)? {
        guard let before = SearchHit.pathAttributes(at: path, kind: "directory") else { return nil }
        let fd = open(path, O_RDONLY | O_DIRECTORY | noLinks)
        guard fd >= 0 else { return nil }
        var actual = stat()
        guard fstat(fd, &actual) == 0, isResident(actual), identity(actual) == identity(before) else {
            close(fd)
            return nil
        }
        return (fd, identity(actual))
    }

    private static func openFile(in dir: Int32, name: String, executable: Bool) -> (Int32, stat)? {
        func allowed(_ info: stat) -> Bool {
            info.st_mode & S_IFMT == S_IFREG && isResident(info) && info.st_nlink == 1
                && (!executable || info.st_mode & S_IXUSR != 0)
        }
        var before = stat(), actual = stat()
        guard fstatat(dir, name, &before, AT_SYMLINK_NOFOLLOW) == 0, allowed(before) else { return nil }
        // O_NONBLOCK keeps a concurrently substituted FIFO from stalling the worker.
        let fd = openat(dir, name, O_RDONLY | O_NONBLOCK | noLinks)
        guard fd >= 0 else { return nil }
        guard fstat(fd, &actual) == 0, allowed(actual), identity(actual) == identity(before) else {
            close(fd)
            return nil
        }
        return (fd, actual)
    }

    static func scan(_ folder: String, isCancelled: () -> Bool = { false }) -> [LauncherExecutable]? {
        withNoDatalessMaterialization {
            guard let (fd, folderID) = directory(folder) else { return nil }
            defer { close(fd) }
            let enumeration = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard enumeration >= 0 else { return nil }
            guard let stream = fdopendir(enumeration) else { close(enumeration); return nil }
            defer { closedir(stream) }
            var commands: [LauncherExecutable] = []
            while !isCancelled() {
                errno = 0
                guard let entry = readdir(stream) else { return errno == 0 ? commands : nil }
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                    String(bytes: raw.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
                }
                guard let name, !name.hasPrefix("."),
                      let (file, info) = openFile(in: fd, name: name, executable: true) else { continue }
                defer { close(file) }
                var header = Data(count: headerLimit)
                let count = header.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
                guard count >= 0 else { continue }
                header.count = count
                let source = LauncherExecutable.Source.script(folder: folder, identity: folderID, name: name,
                                                               stamp: SearchHit.filesystemStamp(info))
                commands.append(.parse(header, eof: Int64(count) == info.st_size, source: source, fallback: name))
            }
            return nil
        }
    }

    static var suggestedFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lumen/Scripts", isDirectory: true)
    }

    static func createSuggestedFolder() -> URL? {
        withNoDatalessMaterialization {
            let home = FileManager.default.homeDirectoryForCurrentUser
            guard let homePath = path(home), let (homeFD, _) = directory(homePath) else { return nil }
            var parent = homeFD
            defer { close(parent) }
            for component in ["Library", "Application Support", "Lumen", "Scripts"] {
                guard mkdirat(parent, component, 0o700) == 0 || errno == EEXIST else { return nil }
                var info = stat()
                guard fstatat(parent, component, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFDIR, isResident(info) else { return nil }
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | noLinks)
                guard next >= 0 else { return nil }
                close(parent)
                parent = next
            }
            return suggestedFolder
        }
    }

    // Darwin's spawn takes a path, not an executable fd. Run a private local snapshot of
    // the checked file so a path replacement (including a shebang reopen) can't hydrate
    // or execute a different file. Keep the approved folder as the working directory.
    static func withStagedFile(_ source: LauncherExecutable.Source, inputPath: String? = nil,
                               deadline: ContinuousClock.Instant, isCancelled: () -> Bool,
                               _ body: (String, Int32) -> LauncherProcess.Result) -> LauncherProcess.Result? {
        var dirFD: Int32 = -1
        defer { if dirFD >= 0 { close(dirFD) } }
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let staged: String? = withNoDatalessMaterialization {
            let folder: String, name: String, executable: Bool, folderID: String?, stamp: String?
            switch source {
            case .script(let root, let identity, let filename, let version):
                (folder, name, executable, folderID, stamp) = (root, filename, true, identity, version)
            case .shortcut:
                guard let inputPath, inputPath.hasPrefix("/"), !inputPath.utf8.contains(0),
                      let localPath = path(URL(fileURLWithPath: inputPath)) else { return nil }
                let url = URL(fileURLWithPath: localPath)
                (folder, name, executable, folderID, stamp) = (url.deletingLastPathComponent().path, url.lastPathComponent, false, nil, nil)
            }
            guard let (dir, actualID) = directory(folder) else { return nil }
            dirFD = dir
            guard folderID == nil || folderID == actualID,
                  let (file, info) = openFile(in: dir, name: name, executable: executable) else { return nil }
            defer { close(file) }
            let version = SearchHit.filesystemStamp(info)
            guard stamp == nil || stamp == version, info.st_size <= stageLimit else { return nil }
            let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let templatePath = IndexScope.folderPath(base.appendingPathComponent("LumenCommand.XXXXXX"))
            var template = templatePath.utf8CString
            guard let temp = template.withUnsafeMutableBufferPointer({ buffer in
                mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
            }) else { return nil }
            let root = URL(fileURLWithPath: temp, isDirectory: true)
            temporary = root
            let target = root.appendingPathComponent(name).path
            let output = open(target, O_WRONLY | O_CREAT | O_EXCL | noLinks, mode_t(executable ? 0o700 : 0o600))
            guard output >= 0 else { return nil }
            defer { close(output) }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var total = 0
            while !isCancelled(), ContinuousClock.now < deadline {
                let count = read(file, &buffer, buffer.count)
                if count == 0 {
                    var after = stat()
                    // Preserve xattrs (including quarantine) on executing a staged copy.
                    guard (!executable || fcopyfile(file, output, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0),
                          fstat(file, &after) == 0, isResident(after), SearchHit.filesystemStamp(after) == version else { return nil }
                    return target
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0, total + count <= stageLimit else { return nil }
                total += count
                let written = buffer.withUnsafeBytes { raw -> Bool in
                    var offset = 0
                    while offset < count {
                        let n = write(output, raw.baseAddress! + offset, count - offset)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { return false }
                        offset += n
                    }
                    return true
                }
                guard written else { return nil }
            }
            return nil
        }
        guard let staged else { return nil }
        return body(staged, dirFD)
    }
}

// These workers do blocking POSIX I/O, so don't occupy Swift's cooperative executor.
final class LauncherWorkCancellation: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

enum LauncherProcess {
    static let executionTimeout: Duration = .seconds(15)
    static let outputLimit = 64 * 1024
    static let truncationMarker = "\n[output truncated]"

    enum Status: Equatable, Sendable { case exited(Int), timedOut, cancelled, unavailable }

    struct Capture: Equatable, Sendable {
        private(set) var bytes = Data()
        private(set) var truncated = false
        var text: String { String(decoding: bytes, as: UTF8.self) + (truncated ? LauncherProcess.truncationMarker : "") }

        mutating func append(_ data: UnsafeRawBufferPointer) {
            let available = LauncherProcess.outputLimit - bytes.count
            if data.count > available { truncated = true }
            if available > 0 { bytes.append(contentsOf: data.prefix(available)) }
        }
    }

    struct Result: Equatable, Sendable {
        var status: Status
        var stdout = Capture()
        var stderr = Capture()
        var succeeded: Bool { status == .exited(0) }
        var output: String {
            if stderr.bytes.isEmpty && !stderr.truncated { return stdout.text }
            if stdout.bytes.isEmpty && !stdout.truncated { return stderr.text }
            return stdout.text + "\n\n[stderr]\n" + stderr.text
        }
    }

    static func execute(_ command: LauncherExecutable, argument: String?, shortcuts: URL) async -> Result {
        await offMain { work in
            let deadline = ContinuousClock.now + executionTimeout
            let cancelled = { work.isCancelled }
            if let stop = interruption(deadline, isCancelled: cancelled) { return Result(status: stop) }
            guard argument?.utf8.contains(0) != true else { return Result(status: .unavailable) }
            switch command.source {
            case .script(_, _, let name, _):
                return LauncherScriptFiles.withStagedFile(command.source, deadline: deadline, isCancelled: cancelled) { staged, dir in
                    run(staged, argv0: name, arguments: argument.map { [$0] } ?? [], directory: dir, deadline: deadline, isCancelled: cancelled)
                } ?? Result(status: interruption(deadline, isCancelled: cancelled) ?? .unavailable)
            case .shortcut(let name):
                if let argument {
                    return LauncherScriptFiles.withStagedFile(command.source, inputPath: argument, deadline: deadline,
                                                              isCancelled: cancelled) { staged, _ in
                        run(shortcuts.path, arguments: ["run", "--input-path=\(staged)", "--", name], deadline: deadline, isCancelled: cancelled)
                    } ?? Result(status: interruption(deadline, isCancelled: cancelled) ?? .unavailable)
                }
                return run(shortcuts.path, arguments: ["run", "--", name], deadline: deadline, isCancelled: cancelled)
            }
        }
    }

    static func offMain<T: Sendable>(_ block: @escaping @Sendable (LauncherWorkCancellation) -> T) async -> T {
        let work = LauncherWorkCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: block(work)) }
            }
        } onCancel: { work.cancel() }
    }

    private static func interruption(_ deadline: ContinuousClock.Instant, isCancelled: () -> Bool) -> Status? {
        if isCancelled() { return .cancelled }
        if ContinuousClock.now >= deadline { return .timedOut }
        return nil
    }

    static func run(_ executable: String, argv0: String? = nil, arguments: [String], directory: Int32? = nil,
                    deadline: ContinuousClock.Instant, isCancelled: () -> Bool) -> Result {
        if let stop = interruption(deadline, isCancelled: isCancelled) { return Result(status: stop) }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return Result(status: .unavailable) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return Result(status: .unavailable) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var fds = [Int32]()
        defer { for fd in fds where fd >= 0 { close(fd) } }
        var mask = sigset_t()
        sigemptyset(&mask)
        // Set the group atomically before the child can fork, unlike setpgid after Process.run().
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0 else {
            return Result(status: .unavailable)
        }
        if let directory, posix_spawn_file_actions_addfchdir_np(&actions, directory) != 0 { return Result(status: .unavailable) }
        for output in [STDOUT_FILENO, STDERR_FILENO] {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { return Result(status: .unavailable) }
            fds += pair
            guard pair.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }),
                  fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0,
                  posix_spawn_file_actions_adddup2(&actions, pair[1], output) == 0 else { return Result(status: .unavailable) }
        }
        let words = [argv0 ?? executable] + arguments
        guard words.allSatisfy({ !$0.utf8.contains(0) }) else { return Result(status: .unavailable) }
        var argv = words.map { strdup($0) }
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { return Result(status: .unavailable) }
        argv.append(nil)
        environment.append(nil)
        var pid: pid_t = 0
        let spawned = withNoDatalessMaterialization {
            posix_spawn(&pid, executable, &actions, &attributes, &argv, &environment)
        }
        guard spawned == 0 else {
            return Result(status: .unavailable)
        }
        for index in [1, 3] { close(fds[index]); fds[index] = -1 }
        var readers = [pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0),
                       pollfd(fd: fds[2], events: Int16(POLLIN), revents: 0)]
        var stdout = Capture(), stderr = Capture()
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain(_ index: Int, into capture: inout Capture) {
            guard readers[index].fd >= 0 else { return }
            // Keep checking cancellation/deadline even if a writer is continuously ready.
            for _ in 0..<32 {
                let count = read(readers[index].fd, &buffer, buffer.count)
                if count == 0 { readers[index].fd = -1; return }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                buffer.withUnsafeBytes { capture.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
        }
        var outcome: Status = .unavailable
        while true {
            if let stop = interruption(deadline, isCancelled: isCancelled) { outcome = stop; break }
            var info = siginfo_t()
            // Keep the leader unreaped until cleanup so its PID/PGID cannot be recycled.
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                if info.si_pid != 0 {
                    outcome = .exited(info.si_code == CLD_EXITED ? Int(info.si_status) : 128 + Int(info.si_status))
                    break
                }
            } else if errno != EINTR { break }
            _ = poll(&readers, nfds_t(readers.count), 25)
            drain(0, into: &stdout)
            drain(1, into: &stderr)
        }
        _ = kill(-pid, SIGKILL)
        drain(0, into: &stdout)
        drain(1, into: &stderr)
        let reaped = waitpid(pid, nil, WNOHANG)
        if reaped == 0 || (reaped < 0 && errno == EINTR) {
            // Don't tie the timeout to a child stuck in kernel I/O after SIGKILL.
            DispatchQueue.global(qos: .utility).async { [pid] in
                while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
            }
        }
        return Result(status: outcome, stdout: stdout, stderr: stderr)
    }
}

@MainActor
final class LauncherScriptCatalog: ObservableObject {
    let shortcutsExecutable: URL
    @Published private(set) var scriptsEnabled: Bool
    @Published private(set) var folder: String?
    @Published private(set) var shortcutsEnabled: Bool
    @Published private(set) var scripts: [LauncherExecutable] = []
    @Published private(set) var shortcuts: [LauncherExecutable] = []
    @Published private(set) var scriptLoading = false
    @Published private(set) var shortcutLoading = false
    @Published private(set) var scriptFailed = false
    @Published private(set) var shortcutFailed = false
    private let defaults: UserDefaults?
    private var scriptLoad: Task<Void, Never>?
    private var shortcutLoad: Task<Void, Never>?

    init(defaults: UserDefaults?, shortcutsExecutable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) {
        self.defaults = defaults
        self.shortcutsExecutable = shortcutsExecutable
        let savedFolder = defaults?.string(forKey: "localScriptsFolder")
        folder = savedFolder
        scriptsEnabled = savedFolder != nil && defaults?.bool(forKey: "localScriptsEnabled") == true
        shortcutsEnabled = defaults?.bool(forKey: "appleShortcutsEnabled") == true
    }

    func selectFolder(_ url: URL) {
        guard let path = LauncherScriptFiles.path(url) else { scriptFailed = true; return }
        if folder != path { scripts = [] }
        folder = path
        defaults?.set(path, forKey: "localScriptsFolder")
        reloadScripts()
    }

    func createAndEnable() {
        scriptLoad?.cancel()
        scriptLoading = true
        scriptFailed = false
        scriptLoad = Task { [weak self] in
            let folder = await LauncherProcess.offMain { $0.isCancelled ? nil : LauncherScriptFiles.createSuggestedFolder() }
            guard !Task.isCancelled, let self else { return }
            self.scriptLoading = false
            self.scriptLoad = nil
            guard let folder else { self.scriptFailed = true; return }
            self.selectFolder(folder)
            self.setScriptsEnabled(true)
        }
    }

    func setScriptsEnabled(_ enabled: Bool) {
        guard !enabled || folder != nil else { return }
        scriptsEnabled = enabled
        defaults?.set(enabled, forKey: "localScriptsEnabled")
        reloadScripts()
    }

    func reloadScripts() {
        scriptLoad?.cancel()
        scriptLoad = nil
        scriptFailed = false
        guard scriptsEnabled, let folder else { scripts = []; scriptLoading = false; return }
        scriptLoading = true
        scriptLoad = Task { [weak self] in
            let commands = await LauncherProcess.offMain { work in LauncherScriptFiles.scan(folder) { work.isCancelled } }
            guard !Task.isCancelled, let self else { return }
            self.scripts = commands ?? []
            self.scriptFailed = commands == nil
            self.scriptLoading = false
            self.scriptLoad = nil
        }
    }

    func setShortcutsEnabled(_ enabled: Bool) {
        shortcutsEnabled = enabled
        defaults?.set(enabled, forKey: "appleShortcutsEnabled")
        refreshShortcuts()
    }

    func refreshShortcuts() {
        shortcutLoad?.cancel()
        shortcutLoad = nil
        shortcutFailed = false
        guard shortcutsEnabled else { shortcuts = []; shortcutLoading = false; return }
        shortcutLoading = true
        let executable = shortcutsExecutable.path
        shortcutLoad = Task { [weak self] in
            let result = await LauncherProcess.offMain { work in
                LauncherProcess.run(executable, arguments: ["list"], deadline: ContinuousClock.now + .seconds(5)) { work.isCancelled }
            }
            guard !Task.isCancelled, let self else { return }
            let names = Self.shortcutNames(result)
            if let names {
                self.shortcuts = names.map { LauncherExecutable(source: .shortcut($0), title: $0, mode: .fullOutput) }
            }
            self.shortcutFailed = names == nil
            self.shortcutLoading = false
            self.shortcutLoad = nil
        }
    }

    static func shortcutNames(_ result: LauncherProcess.Result) -> [String]? {
        guard result.succeeded, !result.stdout.truncated,
              let listing = String(data: result.stdout.bytes, encoding: .utf8) else { return nil }
        var seen = Set<String>()
        return listing.split { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }.map(String.init).filter {
            !$0.utf8.contains(0) && !$0.allSatisfy(\.isWhitespace) && seen.insert($0).inserted
        }
    }

    func contains(_ command: LauncherExecutable) -> Bool {
        switch command.source {
        case .script: return scriptsEnabled && scripts.contains(command)
        case .shortcut: return shortcutsEnabled && shortcuts.contains(command)
        }
    }

    @discardableResult func close() -> Task<Void, Never>? {
        scriptLoad?.cancel()
        shortcutLoad?.cancel()
        return shortcutLoad
    }
}
