import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The store a build uses when the engine is not handed one.
public enum PlatformSecrets {
    public static func store(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> any SecretStore {
        #if os(macOS)
        return KeychainSecretStore()
        #else
        return LinuxSecretStore(environment: environment, home: home)
        #endif
    }
}

/// Secrets in a JSON file only the user can read: the folder is 0700 and the file 0600.
/// Linux falls back to this when the Secret Service is not reachable.
public final class FileSecretStore: SecretStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `${XDG_CONFIG_HOME:-~/.config}/disklessly/secrets.json`.
    public static func defaultURL(environment: [String: String], home: String) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/.config"
        return URL(fileURLWithPath: base).appendingPathComponent("disklessly/secrets.json")
    }

    private struct Item: Codable { var service: String; var account: String; var secret: String }
    private struct File: Codable { var version = 1; var items: [Item] = [] }

    private func read() throws -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        do { return try JSONDecoder().decode(File.self, from: data) }
        catch { throw DisklesslyError.backend("secrets file \(url.path) is not readable JSON; fix or remove it") }
    }

    public func load(service: String, account: String) throws -> String? {
        try read().items.first { $0.service == service && $0.account == account }?.secret
    }

    public func save(service: String, account: String, secret: String) throws {
        var file = try read()
        file.items.removeAll { $0.service == service && $0.account == account }
        file.items.append(Item(service: service, account: account, secret: secret))
        try persist(file)
    }

    public func delete(service: String, account: String) throws {
        var file = try read()
        let before = file.items.count
        file.items.removeAll { $0.service == service && $0.account == account }
        if file.items.count != before { try persist(file) }
    }

    /// Shares are mounted by the system on Linux, so there is no mount credential to keep.
    public func saveMountCredential(kind: String, host: String, account: String, secret: String) throws {
        _ = (kind, host, account, secret)
    }

    /// The temp file is created 0600 before any secret is written to it, then renamed over the old one.
    private func persist(_ file: File) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(folder.path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        let temp = folder.appendingPathComponent(".secrets.\(getpid()).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw DisklesslyError.backend("cannot create \(temp.path) (errno \(errno))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var ok = true
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch { ok = false }
        try? handle.close()
        guard ok, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw DisklesslyError.backend("cannot write \(url.path) (errno \(errno))")
        }
    }
}

/// The freedesktop Secret Service (GNOME Keyring, KWallet) through `secret-tool`, with
/// `FileSecretStore` as the fallback. Secrets go to `secret-tool` on stdin, never in argv.
///
/// `DISKLESSLY_SECRET_STORE=file` forces the file; `secret-tool` forces the Secret
/// Service. The default uses the Secret Service only when a D-Bus session is present,
/// because without one `secret-tool` fails or waits on an unlock prompt nobody sees.
public final class LinuxSecretStore: SecretStore {
    public enum Mode: String { case auto, file, secretTool = "secret-tool" }

    public let file: FileSecretStore
    let mode: Mode
    let tool: String?
    /// Seconds before an unanswered `secret-tool` (an unlock prompt) is given up on.
    let timeout: TimeInterval

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(), timeout: TimeInterval = 15) {
        file = FileSecretStore(url: FileSecretStore.defaultURL(environment: environment, home: home))
        mode = Mode(rawValue: environment["DISKLESSLY_SECRET_STORE"] ?? "auto") ?? .auto
        self.timeout = timeout
        let candidates = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map { "\($0)/secret-tool" }
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        switch mode {
        case .file: tool = nil
        case .secretTool: tool = found
        case .auto: tool = (environment["DBUS_SESSION_BUS_ADDRESS"] ?? "").isEmpty ? nil : found
        }
    }

    /// The Secret Service first, then the file, so a secret saved before a switch is still found.
    public func load(service: String, account: String) throws -> String? {
        if let tool, case .found(let secret) = run(tool, ["lookup", "service", service, "account", account], stdin: nil) {
            return secret
        }
        if mode == .secretTool && tool == nil { throw DisklesslyError.unsupported("secret-tool is not installed; install libsecret-tools or set DISKLESSLY_SECRET_STORE=file") }
        return try file.load(service: service, account: account)
    }

    public func save(service: String, account: String, secret: String) throws {
        if let tool {
            switch run(tool, ["store", "--label=Disklessly \(account)", "service", service, "account", account], stdin: secret) {
            case .found, .missing:
                // The file copy, if any, is now stale.
                try? file.delete(service: service, account: account)
                return
            case .failed(let detail):
                if mode == .secretTool { throw DisklesslyError.backend("secret-tool store failed: \(detail)") }
                FileHandle.standardError.write(Data("disklessly: warning: Secret Service unavailable (\(detail)); saved \(account) to \(file.url.path) (mode 0600) instead.\n".utf8))
            }
        } else if mode == .secretTool {
            throw DisklesslyError.unsupported("secret-tool is not installed; install libsecret-tools or set DISKLESSLY_SECRET_STORE=file")
        }
        try file.save(service: service, account: account, secret: secret)
    }

    public func saveMountCredential(kind: String, host: String, account: String, secret: String) throws {
        _ = (kind, host, account, secret)
    }

    enum Outcome: Equatable { case found(String), missing, failed(String) }

    /// `secret-tool lookup` exits 1 with no output when nothing matches.
    func run(_ tool: String, _ arguments: [String], stdin: String?) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return .failed("\(error.localizedDescription)") }
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .failed("timed out after \(Int(timeout))s (locked keyring?)")
        }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch process.terminationStatus {
        case 0: return out.isEmpty && stdin == nil ? .missing : .found(out)
        case 1 where err.isEmpty: return .missing
        default: return .failed(err.isEmpty ? "exit \(process.terminationStatus)" : err)
        }
    }
}
