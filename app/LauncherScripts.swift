import Darwin
import Foundation
import os

struct LauncherExecutable: Equatable, Sendable {
    enum Mode: String, Sendable { case compact, fullOutput, silent, inline }
    enum Source: Equatable, Sendable {
        // Keep the result row's case shape; only the folder and name carry data.
        case script(folder: String, Never? = nil, name: String, Never? = nil)
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

    static func isResident(_ attributes: stat) -> Bool { attributes.st_flags & UInt32(SF_DATALESS) == 0 }

    // Accept only the two fixed macOS aliases also used by IndexScope. Don't resolve user symlinks.
    static func path(_ url: URL) -> String? {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return IndexScope.folderPath(url)
    }

    static func openDirectory(_ path: String) -> Int32 {
        var info = stat()
        guard path.hasPrefix("/"), !path.utf8.contains(0), lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, isResident(info) else { return -1 }
        return open(path, O_RDONLY | O_DIRECTORY | noLinks)
    }

    static func isExecutable(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && isResident(info) && access(path, X_OK) == 0
    }

    static func scan(_ folder: String, isCancelled: () -> Bool = { false }) -> [LauncherExecutable]? {
        withNoDatalessMaterialization {
            let fd = openDirectory(folder)
            guard fd >= 0 else { return nil }
            guard let stream = fdopendir(fd) else { close(fd); return nil }
            defer { closedir(stream) }
            var commands: [LauncherExecutable] = []
            while !isCancelled() {
                errno = 0
                guard let entry = readdir(stream) else { return errno == 0 ? commands : nil }
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                    String(bytes: raw.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
                }
                guard let name, !name.hasPrefix(".") else { continue }
                let path = folder + "/" + name
                guard isExecutable(path) else { continue }
                let file = open(path, O_RDONLY | O_NONBLOCK | noLinks)
                guard file >= 0 else { continue }
                defer { close(file) }
                var info = stat()
                guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, isResident(info) else { continue }
                var header = Data(count: headerLimit)
                let count = header.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
                guard count >= 0 else { continue }
                header.count = count
                let source = LauncherExecutable.Source.script(folder: folder, name: name)
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
            guard let homePath = path(home) else { return nil }
            var parent = openDirectory(homePath)
            guard parent >= 0 else { return nil }
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
            return withNoDatalessMaterialization { () -> Result? in
                switch command.source {
                case .script(let folder, _, let name, _):
                    let path = folder + "/" + name
                    let directory = LauncherScriptFiles.openDirectory(folder)
                    guard directory >= 0 else { return nil }
                    defer { close(directory) }
                    guard LauncherScriptFiles.isExecutable(path) else { return nil }
                    return run(path, arguments: argument.map { [$0] } ?? [], directory: directory,
                               deadline: deadline, isCancelled: cancelled)
                case .shortcut(let name):
                    var arguments = ["run"]
                    if let argument {
                        guard argument.hasPrefix("/"), let path = LauncherScriptFiles.path(URL(fileURLWithPath: argument)),
                              SearchHit.pathAttributes(at: path, kind: "file") != nil else { return nil }
                        arguments.append("--input-path=\(path)")
                    }
                    return run(shortcuts.path, arguments: arguments + ["--", name], deadline: deadline, isCancelled: cancelled)
                }
            } ?? Result(status: interruption(deadline, isCancelled: cancelled) ?? .unavailable)
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

    static func run(_ executable: String, arguments: [String], directory: Int32? = nil,
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
        let words = [executable] + arguments
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
        guard spawned == 0 else { return Result(status: .unavailable) }
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
