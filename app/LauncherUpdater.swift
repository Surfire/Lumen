import Combine
import CryptoKit
import Darwin
import Foundation
import Security

struct LumenRelease: Decodable {
    let version: String
    let build: String
    let url: URL
    let sha256: String
    let notes: String
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class LauncherUpdater: Sendable {
    private static let feed = URL(string: "https://github.com/Surfire/Lumen/releases/latest/download/lumen-update.json.cms")!
    private static let validation = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
    private let feed: URL
    private let session: URLSession
    private let transport: UpdateTransport
    private let bundle: URL

    init(smokeFeed: URL? = nil) {
        feed = smokeFeed ?? Self.feed
        transport = UpdateTransport(loopbackOnly: smokeFeed != nil)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config, delegate: transport, delegateQueue: nil)
        bundle = Bundle.main.bundleURL
    }

    deinit { session.finishTasksAndInvalidate() }

    func check() async throws -> LumenRelease? {
        let (_, certificate) = try runningIdentity()
        let file = try await download(feed)
        defer { try? FileManager.default.removeItem(at: file) }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let limit = 256 * 1024
        guard let cms = try input.read(upToCount: limit + 1), cms.count <= limit else {
            throw UpdateError("Invalid release manifest size.")
        }
        let release = try JSONDecoder().decode(LumenRelease.self, from: Self.signedContent(cms, certificate))
        let current = Bundle.main.infoDictionary ?? [:]
        guard let oldVersion = current["CFBundleShortVersionString"] as? String,
              let oldBuild = current["CFBundleVersion"] as? String,
              let a = UInt64(oldBuild), let b = UInt64(release.build),
              [oldVersion, release.version].allSatisfy({
                  $0.range(of: #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z"#,
                           options: .regularExpression) != nil
              }), release.sha256.range(of: #"\A[0-9a-fA-F]{64}\z"#, options: .regularExpression) != nil,
              transport.allows(release.url) else { throw UpdateError("Invalid release manifest.") }
        return b > a && release.version.compare(oldVersion, options: .numeric) != .orderedAscending ? release : nil
    }

    func install(_ release: LumenRelease, smokeFailAfterSwap: Bool = false) async throws -> URL {
        let (requirement, _) = try runningIdentity()
        let archive = try await download(release.url)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard try Self.digest(archive) == release.sha256.lowercased() else {
            throw UpdateError("The download's SHA-256 does not match the signed manifest.")
        }

        // realpath retains /private on macOS, so libarchive sees no system symlink in the staging prefix.
        guard let resolved = realpath(bundle.path, nil) else { throw Self.fileError() }
        defer { free(resolved) }
        let destination = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let parent = destination.deletingLastPathComponent()
        // Same destination lock and same-volume backup layout as install-app.py.
        let lock = open(parent.appendingPathComponent(".\(destination.lastPathComponent).install.lock").path,
                        O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw Self.fileError() }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Self.fileError() }
        var template = Array(parent.appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-backup-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw Self.fileError() }
        let work = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        var keepBackup = false
        defer { if !keepBackup { try? FileManager.default.removeItem(at: work) } }
        try Self.extractZIP(archive, into: work)
        let staged = work.appendingPathComponent("Lumen.app", isDirectory: true)
        let kind = try staged.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard kind.isDirectory == true, kind.isSymbolicLink == false else {
            throw UpdateError("The archive must contain a Lumen.app directory.")
        }
        try Self.verify(staged, requirement, release)
        try Self.swap(staged, destination)
        keepBackup = true
        do {
            try Self.verify(destination, requirement, release)
            if transport.loopbackOnly && smokeFailAfterSwap { throw UpdateError("Simulated post-swap failure.") }
        } catch {
            do { try Self.swap(staged, destination) }
            catch { throw UpdateError("Update verification and rollback failed. The previous app is at \(staged.path).") }
            keepBackup = false
            throw UpdateError("Update verification failed; the previous app was restored. \(error.localizedDescription)")
        }
        return staged
    }

    private func download(_ url: URL) async throws -> URL {
        guard transport.allows(url) else { throw UpdateError("Update URLs must use HTTPS.") }
        let (file, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, transport.allows(finalURL) else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError("The update server did not return a download.")
        }
        return file
    }

    private func runningIdentity() throws -> (SecRequirement, SecCertificate) {
        var running: SecCode?
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              let certificate = (try Self.signingInfo(code)[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else {
            throw UpdateError("In-app updates require a release-signed copy of Lumen.")
        }
        return (requirement, certificate)
    }

    private static func signedContent(_ cms: Data, _ certificate: SecCertificate) throws -> Data {
        var decoder: CMSDecoder?
        var count = 0
        var status = CMSSignerStatus.unsigned
        var signer: SecCertificate?
        var content: CFData?
        // Verify the CMS signature; the running app's leaf is the trust anchor, not a public CA lookup.
        guard !cms.isEmpty, CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
              cms.withUnsafeBytes({ CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderGetNumSigners(decoder, &count) == errSecSuccess, count == 1,
              CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, nil, nil) == errSecSuccess,
              status == .valid,
              CMSDecoderCopySignerCert(decoder, 0, &signer) == errSecSuccess, let signer,
              SecCertificateCopyData(signer) as Data == SecCertificateCopyData(certificate) as Data,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else {
            throw UpdateError("The release manifest's signature does not match this installation.")
        }
        return content as Data
    }

    private static func signingInfo(_ code: SecStaticCode) throws -> [String: Any] {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { throw UpdateError("Cannot read the app's signing information.") }
        return values
    }

    private static func verify(_ url: URL, _ requirement: SecRequirement, _ release: LumenRelease) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, validation, requirement) == errSecSuccess else {
            throw UpdateError("The update app's signature does not satisfy this installation's signing requirement.")
        }
        let info = try signingInfo(code)[kSecCodeInfoPList as String] as? [String: Any]
        guard info?["CFBundleShortVersionString"] as? String == release.version,
              info?["CFBundleVersion"] as? String == release.build else {
            throw UpdateError("The signed app version does not match the manifest.")
        }
    }

    private static func digest(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1 << 20), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extractZIP(_ file: URL, into work: URL) throws {
        guard let archive = archive_read_new() else { throw UpdateError("Could not open the ZIP reader.") }
        defer { _ = archive_read_free(archive) }
        func failure() -> UpdateError {
            let detail = archive_error_string(archive).map { String(cString: $0) } ?? "Unexpected ZIP entry."
            return UpdateError("Could not extract the Lumen.app ZIP archive: \(detail)")
        }
        guard archive_read_support_format_zip(archive) == ARCHIVE_OK,
              archive_read_open_filename(archive, file.path, 64 * 1024) == ARCHIVE_OK else { throw failure() }
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry, let raw = archive_entry_pathname(entry),
                  let path = String(validatingUTF8: raw), path == "Lumen.app" || path.hasPrefix("Lumen.app/") else { throw failure() }
            archive_entry_set_pathname(entry, work.path + "/" + path)
            guard archive_read_extract(archive, entry, ARCHIVE_EXTRACT_NO_OVERWRITE | ARCHIVE_EXTRACT_SECURE_SYMLINKS |
                                       ARCHIVE_EXTRACT_SECURE_NODOTDOT) == ARCHIVE_OK else { throw failure() }
        }
    }

    private static func swap(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else { throw fileError() }
    }

    private static func fileError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

final class UpdateTransport: NSObject, URLSessionTaskDelegate {
    let loopbackOnly: Bool
    init(loopbackOnly: Bool) { self.loopbackOnly = loopbackOnly }

    func allows(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        let scheme = url.scheme?.lowercased()
        if loopbackOnly { return ["127.0.0.1", "localhost"].contains(host) && ["http", "https"].contains(scheme) }
        return scheme == "https"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(allows) == true ? request : nil)
    }
}

@MainActor
final class UpdateSettings: ObservableObject {
    @Published private(set) var release: LumenRelease?
    @Published private(set) var busy = false
    @Published private(set) var checked = false
    @Published private(set) var error: String?
    @Published private(set) var backup: URL?
    private let updater = LauncherUpdater()

    func check() {
        run {
            self.release = nil
            self.checked = false
            self.release = try await self.updater.check()
            self.checked = true
        }
    }

    func install() {
        guard let release else { return }
        run { self.backup = try await self.updater.install(release) }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy, backup == nil else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { self.error = error.localizedDescription }
        }
    }
}
