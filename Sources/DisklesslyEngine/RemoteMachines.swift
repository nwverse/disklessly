import Foundation
import DisklesslyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Injectable SSH transport so unit and E2E tests can run against a fake SSH script or closure.
public struct SSHTransport: @unchecked Sendable {
    public var run: (String, String, Data?, TimeInterval) throws -> Data
    public var runWithStdinFile: (String, String, URL, TimeInterval) throws -> Data
    public var streamOut: (String, String, Data?, (Data) throws -> Void, TimeInterval) throws -> Void

    public init(
        run: @escaping (String, String, Data?, TimeInterval) throws -> Data,
        runWithStdinFile: @escaping (String, String, URL, TimeInterval) throws -> Data,
        streamOut: @escaping (String, String, Data?, (Data) throws -> Void, TimeInterval) throws -> Void
    ) {
        self.run = run
        self.runWithStdinFile = runWithStdinFile
        self.streamOut = streamOut
    }

    public static func live(sshExecutable: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> SSHTransport {
        let exe = sshExecutable ?? environment["DISKLESSLY_SSH"] ?? resolveSSHExecutable(environment: environment)
        return SSHTransport(
            run: { host, remoteCommand, stdinData, timeout in
                var collected = Data()
                try executeSSH(executable: exe, environment: environment, host: host, remoteCommand: remoteCommand, stdinData: stdinData, stdinFile: nil, timeout: timeout) { chunk in
                    collected.append(chunk)
                }
                return collected
            },
            runWithStdinFile: { host, remoteCommand, stdinURL, timeout in
                var collected = Data()
                try executeSSH(executable: exe, environment: environment, host: host, remoteCommand: remoteCommand, stdinData: nil, stdinFile: stdinURL, timeout: timeout) { chunk in
                    collected.append(chunk)
                }
                return collected
            },
            streamOut: { host, remoteCommand, stdinData, onChunk, timeout in
                try executeSSH(executable: exe, environment: environment, host: host, remoteCommand: remoteCommand, stdinData: stdinData, stdinFile: nil, timeout: timeout, onStdoutChunk: onChunk)
            }
        )
    }

    private static func resolveSSHExecutable(environment: [String: String]) -> String {
        for candidate in ["/usr/bin/ssh", "/bin/ssh", "/usr/local/bin/ssh", "/opt/homebrew/bin/ssh"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let path = environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/ssh"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return "/usr/bin/ssh"
    }

    /// True when `host` names this machine (loopback alias, local hostname, or a hostname resolving to one of this machine's network interface addresses).
    public static func isSelfHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower == "[::1]" {
            return true
        }
        let localHost = ProcessInfo.processInfo.hostName.lowercased()
        if !localHost.isEmpty {
            if lower == localHost { return true }
            if let short = localHost.split(separator: ".").first, lower == String(short) {
                return true
            }
        }
        let localIPs = localInterfaceAddresses()
        guard !localIPs.isEmpty else { return false }
        if localIPs.contains(lower) { return true }
        let resolved = resolveHostAddresses(lower)
        return !resolved.isEmpty && !localIPs.isDisjoint(with: resolved)
    }

    private static func localInterfaceAddresses() -> Set<String> {
        var result: Set<String> = ["127.0.0.1", "::1"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            if let sa = cur.pointee.ifa_addr {
                let family = Int32(sa.pointee.sa_family)
                if family == AF_INET || family == AF_INET6 {
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let len = family == AF_INET ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
                    if getnameinfo(sa, len, &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: hostBuf).split(separator: "%").first.map(String.init)?.lowercased() ?? ""
                        if !s.isEmpty { result.insert(s) }
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return result
    }

    private static func resolveHostAddresses(_ host: String) -> Set<String> {
        var result = Set<String>()
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &res) == 0, let first = res else { return result }
        defer { freeaddrinfo(first) }
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let cur = ptr {
            if let sa = cur.pointee.ai_addr {
                let family = cur.pointee.ai_family
                if family == AF_INET || family == AF_INET6 {
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, cur.pointee.ai_addrlen, &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: hostBuf).split(separator: "%").first.map(String.init)?.lowercased() ?? ""
                        if !s.isEmpty { result.insert(s) }
                    }
                }
            }
            ptr = cur.pointee.ai_next
        }
        return result
    }

    private static func executeSSH(
        executable: String,
        environment: [String: String],
        host: String,
        remoteCommand: String,
        stdinData: Data?,
        stdinFile: URL?,
        timeout: TimeInterval,
        onStdoutChunk: (Data) throws -> Void
    ) throws {
        guard SSHConfigParser.isConcreteHost(host) else {
            throw DisklesslyError.usage("invalid SSH host alias: \(host)")
        }

        // Ignore SIGPIPE so an early remote exit while writing to stdin does not kill our process.
        _ = signal(SIGPIPE, SIG_IGN)

        let useDirectLocalSh = (executable == "/usr/bin/ssh" || executable == "/bin/ssh" || executable.hasSuffix("/bin/ssh")) && isSelfHost(host)
        let process = Process()
        if useDirectLocalSh {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", remoteCommand]
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = SSHCommand.arguments(host: host, remoteCommand: remoteCommand)
        }
        process.environment = ParsedCommand.environment(inheriting: environment)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        let fileStdinHandle: FileHandle?
        if let stdinFile {
            let fh = try FileHandle(forReadingFrom: stdinFile)
            process.standardInput = fh
            fileStdinHandle = fh
            inPipe = nil
        } else if stdinData != nil {
            let p = Pipe()
            process.standardInput = p
            inPipe = p
            fileStdinHandle = nil
        } else {
            process.standardInput = FileHandle.nullDevice
            inPipe = nil
            fileStdinHandle = nil
        }
        defer { try? fileStdinHandle?.close() }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            throw DisklesslyError.failure("ssh could not start (\(executable)): \(error.localizedDescription)")
        }

        // Schedule a watchdog timer BEFORE the stdout read loop so a hung remote command cannot block forever.
        let timedOutFlag = FlagBox()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOutFlag.set(true)
                process.terminate()
                try? outPipe.fileHandleForReading.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        if let inPipe, let stdinData {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdinData)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let errBox = DataBox()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global().async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errBox.set(data)
            errGroup.leave()
        }

        let streamErrBox = ErrorBox()
        let handle = outPipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            do {
                try onStdoutChunk(chunk)
            } catch {
                streamErrBox.set(error)
                process.terminate()
                break
            }
        }

        if done.wait(timeout: .now() + max(1, timeout)) == .timedOut || timedOutFlag.get() {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            _ = errGroup.wait(timeout: .now() + 2)
            throw DisklesslyError.backend("ssh to \(host) timed out after \(Int(timeout)) s")
        }

        _ = errGroup.wait(timeout: .now() + 2)

        if let streamError = streamErrBox.get() { throw streamError }
        guard process.terminationStatus == 0 else {
            let reason = SSHCommand.lastErrorLine(errBox.get())
            throw DisklesslyError.backend("ssh \(host) failed (exit \(process.terminationStatus)): \(reason)")
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var err: Error?
    func set(_ value: Error) { lock.lock(); err = value; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return err }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Persisted list of managed SSH machines in `<stateDir>/machines/config.json`.
public struct ManagedMachinesConfig: Codable, Equatable, Sendable {
    public struct HostConfig: Codable, Equatable, Sendable {
        public var host: String
        public var displayName: String?
        public var enabled: Bool
        public var addedManually: Bool
        public var rcloneRemote: String? // Optional Mode B direct upload target

        public init(host: String, displayName: String? = nil, enabled: Bool = true, addedManually: Bool = false, rcloneRemote: String? = nil) {
            self.host = host
            self.displayName = displayName
            self.enabled = enabled
            self.addedManually = addedManually
            self.rcloneRemote = rcloneRemote
        }
    }

    public var schema: String = "machines-config/1"
    public var hosts: [HostConfig]

    public init(hosts: [HostConfig] = []) {
        self.hosts = hosts
    }
}

/// Persisted status of the last SSH attempt for a host (`<stateDir>/machines/status/<host>.json`).
public struct RemoteHostAttemptStatus: Codable, Equatable, Sendable {
    public var host: String
    public var reachable: Bool
    public var attemptedAt: Date
    public var lastError: String?

    public init(host: String, reachable: Bool, attemptedAt: Date = Date(), lastError: String? = nil) {
        self.host = host
        self.reachable = reachable
        self.attemptedAt = attemptedAt
        self.lastError = lastError
    }
}

/// Local store for managed SSH hosts, cached scan reports, attempt status, and local transaction journal mirrors.
public enum RemoteMachineStore {
    public static func machinesDir(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("machines", isDirectory: true)
    }

    public static func configURL(stateDir: String) -> URL {
        machinesDir(stateDir: stateDir).appendingPathComponent("config.json")
    }

    public static func scanCacheURL(stateDir: String, host: String) -> URL {
        machinesDir(stateDir: stateDir)
            .appendingPathComponent("scans", isDirectory: true)
            .appendingPathComponent("\(SSHCommand.sanitizeHost(host)).json")
    }

    public static func attemptStatusURL(stateDir: String, host: String) -> URL {
        machinesDir(stateDir: stateDir)
            .appendingPathComponent("status", isDirectory: true)
            .appendingPathComponent("\(SSHCommand.sanitizeHost(host)).json")
    }

    public static func journalDir(stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("remote-journals", isDirectory: true)
    }

    public static func journalURL(stateDir: String, txid: String) -> URL {
        let safeTxid = RemoteJournal.isValidTxid(txid) ? txid : SSHCommand.sanitizeHost(txid)
        return journalDir(stateDir: stateDir).appendingPathComponent("\(safeTxid).json")
    }

    public static func loadConfig(stateDir: String) -> ManagedMachinesConfig {
        let url = configURL(stateDir: stateDir)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ManagedMachinesConfig.self, from: data) else {
            return ManagedMachinesConfig()
        }
        return decoded
    }

    public static func saveConfig(_ config: ManagedMachinesConfig, stateDir: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(config)
        try AtomicFile.write(data, to: configURL(stateDir: stateDir))
    }

    public static func loadCachedScan(stateDir: String, host: String) -> RemoteScanReport? {
        let url = scanCacheURL(stateDir: stateDir, host: host)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RemoteScanReport.self, from: data)
    }

    public static func saveCachedScan(_ report: RemoteScanReport, stateDir: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(report)
        try AtomicFile.write(data, to: scanCacheURL(stateDir: stateDir, host: report.host))
    }

    public static func loadAttemptStatus(stateDir: String, host: String) -> RemoteHostAttemptStatus? {
        let url = attemptStatusURL(stateDir: stateDir, host: host)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RemoteHostAttemptStatus.self, from: data)
    }

    public static func saveAttemptStatus(_ status: RemoteHostAttemptStatus, stateDir: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(status) {
            try? AtomicFile.write(data, to: attemptStatusURL(stateDir: stateDir, host: status.host))
        }
    }

    public static func saveJournal(_ journal: RemoteJournal, stateDir: String) throws {
        guard RemoteJournal.isValidTxid(journal.txid) else {
            throw DisklesslyError.usage("invalid remote journal txid: \(journal.txid)")
        }
        let data = try journal.encode()
        try AtomicFile.write(data, to: journalURL(stateDir: stateDir, txid: journal.txid))
    }

    public static func loadJournals(stateDir: String, host: String? = nil) -> [RemoteJournal] {
        let dir = journalDir(stateDir: stateDir)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [RemoteJournal] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let journal = try? RemoteJournal.decode(data),
               RemoteJournal.isValidTxid(journal.txid) {
                if host == nil || journal.host == host {
                    out.append(journal)
                }
            }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }
}

extension DisklesslyEngine {
    public var sshTransport: SSHTransport {
        sshTransportOverride ?? .live()
    }

    private func validateSSHHost(_ host: String) throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHConfigParser.isConcreteHost(trimmed) else {
            throw DisklesslyError.usage("invalid SSH host alias: \(host)")
        }
        return trimmed
    }

    // MARK: - Discovery & SSH Config

    /// Reads `~/.ssh/config` (or `<homeDirectory>/.ssh/config`) and returns concrete Host entries.
    public func sshConfigHosts() -> [SSHHostEntry] {
        let sshConfigURL = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: sshConfigURL, encoding: .utf8) else { return [] }
        return SSHConfigParser.parse(text)
    }

    /// Combines managed hosts with `~/.ssh/config` discoveries.
    public func managedSSHHosts() -> [ManagedMachinesConfig.HostConfig] {
        let saved = RemoteMachineStore.loadConfig(stateDir: config.stateDir)
        let discovered = sshConfigHosts()
        var merged = saved.hosts
        let existingNames = Set(merged.map(\.host))
        for entry in discovered where !existingNames.contains(entry.alias) {
            merged.append(ManagedMachinesConfig.HostConfig(
                host: entry.alias,
                displayName: entry.alias,
                enabled: true,
                addedManually: false
            ))
        }
        return merged
    }

    @discardableResult
    public func addRemoteMachine(host: String, displayName: String? = nil, rcloneRemote: String? = nil) throws -> ManagedMachinesConfig.HostConfig {
        let trimmed = try validateSSHHost(host)
        var saved = RemoteMachineStore.loadConfig(stateDir: config.stateDir)
        if let idx = saved.hosts.firstIndex(where: { $0.host == trimmed }) {
            saved.hosts[idx].enabled = true
            if let displayName, !displayName.isEmpty { saved.hosts[idx].displayName = displayName }
            if let rcloneRemote, !rcloneRemote.isEmpty { saved.hosts[idx].rcloneRemote = rcloneRemote }
            try RemoteMachineStore.saveConfig(saved, stateDir: config.stateDir)
            return saved.hosts[idx]
        }
        let entry = ManagedMachinesConfig.HostConfig(
            host: trimmed,
            displayName: (displayName?.isEmpty == false) ? displayName : trimmed,
            enabled: true,
            addedManually: true,
            rcloneRemote: (rcloneRemote?.isEmpty == false) ? rcloneRemote : nil
        )
        saved.hosts.append(entry)
        try RemoteMachineStore.saveConfig(saved, stateDir: config.stateDir)
        return entry
    }

    public func removeRemoteMachine(host: String) throws {
        let trimmed = try validateSSHHost(host)
        var saved = RemoteMachineStore.loadConfig(stateDir: config.stateDir)
        let discoveredAliases = Set(sshConfigHosts().map(\.alias))
        if discoveredAliases.contains(trimmed) {
            if let idx = saved.hosts.firstIndex(where: { $0.host == trimmed }) {
                saved.hosts[idx].enabled = false
            } else {
                saved.hosts.append(ManagedMachinesConfig.HostConfig(host: trimmed, enabled: false, addedManually: false))
            }
        } else {
            saved.hosts.removeAll { $0.host == trimmed }
        }
        try RemoteMachineStore.saveConfig(saved, stateDir: config.stateDir)
    }

    // MARK: - Binary deployment & version check (#46 §1)

    /// Checks remote platform (`uname -sm`) and streams matching `disklessly-<os>-<arch>` gzipped to `~/.disklessly/bin/disklessly`.
    public func deployRemoteBinary(host: String, binarySearchDir: URL? = nil, force: Bool = false, timeout: TimeInterval = 60) throws -> [String: Any] {
        let validHost = try validateSSHHost(host)
        let probeCmd = "uname -sm; if [ -x \"$HOME/.disklessly/bin/disklessly\" ]; then \"$HOME/.disklessly/bin/disklessly\" version 2>/dev/null || true; fi"
        let probeData = try sshTransport.run(validHost, probeCmd, nil, 15)
        let probeLines = String(decoding: probeData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unameStr = probeLines.first ?? ""
        guard let platform = RemotePlatform.parse(unameSM: unameStr) else {
            throw DisklesslyError.failure("could not parse remote uname -sm: \(unameStr)")
        }

        if !force, probeLines.count >= 2 {
            let verLine = probeLines[1]
            if verLine.contains("disklessly \(EngineInstall.version)") {
                return [
                    "ok": true,
                    "host": validHost,
                    "platform": "\(platform.os)-\(platform.arch)",
                    "artifact": platform.binaryArtifactName,
                    "remotePath": "~/.disklessly/bin/disklessly",
                    "version": verLine,
                    "upToDate": true,
                ]
            }
        }

        let artifactName = platform.binaryArtifactName
        let candidateURL = resolveLocalRemoteBinary(artifactName: artifactName, platform: platform, searchDir: binarySearchDir)
        guard let binaryURL = candidateURL, FileManager.default.isReadableFile(atPath: binaryURL.path) else {
            throw DisklesslyError.unsupported("no local binary found for \(artifactName); remote scan will use the optimized single-trip shell fallback")
        }

        let rawBinary = try Data(contentsOf: binaryURL)
        let gzipped = try gzipCompress(rawBinary)
        let installCmd = "mkdir -p \"$HOME/.disklessly/bin\" && gzip -dc > \"$HOME/.disklessly/bin/disklessly.new\" && chmod 755 \"$HOME/.disklessly/bin/disklessly.new\" && mv \"$HOME/.disklessly/bin/disklessly.new\" \"$HOME/.disklessly/bin/disklessly\" && \"$HOME/.disklessly/bin/disklessly\" version"
        let outData = try sshTransport.run(validHost, installCmd, gzipped, timeout)
        let versionLine = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "ok": true,
            "host": validHost,
            "platform": "\(platform.os)-\(platform.arch)",
            "artifact": artifactName,
            "remotePath": "~/.disklessly/bin/disklessly",
            "version": versionLine,
            "upToDate": false,
        ]
    }

    private func resolveLocalRemoteBinary(artifactName: String, platform: RemotePlatform, searchDir: URL?) -> URL? {
        let fm = FileManager.default
        if let searchDir {
            let direct = searchDir.appendingPathComponent(artifactName)
            if fm.isReadableFile(atPath: direct.path) { return direct }
        }
        if let envDir = ProcessInfo.processInfo.environment["DISKLESSLY_REMOTE_BIN_DIR"], !envDir.isEmpty {
            let candidate = URL(fileURLWithPath: envDir).appendingPathComponent(artifactName)
            if fm.isReadableFile(atPath: candidate.path) { return candidate }
        }
        let selfExe = EngineInstall.runningExecutable()
        let sibling = selfExe.deletingLastPathComponent().appendingPathComponent(artifactName)
        if fm.isReadableFile(atPath: sibling.path) { return sibling }
        let localOS = HostPlatform.current == .macOS ? "darwin" : "linux"
        if platform.os == localOS && platform.arch == EngineInstall.arch && fm.isReadableFile(atPath: selfExe.path) {
            return selfExe
        }
        return nil
    }

    private func gzipCompress(_ data: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        if !FileManager.default.isExecutableFile(atPath: "/usr/bin/gzip"),
           FileManager.default.isExecutableFile(atPath: "/bin/gzip") {
            process.executableURL = URL(fileURLWithPath: "/bin/gzip")
        }
        process.arguments = ["-c"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
            try? inPipe.fileHandleForWriting.close()
        }
        let compressed = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DisklesslyError.failure("gzip compression failed")
        }
        return compressed
    }

    // MARK: - Remote Scan (#46 §2)

    /// Runs the single-trip combined SSH probe on `host`, caches the result locally, and returns the report.
    /// The default timeout leaves room for `du` over large homes and `docker system df` on busy hosts.
    public func scanRemoteMachine(host: String, now: Date = Date(), timeout: TimeInterval = 150) throws -> RemoteScanReport {
        let validHost = try validateSSHHost(host)
        let scriptData = Data(RemoteScanProbe.combinedScript.utf8)
        do {
            let stdout = try sshTransport.run(validHost, "sh -s", scriptData, timeout)
            let output = String(decoding: stdout, as: UTF8.self)
            let report = RemoteScanProbe.parse(host: validHost, output: output, now: now)
            try? RemoteMachineStore.saveCachedScan(report, stateDir: config.stateDir)
            RemoteMachineStore.saveAttemptStatus(RemoteHostAttemptStatus(host: validHost, reachable: true, attemptedAt: now), stateDir: config.stateDir)
            return report
        } catch {
            RemoteMachineStore.saveAttemptStatus(
                RemoteHostAttemptStatus(host: validHost, reachable: false, attemptedAt: now, lastError: error.localizedDescription),
                stateDir: config.stateDir
            )
            throw error
        }
    }

    // MARK: - Machines Summary & Pure Ordering (#46 §4)

    /// Returns the sorted machine cards (this machine + enabled SSH machines).
    public func machinesSummary(now: Date = Date()) -> [MachineCardSummary] {
        var cards: [MachineCardSummary] = []

        // 1. Local machine card ("This Mac" / local host)
        let localHome = homeDirectory
        let volValues = try? URL(fileURLWithPath: localHome).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let localTotal = UInt64(volValues?.volumeTotalCapacity ?? 0)
        let localAvail = (try? VolumeSpace.availableBytes(at: localHome)) ?? UInt64(volValues?.volumeAvailableCapacity ?? 0)
        let localUsed = localTotal >= localAvail ? localTotal - localAvail : 0
        let localFacts = deviceFactsOverride ?? LiveDeviceFacts.current()
        let localLevel = MachineHealthLevel.evaluate(reachable: true, totalBytes: localTotal, availableBytes: localAvail)
        var localCached: RemoteScanReport?
        let scansDir = RemoteMachineStore.machinesDir(stateDir: config.stateDir).appendingPathComponent("scans", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: scansDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                let alias = file.deletingPathExtension().lastPathComponent
                if SSHTransport.isSelfHost(alias), let hit = RemoteMachineStore.loadCachedScan(stateDir: config.stateDir, host: alias) {
                    if localCached == nil || hit.scannedAt > localCached!.scannedAt {
                        localCached = hit
                    }
                }
            }
        }
        cards.append(MachineCardSummary(
            id: "local",
            host: "localhost",
            displayName: localFacts.hostname.isEmpty ? "This Machine" : localFacts.hostname,
            isLocal: true,
            configuredOrder: -1,
            reachable: true,
            level: localLevel,
            platform: "\(HostPlatform.current.rawValue)-\(EngineInstall.arch)",
            binaryVersion: EngineInstall.version,
            scanMode: "local",
            totalBytes: localTotal,
            usedBytes: localUsed,
            availableBytes: localAvail,
            reclaimableBytes: localCached?.reclaimableBytes ?? 0,
            offloadableBytes: localCached?.offloadableBytes ?? 0,
            offloadedCount: (try? list().count) ?? 0,
            lastScannedAt: localCached?.scannedAt ?? now
        ))

        // 2. Configured remote SSH machines
        let hosts = managedSSHHosts().filter(\.enabled)
        for (idx, entry) in hosts.enumerated() {
            let cached = RemoteMachineStore.loadCachedScan(stateDir: config.stateDir, host: entry.host)
            let attempt = RemoteMachineStore.loadAttemptStatus(stateDir: config.stateDir, host: entry.host)
            let offloaded = (try? listRemoteOffloaded(host: entry.host)) ?? []
            let isReachable: Bool
            if let attempt {
                if let cached, cached.scannedAt > attempt.attemptedAt {
                    isReachable = true
                } else {
                    isReachable = attempt.reachable
                }
            } else {
                isReachable = true
            }

            if let cached {
                let primary = cached.primaryMount
                let total = primary?.totalBytes ?? 0
                let avail = primary?.availableBytes ?? 0
                let used = primary?.usedBytes ?? 0
                let level = MachineHealthLevel.evaluate(reachable: isReachable, totalBytes: total, availableBytes: avail)
                let plat = cached.platform.map { "\($0.os)-\($0.arch)" }
                cards.append(MachineCardSummary(
                    id: entry.host,
                    host: entry.host,
                    displayName: entry.displayName ?? entry.host,
                    isLocal: false,
                    configuredOrder: idx,
                    reachable: isReachable,
                    level: level,
                    platform: plat,
                    binaryVersion: cached.binaryVersion,
                    scanMode: cached.scanMode,
                    totalBytes: total,
                    usedBytes: used,
                    availableBytes: avail,
                    reclaimableBytes: cached.reclaimableBytes,
                    offloadableBytes: cached.offloadableBytes,
                    offloadedCount: offloaded.count,
                    lastScannedAt: cached.scannedAt,
                    lastError: isReachable ? nil : attempt?.lastError
                ))
            } else {
                cards.append(MachineCardSummary(
                    id: entry.host,
                    host: entry.host,
                    displayName: entry.displayName ?? entry.host,
                    isLocal: false,
                    configuredOrder: idx,
                    reachable: isReachable,
                    level: isReachable ? .ok : .offline,
                    platform: nil,
                    binaryVersion: nil,
                    scanMode: nil,
                    totalBytes: 0,
                    usedBytes: 0,
                    availableBytes: 0,
                    reclaimableBytes: 0,
                    offloadableBytes: 0,
                    offloadedCount: offloaded.count,
                    lastScannedAt: nil,
                    lastError: isReachable ? nil : attempt?.lastError
                ))
            }
        }

        return MachineOrdering.sort(cards)
    }

    // MARK: - Plan (dry-run), Clean, Offload & Restore (#46 §3)

    private static func allowedContainerRuntime(_ path: String) -> (runtime: String, ref: String)? {
        if path.hasPrefix("docker://") {
            let ref = String(path.dropFirst("docker://".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return ref.isEmpty ? nil : ("docker", ref)
        }
        if path.hasPrefix("podman://") {
            let ref = String(path.dropFirst("podman://".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return ref.isEmpty ? nil : ("podman", ref)
        }
        return nil
    }

    /// Creates a dry-run plan for cleaning, offloading, or restoring items on `host`.
    public func planRemoteAction(
        host: String,
        action: String,
        targets: [String],
        mode: String = "relay"
    ) throws -> RemoteActionPlan {
        let validHost = try validateSSHHost(host)
        guard !targets.isEmpty else {
            throw DisklesslyError.usage("remote \(action) requires at least one item id or path")
        }
        let cached = try RemoteMachineStore.loadCachedScan(stateDir: config.stateDir, host: validHost) ?? scanRemoteMachine(host: validHost)
        let remoteHome = cached.remoteHome
        var planItems: [RemoteActionPlan.PlanItem] = []

        if action == "restore" {
            let offloaded = try listRemoteOffloaded(host: validHost)
            for target in targets {
                let canonTarget = RemotePathPolicy.canonicalize(target)
                guard let rec = offloaded.first(where: { $0.id == target || $0.originalPath == target || $0.originalPath == canonTarget }) else {
                    throw DisklesslyError.usage("no offloaded record matching '\(target)' for host \(validHost)")
                }
                planItems.append(RemoteActionPlan.PlanItem(
                    id: rec.id,
                    path: rec.originalPath,
                    title: rec.title,
                    kind: rec.kind,
                    bytes: rec.logicalBytes,
                    action: "restore",
                    recoverable: true,
                    repoObject: rec.repoObject
                ))
            }
            return RemoteActionPlan(host: validHost, action: "restore", mode: mode, dryRun: true, items: planItems)
        }

        for target in targets {
            let canonTarget = RemotePathPolicy.canonicalize(target)
            if let matched = cached.items.first(where: { $0.id == target || $0.path == target || $0.path == canonTarget }) {
                if matched.inUse {
                    throw DisklesslyError.busy("\(matched.title) is currently in use on \(validHost)")
                }
                if action == "clean" && matched.action != .clean {
                    throw DisklesslyError.usage("\(matched.title) is an offload target, not a rebuildable cache; use offload instead of clean")
                }
                if let why = RemotePathPolicy.refusal(for: matched.path, remoteHome: remoteHome) {
                    throw DisklesslyError.usage(why)
                }
                let itemKind: String
                if matched.category == "container-image" { itemKind = "container-image" }
                else if matched.category == "large-file" { itemKind = "file" }
                else if matched.action == .clean { itemKind = "cache" }
                else { itemKind = "folder" }
                planItems.append(RemoteActionPlan.PlanItem(
                    id: matched.id,
                    path: matched.path,
                    title: matched.title,
                    kind: itemKind,
                    bytes: matched.bytes,
                    action: action,
                    recoverable: action == "offload"
                ))
            } else {
                // Direct path specified by user
                if let why = RemotePathPolicy.refusal(for: target, remoteHome: remoteHome) {
                    throw DisklesslyError.usage(why)
                }
                if action == "clean" {
                    // Only allow direct clean on paths inside a cache or log directory
                    let isCacheOrLog = canonTarget.contains("/.cache/") || canonTarget.contains("/Caches/") || canonTarget.hasPrefix("/var/cache/") || canonTarget.hasPrefix("/var/log/")
                    if !isCacheOrLog {
                        throw DisklesslyError.usage("refusing direct clean of non-cache path \(canonTarget); use offload to preserve data in the repo")
                    }
                }
                if let ctr = Self.allowedContainerRuntime(canonTarget) {
                    let name = ctr.ref
                    planItems.append(RemoteActionPlan.PlanItem(
                        id: "image-\(ctr.runtime)-\(SSHCommand.sanitizeHost(name))",
                        path: canonTarget,
                        title: "\(ctr.runtime): \(name)",
                        kind: "container-image",
                        bytes: 1024,
                        action: action,
                        recoverable: action == "offload"
                    ))
                    continue
                }
                let q = SSHCommand.shellQuote(canonTarget)
                let probeCmd = "if [ -d \(q) ]; then k=folder; elif [ -f \(q) ]; then k=file; else exit 1; fi; kb=$(du -xsk \(q) 2>/dev/null | awk '{print $1}' | head -n 1); printf '%s %s\\n' \"$k\" \"$kb\""
                let sizeOut = try sshTransport.run(validHost, probeCmd, nil, 20)
                let parts = String(decoding: sizeOut, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                guard parts.count >= 2, let kb = UInt64(parts[1]) else {
                    throw DisklesslyError.usage("remote path not found or unreadable on \(validHost): \(canonTarget)")
                }
                let itemKind = String(parts[0])
                let name = (canonTarget as NSString).lastPathComponent
                let shortSha = String(SHA256Digest.hex(Data(canonTarget.utf8)).prefix(8))
                planItems.append(RemoteActionPlan.PlanItem(
                    id: "custom-\(SSHCommand.sanitizeHost(name))-\(shortSha)",
                    path: canonTarget,
                    title: name,
                    kind: itemKind,
                    bytes: max(1, kb) * 1024,
                    action: action,
                    recoverable: action == "offload"
                ))
            }
        }

        return RemoteActionPlan(host: validHost, action: action, mode: mode, dryRun: true, items: planItems)
    }

    /// Executes a remote cleanup (or returns the dry-run plan when `dryRun == true`).
    public func cleanRemoteMachine(
        host: String,
        targets: [String],
        dryRun: Bool = false
    ) throws -> [String: Any] {
        let validHost = try validateSSHHost(host)
        let plan = try planRemoteAction(host: validHost, action: "clean", targets: targets, mode: "clean")
        if dryRun { return plan.jsonObject() }

        let cached = RemoteMachineStore.loadCachedScan(stateDir: config.stateDir, host: validHost)
        var cleaned: [[String: Any]] = []
        var freedBytes: UInt64 = 0

        for item in plan.items {
            if let why = RemotePathPolicy.refusal(for: item.path, remoteHome: cached?.remoteHome) {
                throw DisklesslyError.usage(why)
            }
            var journal = RemoteJournal(
                host: validHost,
                action: "clean",
                mode: "clean",
                targetPath: item.path,
                bytes: item.bytes,
                phase: .planned
            )
            try persistRemoteJournal(journal)

            let cmd = RemoteCleanCommand.script(id: item.id, path: item.path)
            let out = try sshTransport.run(validHost, cmd, nil, 600)
            let outcome = RemoteCleanCommand.parse(String(decoding: out, as: UTF8.self))
            // Report what the filesystem actually gained, not the scanned size: hard-linked stores
            // (pnpm), skipped in-use children and rotated-only log cleanup free less than `du` says.
            let measured = outcome.freedBytes ?? item.bytes

            journal.phase = .completed
            journal.updatedAt = Date()
            journal.note = outcome.busy.isEmpty ? nil : "skipped \(outcome.busy.count) in-use entr\(outcome.busy.count == 1 ? "y" : "ies")"
            try persistRemoteJournal(journal)

            freedBytes += measured
            var obj = item.jsonObject()
            obj["scannedBytes"] = NSNumber(value: item.bytes)
            obj["freedBytes"] = NSNumber(value: measured)
            obj["skippedInUse"] = outcome.busy
            obj["exitCode"] = Int(outcome.exitCode)
            cleaned.append(obj)
        }

        _ = try? scanRemoteMachine(host: validHost)

        return [
            "ok": true,
            "host": validHost,
            "action": "clean",
            "dryRun": false,
            "freedBytes": NSNumber(value: freedBytes),
            "items": cleaned,
        ]
    }

    /// Offloads a remote directory, file, or container image to the repository under `machines/<host>/...`.
    /// Supports Mode A (`relay`, default: streams over SSH into the Mac/local repo) and Mode B (`direct`: remote rclone).
    public func offloadRemoteItem(
        host: String,
        target: String,
        mode: String = "relay",
        rcloneRemote: String? = nil,
        dryRun: Bool = false
    ) throws -> [String: Any] {
        let validHost = try validateSSHHost(host)
        let plan = try planRemoteAction(host: validHost, action: "offload", targets: [target], mode: mode)
        if dryRun { return plan.jsonObject() }
        guard let item = plan.items.first else {
            throw DisklesslyError.usage("nothing to offload for \(target)")
        }
        let cached = RemoteMachineStore.loadCachedScan(stateDir: config.stateDir, host: validHost)
        let canonPath = RemotePathPolicy.canonicalize(item.path)
        if let why = RemotePathPolicy.refusal(for: canonPath, remoteHome: cached?.remoteHome) {
            throw DisklesslyError.usage(why)
        }

        let backend = try openPrimaryBackend()
        let safeHost = SSHCommand.sanitizeHost(validHost)
        try? backend.ensureCollection("machines")
        try? backend.ensureCollection("machines/\(safeHost)")
        try? backend.ensureCollection("machines/\(safeHost)/objects")
        try? backend.ensureCollection("machines/\(safeHost)/records")
        try? backend.ensureCollection("machines/\(safeHost)/staging")

        let containerInfo = Self.allowedContainerRuntime(canonPath)
        let isContainer = containerInfo != nil
        let kind: String = isContainer ? "container-image" : (item.kind == "file" ? "file" : "folder")
        let txid = UUID().uuidString.lowercased()
        let stubPath = isContainer ? nil : "\(canonPath).disklessly-remote"
        let asidePath = isContainer ? nil : "\((canonPath as NSString).deletingLastPathComponent)/.\((canonPath as NSString).lastPathComponent).disklessly-removing-\(txid)"

        var journal = RemoteJournal(
            txid: txid,
            host: validHost,
            action: "offload",
            mode: mode,
            targetPath: canonPath,
            asidePath: asidePath,
            stubPath: stubPath,
            bytes: item.bytes,
            phase: .planned
        )
        try persistRemoteJournal(journal)

        // Build remote stream producer command that propagates producer failure even across POSIX pipes
        let streamCmd: String
        if let ctr = containerInfo {
            let rcFile = "/tmp/disklessly-rc-\(txid)"
            let qRc = SSHCommand.shellQuote(rcFile)
            streamCmd = "{ \(ctr.runtime) save \(SSHCommand.shellQuote(ctr.ref)); echo $? > \(qRc); } | gzip -c; rc=$(cat \(qRc) 2>/dev/null || echo 1); rm -f \(qRc); [ \"$rc\" = 0 ]"
        } else {
            let parent = (canonPath as NSString).deletingLastPathComponent
            let name = (canonPath as NSString).lastPathComponent
            let qPath = SSHCommand.shellQuote(canonPath)
            let qParent = SSHCommand.shellQuote(parent)
            let qName = SSHCommand.shellQuote(name)
            let rcFile = "/tmp/disklessly-rc-\(txid)"
            let qRc = SSHCommand.shellQuote(rcFile)
            streamCmd = "test -e \(qPath) && { { tar -C \(qParent) -cf - \(qName); echo $? > \(qRc); } | gzip -c; rc=$(cat \(qRc) 2>/dev/null || echo 1); rm -f \(qRc); [ \"$rc\" = 0 ]; }"
        }

        let sha256: String
        let storedBytes: UInt64
        let repoObject: String
        var usedRcloneRemote: String? = nil

        if mode == "direct" {
            let configuredRemote = rcloneRemote ?? managedSSHHosts().first(where: { $0.host == validHost })?.rcloneRemote
            guard let remoteSpec = configuredRemote, !remoteSpec.isEmpty else {
                throw DisklesslyError.usage("Mode B (direct) requires an rclone remote configured for \(validHost)")
            }
            usedRcloneRemote = remoteSpec
            let remoteTmp = "/tmp/disklessly-\(txid).tar.gz"
            let qTmp = SSHCommand.shellQuote(remoteTmp)
            let prepOut = try sshTransport.run(
                validHost,
                "trap 'rm -f \(qTmp)' INT TERM; set -e; (\(streamCmd)) > \(qTmp); gzip -t \(qTmp); sha=$( (sha256sum \(qTmp) 2>/dev/null || shasum -a 256 \(qTmp)) | awk '{print $1}' ); sz=$(wc -c < \(qTmp) | tr -d ' '); printf '%s %s\\n' \"$sha\" \"$sz\"",
                nil,
                600
            )
            let tokens = String(decoding: prepOut, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard tokens.count >= 2, let sz = UInt64(tokens[1]), sz > 0, tokens[0].count == 64 else {
                _ = try? sshTransport.run(validHost, "rm -f \(qTmp)", nil, 15)
                throw DisklesslyError.failure("remote hash/size check failed during direct offload")
            }
            sha256 = String(tokens[0])
            storedBytes = sz
            repoObject = RemoteOffloadRecord.objectPath(host: validHost, sha256: sha256, kind: kind)
            let rcloneDest: String
            if remoteSpec.contains(":") {
                rcloneDest = (remoteSpec.hasSuffix(":") || remoteSpec.hasSuffix("/")) ? "\(remoteSpec)\(repoObject)" : "\(remoteSpec)/\(repoObject)"
            } else {
                rcloneDest = "\(remoteSpec):\(repoObject)"
            }
            let qDest = SSHCommand.shellQuote(rcloneDest)
            _ = try sshTransport.run(
                validHost,
                "rclone copyto \(qTmp) \(qDest); rc=$?; rm -f \(qTmp); [ $rc -eq 0 ]",
                nil,
                600
            )
        } else {
            // Mode A (default): relay stream over SSH into our StorageBackend
            try FileManager.default.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
            let tempFile = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("remote-offload-\(txid).tar.gz")
            _ = FileManager.default.createFile(atPath: tempFile.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: tempFile) }

            let handle = try FileHandle(forWritingTo: tempFile)
            var hasher = SHA256Digest.Stream()
            var written: UInt64 = 0
            do {
                try sshTransport.streamOut(validHost, streamCmd, nil, { chunk in
                    hasher.update(chunk)
                    try handle.write(contentsOf: chunk)
                    written += UInt64(chunk.count)
                }, 600)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard written > 20 else {
                throw DisklesslyError.failure("remote archive stream produced empty or invalid archive for \(canonPath)")
            }
            sha256 = hasher.finalize()
            storedBytes = written
            repoObject = RemoteOffloadRecord.objectPath(host: validHost, sha256: sha256, kind: kind)

            if case .conflict(let msg) = try WriteOnce.publishFile(backend: backend, path: repoObject, file: tempFile, sha256: sha256) {
                throw DisklesslyError.integrity(msg)
            }
        }

        journal.sha256 = sha256
        journal.repoObject = repoObject
        journal.phase = .uploaded
        journal.updatedAt = Date()
        try persistRemoteJournal(journal)

        // Verify in repo when using Mode A
        if mode != "direct" {
            guard let stat = try backend.stat(repoObject), stat.size == storedBytes else {
                throw DisklesslyError.integrity("repo object verification failed for \(repoObject)")
            }
            if let localRoot = backend.localRoot() {
                let actualSha = try SHA256Digest.hexFile(localRoot.appendingPathComponent(repoObject))
                guard actualSha == sha256 else {
                    throw DisklesslyError.integrity("repo digest mismatch for \(repoObject)")
                }
            }
        }

        let recordId = String(SHA256Digest.hex(Data("\(validHost)\n\(canonPath)\n\(sha256)\n\(txid)".utf8)).prefix(16))
        let record = RemoteOffloadRecord(
            id: recordId,
            host: validHost,
            kind: kind,
            title: item.title,
            originalPath: canonPath,
            stubPath: stubPath,
            repoObject: repoObject,
            sha256: sha256,
            storedBytes: storedBytes,
            logicalBytes: item.bytes,
            mode: mode,
            rcloneRemote: usedRcloneRemote
        )
        let recordPath = RemoteOffloadRecord.recordPath(host: validHost, id: recordId)
        try backend.put(recordPath, data: try record.encode())

        journal.recordId = recordId
        journal.phase = .verified
        journal.updatedAt = Date()
        try persistRemoteJournal(journal)

        do {
            if let failureInjector { try failureInjector("remote.offload.verified") }

            if let ctr = containerInfo {
                _ = try sshTransport.run(validHost, "\(ctr.runtime) rmi \(SSHCommand.shellQuote(ctr.ref))", nil, 60)
            } else if let stubPath, let asidePath {
                let stubData = try record.encode()
                let qStub = SSHCommand.shellQuote(stubPath)
                let qTarget = SSHCommand.shellQuote(canonPath)
                let qAside = SSHCommand.shellQuote(asidePath)

                // 1. Write stub file on remote
                _ = try sshTransport.run(validHost, "cat > \(qStub)", stubData, 30)
                journal.phase = .stubbed
                journal.updatedAt = Date()
                try persistRemoteJournal(journal)

                if let failureInjector { try failureInjector("remote.offload.stubbed") }

                // 2. Move original aside
                _ = try sshTransport.run(validHost, "mv \(qTarget) \(qAside)", nil, 30)
                journal.phase = .movedAside
                journal.updatedAt = Date()
                try persistRemoteJournal(journal)

                if let failureInjector { try failureInjector("remote.offload.movedAside") }

                // 3. Remove aside copy
                _ = try sshTransport.run(validHost, "rm -rf \(qAside)", nil, 120)
            }
        } catch {
            // If we failed before moving the original aside, remove the premature repo record so it is not orphaned.
            if journal.phase != .movedAside {
                try? backend.delete(recordPath)
            }
            throw error
        }

        journal.phase = .completed
        journal.updatedAt = Date()
        try persistRemoteJournal(journal)

        _ = try? scanRemoteMachine(host: validHost)

        return [
            "ok": true,
            "host": validHost,
            "action": "offload",
            "dryRun": false,
            "record": record.jsonObject(),
            "txid": txid,
        ]
    }

    /// Lists all offloaded records stored in the repo for `host`.
    public func listRemoteOffloaded(host: String) throws -> [RemoteOffloadRecord] {
        let validHost = try validateSSHHost(host)
        let backend = try openBackend()
        let safeHost = SSHCommand.sanitizeHost(validHost)
        let dir = "machines/\(safeHost)/records"
        let names = (try? backend.list(dir)) ?? []
        var records: [RemoteOffloadRecord] = []
        for name in names where name.hasSuffix(".json") && !RepoFileNames.isPlaceholder(name) && !RepoFileNames.isConflictCopy(name) {
            let path = "\(dir)/\(name)"
            if let data = try? backend.get(path, range: nil),
               let rec = try? RemoteOffloadRecord.decode(data) {
                records.append(rec)
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    /// Restores an offloaded remote item from the repo back to `host` (#46 §3).
    public func restoreRemoteItem(
        host: String,
        recordIdOrPath: String,
        dryRun: Bool = false
    ) throws -> [String: Any] {
        let validHost = try validateSSHHost(host)
        let plan = try planRemoteAction(host: validHost, action: "restore", targets: [recordIdOrPath], mode: "relay")
        if dryRun { return plan.jsonObject() }

        let records = try listRemoteOffloaded(host: validHost)
        let canonTarget = RemotePathPolicy.canonicalize(recordIdOrPath)
        guard let record = records.first(where: { $0.id == recordIdOrPath || $0.originalPath == recordIdOrPath || $0.originalPath == canonTarget }) else {
            throw DisklesslyError.usage("no offloaded record found for '\(recordIdOrPath)' on \(validHost)")
        }
        let cached = RemoteMachineStore.loadCachedScan(stateDir: config.stateDir, host: validHost)
        if let why = RemotePathPolicy.refusal(for: record.originalPath, remoteHome: cached?.remoteHome) {
            throw DisklesslyError.integrity("refusing restore to unsafe path in record: \(why)")
        }

        let backend = try openPrimaryBackend()
        let txid = UUID().uuidString.lowercased()
        var journal = RemoteJournal(
            txid: txid,
            host: validHost,
            action: "restore",
            mode: record.mode,
            targetPath: record.originalPath,
            stubPath: record.stubPath,
            repoObject: record.repoObject,
            recordId: record.id,
            sha256: record.sha256,
            bytes: record.logicalBytes,
            phase: .planned
        )
        try persistRemoteJournal(journal)

        if record.mode == "direct", let remoteSpec = record.rcloneRemote ?? managedSSHHosts().first(where: { $0.host == validHost })?.rcloneRemote, !remoteSpec.isEmpty {
            let rcloneSrc: String
            if remoteSpec.contains(":") {
                rcloneSrc = (remoteSpec.hasSuffix(":") || remoteSpec.hasSuffix("/")) ? "\(remoteSpec)\(record.repoObject)" : "\(remoteSpec)/\(record.repoObject)"
            } else {
                rcloneSrc = "\(remoteSpec):\(record.repoObject)"
            }
            let qSrc = SSHCommand.shellQuote(rcloneSrc)
            let remoteTmp = "/tmp/disklessly-restore-\(txid).tar.gz"
            let qTmp = SSHCommand.shellQuote(remoteTmp)
            let expectedSha = SSHCommand.shellQuote(record.sha256)

            if record.kind == "container-image" {
                guard let ctr = Self.allowedContainerRuntime(record.originalPath) else {
                    throw DisklesslyError.integrity("invalid container runtime in record: \(record.originalPath)")
                }
                let cmd = """
                trap 'rm -f \(qTmp)' EXIT INT TERM
                set -e
                rclone copyto \(qSrc) \(qTmp)
                sha=$( (sha256sum \(qTmp) 2>/dev/null || shasum -a 256 \(qTmp)) | awk '{print $1}' )
                [ "$sha" = \(expectedSha) ]
                gzip -dc \(qTmp) | \(ctr.runtime) load
                """
                _ = try sshTransport.run(validHost, cmd, nil, 600)
            } else {
                let parent = (record.originalPath as NSString).deletingLastPathComponent
                let name = (record.originalPath as NSString).lastPathComponent
                let stagingDir = "\(parent)/.disklessly-restore-\(txid)"
                let qStaging = SSHCommand.shellQuote(stagingDir)
                let qExtracted = SSHCommand.shellQuote("\(stagingDir)/\(name)")
                let qTarget = SSHCommand.shellQuote(record.originalPath)
                let qStub = record.stubPath.map(SSHCommand.shellQuote) ?? "''"
                let cmd = """
                trap 'rm -f \(qTmp); rm -rf \(qStaging)' EXIT INT TERM
                set -e
                rclone copyto \(qSrc) \(qTmp)
                sha=$( (sha256sum \(qTmp) 2>/dev/null || shasum -a 256 \(qTmp)) | awk '{print $1}' )
                [ "$sha" = \(expectedSha) ]
                mkdir -p \(qStaging)
                gzip -dc \(qTmp) | tar -C \(qStaging) -xf -
                test -e \(qExtracted)
                if [ -e \(qTarget) ]; then echo "target already exists: \(record.originalPath)" >&2; exit 17; fi
                mv \(qExtracted) \(qTarget)
                rmdir \(qStaging) 2>/dev/null || rm -rf \(qStaging)
                if [ -n \(qStub) ] && [ -e \(qStub) ]; then rm -f \(qStub); fi
                """
                _ = try sshTransport.run(validHost, cmd, nil, 600)
            }
        } else {
            try FileManager.default.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
            let stagedArchive = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("remote-restore-\(record.id).tar.gz")
            let partialArchive = URL(fileURLWithPath: config.cacheDir).appendingPathComponent("remote-restore-\(record.id).part")
            defer {
                try? FileManager.default.removeItem(at: stagedArchive)
                try? FileManager.default.removeItem(at: partialArchive)
            }

            try CacheFetcher.materialize(
                backend: backend,
                remote: record.repoObject,
                destination: stagedArchive,
                partial: partialArchive,
                expectedSize: record.storedBytes,
                expectedSHA256: record.sha256
            )

            if record.kind == "container-image" {
                guard let ctr = Self.allowedContainerRuntime(record.originalPath) else {
                    throw DisklesslyError.integrity("invalid container runtime in record: \(record.originalPath)")
                }
                _ = try sshTransport.runWithStdinFile(validHost, "gzip -dc | \(ctr.runtime) load", stagedArchive, 600)
            } else {
                let parent = (record.originalPath as NSString).deletingLastPathComponent
                let name = (record.originalPath as NSString).lastPathComponent
                let stagingDir = "\(parent)/.disklessly-restore-\(txid)"
                let qStaging = SSHCommand.shellQuote(stagingDir)
                let qExtracted = SSHCommand.shellQuote("\(stagingDir)/\(name)")
                let qTarget = SSHCommand.shellQuote(record.originalPath)
                let qStub = record.stubPath.map(SSHCommand.shellQuote) ?? "''"

                let restoreCmd = """
                trap 'rm -rf \(qStaging)' EXIT INT TERM
                set -e
                mkdir -p \(qStaging)
                gzip -dc | tar -C \(qStaging) -xf -
                test -e \(qExtracted)
                if [ -e \(qTarget) ]; then echo "target already exists: \(record.originalPath)" >&2; exit 17; fi
                mv \(qExtracted) \(qTarget)
                rmdir \(qStaging) 2>/dev/null || rm -rf \(qStaging)
                if [ -n \(qStub) ] && [ -e \(qStub) ]; then rm -f \(qStub); fi
                """
                _ = try sshTransport.runWithStdinFile(validHost, restoreCmd, stagedArchive, 600)
            }
        }

        let recordPath = RemoteOffloadRecord.recordPath(host: validHost, id: record.id)
        try? backend.delete(recordPath)

        journal.phase = .completed
        journal.updatedAt = Date()
        try persistRemoteJournal(journal)

        _ = try? scanRemoteMachine(host: validHost)

        return [
            "ok": true,
            "host": validHost,
            "action": "restore",
            "dryRun": false,
            "restoredPath": record.originalPath,
            "recordId": record.id,
            "bytes": NSNumber(value: record.logicalBytes),
        ]
    }

    // MARK: - Journal Persistence & Recovery (#46 §3)

    private func persistRemoteJournal(_ journal: RemoteJournal) throws {
        try RemoteMachineStore.saveJournal(journal, stateDir: config.stateDir)
        if RemoteJournal.isValidTxid(journal.txid), let data = try? journal.encode() {
            let qFile = SSHCommand.shellQuote("\(journal.txid).json")
            let remoteJournalCmd = "mkdir -p \"$HOME/.disklessly/journal\" && cat > \"$HOME/.disklessly/journal\"/\(qFile)"
            _ = try? sshTransport.run(journal.host, remoteJournalCmd, data, 15)
        }
    }

    /// Inspects incomplete remote transaction journals for `host` and rolls back or finishes them safely.
    public func recoverRemoteJournals(host: String) throws -> [[String: Any]] {
        let validHost = try validateSSHHost(host)
        let journals = RemoteMachineStore.loadJournals(stateDir: config.stateDir, host: validHost)
        let backend = try? openPrimaryBackend()
        var actions: [[String: Any]] = []

        for var journal in journals {
            guard journal.phase != .completed && journal.phase != .rolledBack && journal.phase != .failed else { continue }
            let qTarget = SSHCommand.shellQuote(journal.targetPath)
            let qAside = journal.asidePath.map(SSHCommand.shellQuote) ?? "''"
            let qStub = journal.stubPath.map(SSHCommand.shellQuote) ?? "''"
            let probeCmd = """
            t=0; a=0; s=0
            [ -e \(qTarget) ] && t=1
            [ -n \(qAside) ] && [ -e \(qAside) ] && a=1
            [ -n \(qStub) ] && [ -e \(qStub) ] && s=1
            printf '%s %s %s\\n' "$t" "$a" "$s"
            """
            let out = try sshTransport.run(validHost, probeCmd, nil, 15)
            let flags = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            let targetExists = flags.count > 0 && flags[0] == "1"
            let asideExists = flags.count > 1 && flags[1] == "1"
            let stubExists = flags.count > 2 && flags[2] == "1"

            let decision = RemoteJournalRecovery.decide(
                journal: journal,
                targetExists: targetExists,
                asideExists: asideExists,
                stubExists: stubExists
            )
            switch decision {
            case .none:
                journal.phase = .rolledBack
                if let recId = journal.recordId {
                    try? backend?.delete(RemoteOffloadRecord.recordPath(host: validHost, id: recId))
                }
            case .markCompleted:
                journal.phase = .completed
            case .removeStubOnly(let stubPath):
                _ = try sshTransport.run(validHost, "rm -f \(SSHCommand.shellQuote(stubPath))", nil, 15)
                journal.phase = .rolledBack
                if let recId = journal.recordId {
                    try? backend?.delete(RemoteOffloadRecord.recordPath(host: validHost, id: recId))
                }
            case .rollbackMoveAside(let asidePath, let targetPath, let stubPath):
                var cmd = "mv \(SSHCommand.shellQuote(asidePath)) \(SSHCommand.shellQuote(targetPath))"
                if let stubPath { cmd += " && rm -f \(SSHCommand.shellQuote(stubPath))" }
                _ = try sshTransport.run(validHost, cmd, nil, 30)
                journal.phase = .rolledBack
                if let recId = journal.recordId {
                    try? backend?.delete(RemoteOffloadRecord.recordPath(host: validHost, id: recId))
                }
            case .finishRemoveAside(let asidePath):
                _ = try sshTransport.run(validHost, "rm -rf \(SSHCommand.shellQuote(asidePath))", nil, 60)
                journal.phase = .completed
            }
            journal.updatedAt = Date()
            try persistRemoteJournal(journal)
            actions.append([
                "txid": journal.txid,
                "decision": String(describing: decision),
                "phase": journal.phase.rawValue,
            ])
        }
        return actions
    }
}
