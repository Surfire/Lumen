import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI

/// One pinned file from `gemma-assets.json` (shared with `src/gemma.rs` and `scripts/install-local-gemma.py`).
struct GemmaAssetSpec: Decodable, Equatable, Sendable {
    let name: String?
    let member: String?
    let directory: String?
    let revision: String?
    let size: Int64
    let sha256: String
}

struct GemmaAssetManifest: Decodable, Equatable, Sendable {
    let model: GemmaAssetSpec
    let image_projector: GemmaAssetSpec
    let archive: GemmaAssetSpec
    let runtime: [String: GemmaAssetSpec]

    var modelName: String { model.name ?? "embeddinggemma-2-Q8_0.gguf" }
    var projectorName: String { image_projector.name ?? "mmproj-embeddinggemma-2-Q8_0.gguf" }
    var archiveName: String { archive.name ?? "llama-b11457-bin-macos-arm64.tar.gz" }
    /// `llama-b11457-bin-macos-arm64.tar.gz` is published under the GitHub release tag `b11457`.
    var runtimeTag: String {
        let parts = archiveName.split(separator: "-")
        return parts.count > 1 ? String(parts[1]) : "b11457"
    }
}

enum GemmaAsset: String, CaseIterable, Sendable {
    case model, imageProjector, runtimeArchive
}

enum GemmaMirror: String, CaseIterable, Identifiable, Sendable {
    case huggingFace, hfMirror

    var id: Self { self }
    var title: String {
        switch self {
        case .huggingFace: return "HuggingFace"
        case .hfMirror: return "HF-Mirror"
        }
    }
    var host: String {
        switch self {
        case .huggingFace: return "huggingface.co"
        case .hfMirror: return "hf-mirror.com"
        }
    }
}

enum GemmaComponent: Sendable {
    case text, image
}

struct GemmaInstallFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Downloads or imports the pinned EmbeddingGemma 2 assets into
/// `~/Library/Application Support/Lumen/Gemma2` with the exact layout `GemmaModel` checks.
@MainActor
final class GemmaAssetManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(String)
        case verifying(String)
        case installing
        case unrecognizedImport
        case failed(String)
    }

    static let shared = GemmaAssetManager()
    nonisolated static let repository = "ggml-org/embeddinggemma-2-GGUF"
    nonisolated static let defaultHome: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lumen/Gemma2", isDirectory: true)

    @Published private(set) var textInstalled = false
    @Published private(set) var imageInstalled = false
    @Published private(set) var phase = Phase.idle
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published var mirror: GemmaMirror {
        didSet { defaults?.set(mirror.rawValue, forKey: "gemma.mirror.v1") }
    }

    let home: URL
    let manifest: GemmaAssetManifest?
    private let defaults: UserDefaults?
    private var work: Task<Void, Never>?

    init(home: URL = GemmaAssetManager.defaultHome, manifest: GemmaAssetManifest? = GemmaAssetManager.bundledManifest,
         defaults: UserDefaults? = .standard) {
        self.home = home
        self.manifest = manifest
        self.defaults = defaults
        // Smart default: the mainland China mirror when the region suggests HuggingFace is unreachable.
        let stored = defaults?.string(forKey: "gemma.mirror.v1").flatMap(GemmaMirror.init(rawValue:))
        mirror = stored ?? (Locale.current.region?.identifier == "CN" ? .hfMirror : .huggingFace)
        refresh()
    }

    var busy: Bool {
        switch phase {
        case .downloading, .verifying, .installing: return true
        case .idle, .unrecognizedImport, .failed: return false
        }
    }

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    var textBytes: Int64 { manifest.map { $0.model.size + $0.archive.size } ?? 0 }
    var imageBytes: Int64 { manifest?.image_projector.size ?? 0 }

    /// Cheap presence check (lstat + exact size); `lumen model-status --verify` owns the SHA-256 check.
    func refresh() {
        guard let manifest else { textInstalled = false; imageInstalled = false; return }
        textInstalled = Self.textAssetsPresent(home: home, manifest: manifest)
        imageInstalled = Self.regularFile(home.appendingPathComponent(manifest.projectorName), size: manifest.image_projector.size)
    }

    // MARK: Pure helpers (offline-testable)

    /// Read once per process; the pinned manifest never changes at runtime.
    nonisolated static let bundledManifest = loadManifest()

    nonisolated static func loadManifest(bundle: Bundle = .main) -> GemmaAssetManifest? {
        var candidates: [URL] = []
        if let bundled = bundle.url(forResource: "gemma-assets", withExtension: "json") { candidates.append(bundled) }
        #if LUMEN_SMOKE
        // Dev/smoke fallback only; release builds read the bundled resource exclusively.
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/gemma-assets.json"))
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/gemma-assets.json"))
        #endif
        for url in candidates {
            if let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(GemmaAssetManifest.self, from: data) {
                return manifest
            }
        }
        return nil
    }

    nonisolated static func downloadURL(asset: GemmaAsset, mirror: GemmaMirror, manifest: GemmaAssetManifest) -> URL? {
        switch asset {
        case .model:
            return huggingFaceURL(mirror: mirror, revision: manifest.model.revision, file: manifest.modelName)
        case .imageProjector:
            return huggingFaceURL(mirror: mirror, revision: manifest.image_projector.revision ?? manifest.model.revision,
                                  file: manifest.projectorName)
        case .runtimeArchive:
            // HF mirrors do not carry GitHub releases; the archive is pinned by size + SHA-256 anyway.
            return URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(manifest.runtimeTag)/\(manifest.archiveName)")
        }
    }

    private nonisolated static func huggingFaceURL(mirror: GemmaMirror, revision: String?, file: String) -> URL? {
        guard let revision, !revision.isEmpty else { return nil }
        return URL(string: "https://\(mirror.host)/\(repository)/resolve/\(revision)/\(file)")
    }

    /// Streams the file once, rejecting symlinks, non-regular files, and any size or digest mismatch.
    nonisolated static func verifyFileSHA256(at url: URL, expectedSHA256: String, expectedSize: Int64) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == expectedSize else { return false }
        var hasher = SHA256()
        var remaining = expectedSize
        while remaining > 0 {
            if Task.isCancelled { return false }
            let chunk: Data
            do { chunk = try handle.read(upToCount: Int(min(remaining, 4 << 20))) ?? Data() } catch { return false }
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        if let extra = try? handle.read(upToCount: 1), !extra.isEmpty { return false }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expectedSHA256.lowercased()
    }

    nonisolated static func regularFile(_ url: URL, size: Int64) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && Int64(info.st_size) == size
    }

    nonisolated static func textAssetsPresent(home: URL, manifest: GemmaAssetManifest) -> Bool {
        let runtime = home.appendingPathComponent("runtime", isDirectory: true)
        return regularFile(home.appendingPathComponent(manifest.modelName), size: manifest.model.size)
            && manifest.runtime.allSatisfy { regularFile(runtime.appendingPathComponent($0.key), size: $0.value.size) }
    }

    /// The installed default projector, when present with its pinned size.
    nonisolated static func installedProjector(home: URL = defaultHome, manifest: GemmaAssetManifest? = bundledManifest) -> URL? {
        guard let manifest else { return nil }
        let url = home.appendingPathComponent(manifest.projectorName)
        return regularFile(url, size: manifest.image_projector.size) ? url : nil
    }

    /// Classifies user-picked files by exact pinned size (SHA-256 is checked during install).
    nonisolated static func classify(_ urls: [URL], manifest: GemmaAssetManifest) -> [GemmaAsset: URL] {
        var found: [GemmaAsset: URL] = [:]
        for url in urls {
            var info = stat()
            // Never materialize a cloud-only (dataless) pick; copying it would download it.
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
            switch Int64(info.st_size) {
            case manifest.model.size: found[.model] = url
            case manifest.image_projector.size: found[.imageProjector] = url
            case manifest.archive.size: found[.runtimeArchive] = url
            default: continue
            }
        }
        return found
    }

    // MARK: Install actions

    func install(_ component: GemmaComponent, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let manifest, !busy else { return }
        var sources: [GemmaAsset: Source] = [:]
        switch component {
        case .text:
            guard let model = Self.downloadURL(asset: .model, mirror: mirror, manifest: manifest),
                  let archive = Self.downloadURL(asset: .runtimeArchive, mirror: mirror, manifest: manifest) else { return }
            sources = [.model: .remote(model), .runtimeArchive: .remote(archive)]
        case .image:
            guard let projector = Self.downloadURL(asset: .imageProjector, mirror: mirror, manifest: manifest) else { return }
            sources = [.imageProjector: .remote(projector)]
        }
        start(sources, manifest: manifest, completion: completion)
    }

    /// Offline fallback: pick already-downloaded `.gguf` / `.tar.gz` files.
    func importLocalFiles(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let manifest, !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.canDownloadUbiquitousContents = false
        panel.message = "embeddinggemma-2-Q8_0.gguf · mmproj-embeddinggemma-2-Q8_0.gguf · \(manifest.archiveName)"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, completion: completion)
    }

    /// Installs whichever complete components the given local files provide (also the offline smoke entry point).
    func importFiles(_ urls: [URL], completion: @escaping (Bool) -> Void = { _ in }) {
        guard let manifest, !busy else { return }
        let found = Self.classify(urls, manifest: manifest)
        let runtimePresent = manifest.runtime.allSatisfy {
            Self.regularFile(home.appendingPathComponent("runtime").appendingPathComponent($0.key), size: $0.value.size)
        }
        let modelPresent = Self.regularFile(home.appendingPathComponent(manifest.modelName), size: manifest.model.size)
        if found.isEmpty
            || (found[.model] != nil && found[.runtimeArchive] == nil && !runtimePresent)
            || (found[.runtimeArchive] != nil && found[.model] == nil && !modelPresent) {
            phase = .unrecognizedImport
            completion(false)
            return
        }
        start(found.mapValues { .local($0) }, manifest: manifest, completion: completion)
    }

    func cancel() {
        work?.cancel()
    }

    private enum Source: Sendable {
        case remote(URL)
        case local(URL)
    }

    private func start(_ sources: [GemmaAsset: Source], manifest: GemmaAssetManifest, completion: @escaping (Bool) -> Void) {
        downloadedBytes = 0
        totalBytes = 0
        phase = .verifying("")
        let home = home
        // The manager is main-actor isolated (Sendable); holding it for one install is intended.
        work = Task {
            let report: @Sendable (Phase, Int64, Int64) -> Void = { phase, done, total in
                Task { @MainActor in
                    guard self.busy else { return }
                    self.phase = phase
                    self.downloadedBytes = done
                    self.totalBytes = total
                }
            }
            // A nonisolated async call runs off the main actor and still receives this task's cancellation.
            let result: Result<Void, Error>
            do {
                try await Self.perform(sources, manifest: manifest, home: home, report: report)
                result = .success(())
            } catch { result = .failure(error) }
            self.work = nil
            self.refresh()
            switch result {
            case .success:
                self.phase = .idle
                completion(true)
            case .failure(let error):
                self.phase = error is CancellationError || Task.isCancelled ? .idle : .failed(error.localizedDescription)
                completion(false)
            }
        }
    }

    // MARK: Background install pipeline

    private nonisolated static func perform(_ sources: [GemmaAsset: Source], manifest: GemmaAssetManifest, home: URL,
                                            report: @escaping @Sendable (Phase, Int64, Int64) -> Void) async throws {
        let parent = home.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A private staging directory on the same volume keeps every final rename atomic.
        let staging = parent.appendingPathComponent(".lumen-gemma-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw failure("Could not create a private staging folder") }
        defer { try? FileManager.default.removeItem(at: staging) }

        let ordered = GemmaAsset.allCases.filter { sources[$0] != nil }
        var acquired: [GemmaAsset: URL] = [:]
        for asset in ordered {
            guard let source = sources[asset] else { continue }
            let spec = spec(asset, manifest)
            let destination = staging.appendingPathComponent(asset.rawValue)
            switch source {
            case .remote(let url):
                report(.downloading(asset.rawValue), 0, spec.size)
                try await GemmaDownload.fetch(url, to: destination, expected: spec.size) { done, total in
                    report(.downloading(asset.rawValue), done, total > 0 ? total : spec.size)
                }
            case .local(let url):
                report(.verifying(asset.rawValue), 0, 0)
                try FileManager.default.copyItem(at: url, to: destination)
            }
            try Task.checkCancellation()
            report(.verifying(asset.rawValue), 0, 0)
            guard verifyFileSHA256(at: destination, expectedSHA256: spec.sha256, expectedSize: spec.size) else {
                try Task.checkCancellation()
                throw failure("Unexpected size or SHA-256 for \(asset.rawValue)")
            }
            acquired[asset] = destination
        }

        var stagedRuntime: URL?
        if let archive = acquired[.runtimeArchive] {
            report(.verifying(GemmaAsset.runtimeArchive.rawValue), 0, 0)
            stagedRuntime = try unpackRuntime(archive, manifest: manifest, staging: staging)
        }
        try Task.checkCancellation()
        report(.installing, 0, 0)
        try installStaged(model: acquired[.model], runtime: stagedRuntime, projector: acquired[.imageProjector],
                          manifest: manifest, home: home, staging: staging)
    }

    private nonisolated static func spec(_ asset: GemmaAsset, _ manifest: GemmaAssetManifest) -> GemmaAssetSpec {
        switch asset {
        case .model: return manifest.model
        case .imageProjector: return manifest.image_projector
        case .runtimeArchive: return manifest.archive
        }
    }

    private nonisolated static func failure(_ message: String) -> GemmaInstallFailure { GemmaInstallFailure(message: message) }

    /// Extracts only the pinned members with `/usr/bin/tar` (bsdtar rejects `..`, absolute paths, and
    /// writes through symlinks by default), then re-verifies every member before it can be installed.
    private nonisolated static func unpackRuntime(_ archive: URL, manifest: GemmaAssetManifest, staging: URL) throws -> URL {
        guard let directory = manifest.archive.directory, !directory.isEmpty, !directory.contains("/"), directory != ".." else {
            throw failure("Invalid runtime manifest")
        }
        let extract = staging.appendingPathComponent("extract", isDirectory: true)
        let runtime = staging.appendingPathComponent("runtime", isDirectory: true)
        guard mkdir(extract.path, 0o700) == 0, mkdir(runtime.path, 0o700) == 0 else { throw failure("Could not stage the runtime") }
        var members: [String: String] = [:]
        for (name, spec) in manifest.runtime {
            guard let member = spec.member, !member.isEmpty, !member.contains("/"), member != "..",
                  !name.isEmpty, !name.contains("/"), name != ".." else { throw failure("Invalid runtime manifest") }
            members[name] = "\(directory)/\(member)"
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", extract.path, "--no-same-owner", "--no-same-permissions", "--"]
            + Array(Set(members.values)).sorted()
        tar.standardInput = FileHandle.nullDevice
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw failure("Could not unpack the runtime archive") }
        for (name, member) in members {
            guard let spec = manifest.runtime[name] else { continue }
            let source = extract.appendingPathComponent(member)
            guard verifyFileSHA256(at: source, expectedSHA256: spec.sha256, expectedSize: spec.size) else {
                throw failure("Unexpected size or SHA-256 for runtime \(name)")
            }
            let target = runtime.appendingPathComponent(name)
            // Members shared by two keys would be moved twice; copy keeps each key independent.
            try FileManager.default.copyItem(at: source, to: target)
            guard verifyFileSHA256(at: target, expectedSHA256: spec.sha256, expectedSize: spec.size),
                  chmod(target.path, name == "llama-server" ? 0o700 : 0o400) == 0 else {
                throw failure("Could not stage runtime \(name)")
            }
            clearQuarantine(target)
        }
        return runtime
    }

    private nonisolated static func installStaged(model: URL?, runtime: URL?, projector: URL?, manifest: GemmaAssetManifest,
                                                  home: URL, staging: URL) throws {
        if let model, chmod(model.path, 0o400) != 0 { throw failure("Could not protect the model") }
        if let projector, chmod(projector.path, 0o400) != 0 { throw failure("Could not protect the image model") }
        [model, projector].compactMap { $0 }.forEach(clearQuarantine)
        var info = stat()
        if lstat(home.path, &info) != 0 {
            guard errno == ENOENT else { throw failure("Could not inspect \(home.path)") }
            // Fresh install: assemble the private folder and publish it with one exclusive rename.
            let assets = staging.appendingPathComponent("assets", isDirectory: true)
            guard mkdir(assets.path, 0o700) == 0 else { throw failure("Could not stage the model folder") }
            if let model { try move(model, to: assets.appendingPathComponent(manifest.modelName)) }
            if let runtime { try move(runtime, to: assets.appendingPathComponent("runtime", isDirectory: true)) }
            if let projector { try move(projector, to: assets.appendingPathComponent(manifest.projectorName)) }
            guard renamex_np(assets.path, home.path, UInt32(RENAME_EXCL)) == 0 else {
                throw failure("Could not install into \(home.path)")
            }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw failure("\(home.path) is not a private folder owned by this user")
        }
        _ = chmod(home.path, 0o700)
        if let model { try replace(model, at: home.appendingPathComponent(manifest.modelName)) }
        if let projector { try replace(projector, at: home.appendingPathComponent(manifest.projectorName)) }
        if let runtime {
            let target = home.appendingPathComponent("runtime", isDirectory: true)
            if renamex_np(runtime.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else { throw failure("Could not install the runtime") }
                // Swap the verified runtime in atomically; the old one lands in staging and is removed with it.
                guard renamex_np(runtime.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw failure("Could not replace the runtime")
                }
            }
        }
    }

    /// Bsdtar and Finder copies propagate a browser download's quarantine flag; the bytes are already pinned by SHA-256.
    private nonisolated static func clearQuarantine(_ url: URL) {
        _ = removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
    }

    private nonisolated static func move(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else { throw failure("Could not stage \(destination.lastPathComponent)") }
    }

    private nonisolated static func replace(_ source: URL, at destination: URL) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
            throw failure("\(destination.lastPathComponent) is a folder")
        }
        // rename(2) atomically replaces a file (or a symlink itself, never its target).
        guard rename(source.path, destination.path) == 0 else { throw failure("Could not install \(destination.lastPathComponent)") }
    }
}

/// A `URLSessionConfiguration.default` download (system proxies respected) with streamed progress and cancellation.
private final class GemmaDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expected: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()
    private var moved: Error??
    private var reported: Int64 = 0

    private init(destination: URL, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.expected = expected
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, expected: Int64,
                      progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let delegate = GemmaDownload(destination: destination, expected: expected, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.lock.lock()
                delegate.continuation = continuation
                delegate.lock.unlock()
                if Task.isCancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        // Throttle main-actor hops to roughly one per MiB.
        guard totalBytesWritten - reported >= 1 << 20 || totalBytesWritten >= total else { return }
        reported = totalBytesWritten
        progress(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this callback returns, so move it now.
        var outcome: Error?
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            outcome = GemmaInstallFailure(message: "HTTP \(response.statusCode)")
        } else {
            do { try FileManager.default.moveItem(at: location, to: destination) } catch { outcome = error }
        }
        lock.lock()
        moved = .some(outcome)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let moved = self.moved
        lock.unlock()
        if let error {
            if (error as? URLError)?.code == .cancelled { continuation?.resume(throwing: CancellationError()) }
            else { continuation?.resume(throwing: error) }
        } else if case .some(.some(let failure)) = moved {
            continuation?.resume(throwing: failure)
        } else if moved == nil {
            continuation?.resume(throwing: GemmaInstallFailure(message: "Download did not finish"))
        } else {
            continuation?.resume()
        }
    }
}

/// Model status rows + one-click installer, shown at the top of the unified Semantic & Content Index card.
struct GemmaAssetSettings: View {
    @ObservedObject var launcher: Launcher
    @ObservedObject var assets: GemmaAssetManager
    let installed: (GemmaComponent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(launcher.t("文本语义模型", "Text Semantic Model"), bytes: assets.textBytes,
                ready: assets.textInstalled, component: .text, identifier: "settings.gemma.text")
            row(launcher.t("图像多模态（可选）", "Image Multimodal (Optional)"), bytes: assets.imageBytes,
                ready: assets.imageInstalled, component: .image, identifier: "settings.gemma.image")
            if assets.busy {
                HStack(spacing: 8) {
                    if case .downloading = assets.phase, let fraction = assets.fraction {
                        ProgressView(value: fraction) {
                            Text("\(ByteCountFormatter.string(fromByteCount: assets.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: assets.totalBytes, countStyle: .file))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                        Text(phaseLabel).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button(launcher.t("取消", "Cancel"), action: assets.cancel)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.gemma.cancel")
                }
            }
            HStack(spacing: 10) {
                Picker(launcher.t("下载源", "Source"), selection: $assets.mirror) {
                    ForEach(GemmaMirror.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(assets.busy)
                Spacer()
                Button(launcher.t("从本地导入…", "Import Local Files…")) {
                    assets.importLocalFiles { ok in if ok { installed(.text) } }
                }
                .controlSize(.small)
                .disabled(assets.busy || assets.manifest == nil)
                .accessibilityIdentifier("settings.gemma.import")
            }
            if assets.phase == .unrecognizedImport {
                Text(launcher.t("未识别所选文件。请同时选择模型 .gguf 与 llama 运行库压缩包。",
                                "The selected files were not recognized. Choose the model .gguf and the llama runtime archive."))
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if case .failed(let message) = assets.phase {
                Text(launcher.t("安装失败：\(message)", "Install failed: \(message)"))
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var phaseLabel: String {
        switch assets.phase {
        case .verifying: return launcher.t("正在校验 SHA-256…", "Verifying SHA-256…")
        case .installing: return launcher.t("正在安装…", "Installing…")
        default: return launcher.t("正在准备…", "Preparing…")
        }
    }

    private func row(_ title: String, bytes: Int64, ready: Bool, component: GemmaComponent, identifier: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ready ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title)
            Text("~\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if ready {
                Text(launcher.t("已安装", "Installed")).font(.callout).foregroundStyle(.secondary)
            } else {
                Button(launcher.t("下载", "Download")) {
                    assets.install(component) { ok in if ok { installed(component) } }
                }
                .controlSize(.small)
                .disabled(assets.busy || assets.manifest == nil)
                .accessibilityIdentifier(identifier)
            }
        }
    }
}
