import XCTest
@testable import DisklesslyCore
@testable import DisklesslyEngine

final class RemoteMachinesTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("disklessly-remote-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - 1. SSH Config Parser & SSHCommand Safety

    func testSSHConfigParserFiltersWildcardsMergesDefaultsAndRejectsOptionHosts() {
        let configText = """
        # Global defaults
        Host *
            User default-user
            ServerAliveInterval 30

        Host gpu-box gpu-backup *.internal !bad-host -oProxyCommand=bad
            HostName 10.0.1.50
            User ubuntu
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
            ProxyJump bastion

        Host mac-mini-m4
            HostName 192.168.1.88

        Host ?-temp
            HostName 10.0.0.9
        """

        let entries = SSHConfigParser.parse(configText)
        XCTAssertEqual(entries.map(\.alias), ["gpu-box", "gpu-backup", "mac-mini-m4"])
        XCTAssertEqual(entries[0].hostname, "10.0.1.50")
        XCTAssertEqual(entries[0].user, "ubuntu")
        XCTAssertEqual(entries[0].port, 2222)
        XCTAssertEqual(entries[0].identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(entries[0].proxyJump, "bastion")
        XCTAssertEqual(entries[0].displayTarget, "ubuntu@10.0.1.50:2222")

        // mac-mini-m4 inherits User from `Host *`
        XCTAssertEqual(entries[2].hostname, "192.168.1.88")
        XCTAssertEqual(entries[2].user, "default-user")
        XCTAssertNil(entries[2].port)
        XCTAssertEqual(entries[2].displayTarget, "default-user@192.168.1.88")

        XCTAssertFalse(SSHConfigParser.isConcreteHost("-oProxyCommand=sh"))
        XCTAssertFalse(SSHConfigParser.isConcreteHost("*.example.com"))
        XCTAssertTrue(SSHConfigParser.isConcreteHost("prod-node-01"))
    }

    func testSSHCommandArgumentsIncludesDoubleDashAndExtractsLastStderrLine() {
        let args = SSHCommand.arguments(host: "gpu-box", remoteCommand: "uname -sm")
        XCTAssertEqual(args, [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "--",
            "gpu-box",
            "uname -sm",
        ])

        let stderr = """
        Warning: Permanently added 'gpu-box' (ED25519) to the list of known hosts.
        Permission denied (publickey).

        """
        XCTAssertEqual(SSHCommand.lastErrorLine(stderr), "Permission denied (publickey).")
        XCTAssertEqual(SSHCommand.shellQuote("/home/user/my 'folder'"), "'/home/user/my '\\''folder'\\'''")
    }

    // MARK: - 2. Machine Ordering Pure Function (#46 §4)

    func testMachineOrderingOfflineCriticalWarningThenConfiguredOrder() {
        let mOk2 = MachineCardSummary(id: "ok-2", host: "ok-2", displayName: "OK 2", configuredOrder: 2, reachable: true, level: .ok)
        let mWarn = MachineCardSummary(id: "warn-1", host: "warn-1", displayName: "Warn 1", configuredOrder: 5, reachable: true, level: .warning)
        let mOffline = MachineCardSummary(id: "off-1", host: "off-1", displayName: "Offline 1", configuredOrder: 9, reachable: false, level: .offline)
        let mCrit = MachineCardSummary(id: "crit-1", host: "crit-1", displayName: "Crit 1", configuredOrder: 4, reachable: true, level: .critical)
        let mOk1 = MachineCardSummary(id: "ok-1", host: "ok-1", displayName: "OK 1", configuredOrder: 1, reachable: true, level: .ok)

        let sorted = MachineOrdering.sort([mOk2, mWarn, mOffline, mCrit, mOk1])
        XCTAssertEqual(sorted.map(\.id), ["off-1", "crit-1", "warn-1", "ok-1", "ok-2"])
    }

    // MARK: - 3. Single-Trip Scan Output Parser & Mounts (#46 §2)

    func testRemoteScanProbeParsesLinuxMountsCachesKernelsDockerAndLargeDirs() throws {
        let sampleOutput = """
        @@SECTION:UNAME
        Linux x86_64
        @@SECTION:HOSTNAME
        gpu-worker-01
        @@SECTION:HOME
        /home/ubuntu
        @@SECTION:BIN_VERSION
        disklessly 0.2.3
        @@SECTION:PROC_MOUNTS
        /dev/sda1 / ext4 rw,relatime 0 0
        /dev/sda1 /var/snap/bind ext4 rw,relatime 0 0
        /dev/loop0 /snap/core20/1 squashfs ro,nodev 0 0
        tmpfs /run tmpfs rw,nosuid 0 0
        /dev/nvme0n1p1 /data xfs rw,relatime 0 0
        @@SECTION:DF
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        /dev/sda1        104857600  83886080  20971520      80% /
        /dev/sda1        104857600  83886080  20971520      80% /var/snap/bind
        /dev/loop0          131072    131072         0     100% /snap/core20/1
        tmpfs              8388608      1024   8387584       1% /run
        /dev/nvme0n1p1   524288000 104857600 419430400      20% /data
        @@SECTION:CACHES
        cache-pip\tpackage-cache\tpip wheel & http cache\t/home/ubuntu/.cache/pip\t2097152\tclean\tfalse\tRebuildable Python pip cache
        model-hf\tmodel-cache\tHuggingFace Hub models\t/home/ubuntu/.cache/huggingface\t10485760\toffload\ttrue\tLarge AI model weights
        @@SECTION:KERNELS
        kernel-6.1.0-10\tkernel-snap\tOld kernel modules (6.1.0-10)\t/lib/modules/6.1.0-10\t262144\tclean\tfalse\tInactive kernel module tree
        @@SECTION:JOURNAL
        Archived and active journals take up 512.0M in the file system.
        @@SECTION:CONTAINERS
        docker|pytorch/pytorch:2.4-cuda12|sha256:abcdef123456|6.5GB
        docker|busy/image:latest|sha256:999999|1.2GB
        inuse|docker|busy/image:latest|c1
        @@SECTION:LARGE_HOME
        large-dir\t4194304\t/home/ubuntu/datasets
        @@SECTION:END
        """

        let report = RemoteScanProbe.parse(host: "gpu-box", output: sampleOutput)
        XCTAssertEqual(report.host, "gpu-box")
        XCTAssertEqual(report.hostname, "gpu-worker-01")
        XCTAssertEqual(report.remoteHome, "/home/ubuntu")
        XCTAssertEqual(report.platform, RemotePlatform(os: "linux", arch: "x86_64", raw: "Linux x86_64"))
        XCTAssertEqual(report.binaryVersion, "0.2.3")
        XCTAssertEqual(report.scanMode, "binary+sh")

        // Deduped bind mount (/dev/sda1), skipped loop0 and tmpfs -> only / and /data remain
        XCTAssertEqual(report.mounts.map(\.mountPoint), ["/", "/data"])
        XCTAssertEqual(report.mounts[0].fsType, "ext4")
        XCTAssertEqual(report.primaryMount?.mountPoint, "/")

        XCTAssertEqual(report.items.count, 7)
        XCTAssertEqual(report.items[0].id, "model-hf")
        XCTAssertEqual(report.items[0].action, .offload)
        XCTAssertEqual(report.items[1].category, "container-image")
        XCTAssertFalse(report.items[1].inUse)
        let busyImg = try XCTUnwrap(report.items.first { $0.path == "docker://busy/image:latest" })
        XCTAssertTrue(busyImg.inUse, "container image used by a container should be marked inUse")
        XCTAssertFalse(report.recommendations.contains { $0.path == "docker://busy/image:latest" }, "inUse items are excluded from recommendations")
        XCTAssertTrue(report.reclaimableBytes > 2 * 1024 * 1024 * 1024)
        XCTAssertTrue(report.offloadableBytes > 14 * 1024 * 1024 * 1024)
    }

    func testDarwinMountsReportSystemVolumesData() {
        let dfLines = [
            "Filesystem     1024-blocks      Used Available Capacity Mounted on",
            "/dev/disk3s1s1   488245288  15000000 200000000       7% /",
            "/dev/disk3s5     488245288 273245288 200000000      58% /System/Volumes/Data",
            "devfs                  385       385         0     100% /dev",
        ]
        let mounts = RemoteScanProbe.parseMounts(procMounts: [], dfLines: dfLines, os: "darwin")
        XCTAssertEqual(mounts.count, 1)
        XCTAssertEqual(mounts.first?.mountPoint, "/System/Volumes/Data")
        XCTAssertEqual(mounts.first?.fsType, "apfs")
    }

    // MARK: - 4. Path Refusal Policy

    func testRemotePathPolicyRefusesSystemAndHomeAndSSHPaths() {
        let home = "/home/ubuntu"
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/home", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/home/ubuntu", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/home/otheruser", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/Users/alice", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/home/ubuntu/.ssh", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/home/ubuntu/.ssh/authorized_keys", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/home/ubuntu/.disklessly/journal", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/etc/passwd", remoteHome: home))
        XCTAssertNotNil(RemotePathPolicy.refusal(for: "/home/ubuntu/../ubuntu", remoteHome: home))
        XCTAssertNil(RemotePathPolicy.refusal(for: "/home/ubuntu/datasets", remoteHome: home))
        XCTAssertNil(RemotePathPolicy.refusal(for: "docker://pytorch/pytorch:2.4", remoteHome: home))
    }

    // MARK: - 5. End-to-End Loopback SSH Scan, Plan, Clean, Offload (Mode A & Mode B), Restore & Recovery

    private func makeLoopbackEngine() throws -> (DisklesslyEngine, URL, URL) {
        let localHome = root.appendingPathComponent("local-home", isDirectory: true)
        let remoteHome = root.appendingPathComponent("remote-home", isDirectory: true)
        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        for dir in [localHome, remoteHome, repoDir, binDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Write ~/.ssh/config in localHome
        let sshDir = localHome.appendingPathComponent(".ssh", isDirectory: true)
        try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try """
        Host test-box
            HostName 127.0.0.1
            User tester
        """.write(to: sshDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        // Create fake rclone in binDir for Mode B testing
        let rcloneStore = root.appendingPathComponent("rclone-store", isDirectory: true)
        try fm.createDirectory(at: rcloneStore, withIntermediateDirectories: true)
        let fakeRclone = binDir.appendingPathComponent("rclone")
        let rcloneScript = """
        #!/bin/sh
        CMD="$1"
        SRC="$2"
        DST="$3"
        map_path() {
          case "$1" in
            *:*)
              REL="${1#*:}"
              echo "\(rcloneStore.path)/$REL"
              ;;
            *)
              echo "$1"
              ;;
          esac
        }
        if [ "$CMD" = "copyto" ]; then
          S=$(map_path "$SRC")
          D=$(map_path "$DST")
          mkdir -p "$(dirname "$D")"
          cp "$S" "$D"
          exit 0
        fi
        exit 1
        """
        try rcloneScript.write(to: fakeRclone, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRclone.path)

        // Create fake SSH script that executes the remote command locally with HOME=remoteHome and PATH including binDir
        let fakeSSH = binDir.appendingPathComponent("fake-ssh")
        let script = """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          case "$1" in
            -T) shift ;;
            -o) shift; shift ;;
            --) shift; HOST="$1"; shift; break ;;
            -*) shift ;;
            *) HOST="$1"; shift; break ;;
          esac
        done
        export HOME="\(remoteHome.path)"
        export PATH="\(binDir.path):$PATH"
        exec /bin/sh -c "$@"
        """
        try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

        var config = RuntimeConfig(
            repoPath: repoDir.path,
            cacheDir: root.appendingPathComponent("cache").path,
            stateDir: root.appendingPathComponent("state").path,
            mountRoot: root.appendingPathComponent("mnt").path,
            stubDir: root.appendingPathComponent("apps").path
        )
        config.minFreeBytes = 0

        var engine = DisklesslyEngine(config: config, secrets: MemorySecretStore())
        engine.homeOverride = localHome.path
        engine.backendOverride = try LocalFolderBackend(root: repoDir)
        engine.sshTransportOverride = .live(sshExecutable: fakeSSH.path)
        try engine.initialize()
        return (engine, remoteHome, binDir)
    }

    func testLoopbackSSHScanCleanOffloadAndRestoreEndToEnd() throws {
        let (engine, remoteHome, _) = try makeLoopbackEngine()

        // Populate remoteHome with a pip cache (2 MiB) and a large dataset folder (3 MiB)
        let pipCache = remoteHome.appendingPathComponent(".cache/pip", isDirectory: true)
        try fm.createDirectory(at: pipCache, withIntermediateDirectories: true)
        let wheelData = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        try wheelData.write(to: pipCache.appendingPathComponent("torch.whl"))

        let datasetDir = remoteHome.appendingPathComponent("training-data", isDirectory: true)
        try fm.createDirectory(at: datasetDir, withIntermediateDirectories: true)
        let sampleA = Data("sample-alpha-payload-".utf8) + Data(repeating: 0x42, count: 1500 * 1024)
        let sampleB = Data("sample-beta-payload-".utf8) + Data(repeating: 0x43, count: 1500 * 1024)
        try sampleA.write(to: datasetDir.appendingPathComponent("part1.bin"))
        try sampleB.write(to: datasetDir.appendingPathComponent("part2.bin"))

        // 1. Scan over fake SSH
        let report = try engine.scanRemoteMachine(host: "test-box")
        XCTAssertEqual(report.host, "test-box")
        XCTAssertEqual(report.remoteHome, remoteHome.path)
        XCTAssertTrue(report.items.contains(where: { $0.id == "cache-pip" && $0.action == .clean }))
        XCTAssertTrue(report.items.contains(where: { $0.path == datasetDir.path && $0.action == .offload }))

        // Verify remoteHome protection: trying to clean or offload remoteHome itself is refused
        XCTAssertThrowsError(try engine.offloadRemoteItem(host: "test-box", target: remoteHome.path))
        XCTAssertThrowsError(try engine.cleanRemoteMachine(host: "test-box", targets: [remoteHome.path]))

        // 2. Dry-run Clean Plan -> changes nothing
        let dryClean = try engine.cleanRemoteMachine(host: "test-box", targets: ["cache-pip"], dryRun: true)
        XCTAssertEqual(dryClean["dryRun"] as? Bool, true)
        XCTAssertTrue(fm.fileExists(atPath: pipCache.appendingPathComponent("torch.whl").path))

        // 3. Execute Clean -> removes contents of .cache/pip and writes completed journal
        let cleanRes = try engine.cleanRemoteMachine(host: "test-box", targets: ["cache-pip"], dryRun: false)
        XCTAssertEqual(cleanRes["dryRun"] as? Bool, false)
        XCTAssertFalse(fm.fileExists(atPath: pipCache.appendingPathComponent("torch.whl").path))

        // 4. Dry-run Offload Plan (with trailing slash) -> canonicalizes path and changes nothing
        let dryOffload = try engine.offloadRemoteItem(host: "test-box", target: datasetDir.path + "/", dryRun: true)
        XCTAssertEqual(dryOffload["dryRun"] as? Bool, true)
        XCTAssertTrue(fm.fileExists(atPath: datasetDir.path))

        // 5. Execute Offload (Mode A relay) -> uploads archive to repo `machines/test-box/objects/...`, writes stub, removes original
        let offloadRes = try engine.offloadRemoteItem(host: "test-box", target: datasetDir.path + "/", dryRun: false)
        XCTAssertEqual(offloadRes["ok"] as? Bool, true)
        let stubURL = URL(fileURLWithPath: "\(datasetDir.path).disklessly-remote")
        XCTAssertFalse(fm.fileExists(atPath: datasetDir.path), "original directory should be removed after offload")
        XCTAssertTrue(fm.fileExists(atPath: stubURL.path), "remote stub placeholder should exist")

        let offloadedRecords = try engine.listRemoteOffloaded(host: "test-box")
        XCTAssertEqual(offloadedRecords.count, 1)
        let record = try XCTUnwrap(offloadedRecords.first)
        XCTAssertEqual(record.originalPath, datasetDir.path)
        XCTAssertEqual(record.kind, "folder")
        XCTAssertTrue(record.repoObject.hasPrefix("machines/test-box/objects/"))

        // Verify remote journal was written under ~/.disklessly/journal
        let remoteJournalDir = remoteHome.appendingPathComponent(".disklessly/journal")
        let journalFiles = (try? fm.contentsOfDirectory(atPath: remoteJournalDir.path)) ?? []
        XCTAssertFalse(journalFiles.isEmpty, "remote transaction journal should exist in ~/.disklessly/journal")

        // 6. Execute Restore -> streams back from repo using file stdin, restores original files, removes stub
        let restoreRes = try engine.restoreRemoteItem(host: "test-box", recordIdOrPath: record.id, dryRun: false)
        XCTAssertEqual(restoreRes["ok"] as? Bool, true)
        XCTAssertTrue(fm.fileExists(atPath: datasetDir.path), "restored directory should exist")
        XCTAssertFalse(fm.fileExists(atPath: stubURL.path), "stub should be removed after restore")
        XCTAssertEqual(try Data(contentsOf: datasetDir.appendingPathComponent("part1.bin")), sampleA)
        XCTAssertEqual(try Data(contentsOf: datasetDir.appendingPathComponent("part2.bin")), sampleB)
        XCTAssertTrue(try engine.listRemoteOffloaded(host: "test-box").isEmpty)
    }

    func testModeBDirectRcloneOffloadAndRestoreAndBinaryDeploy() throws {
        let (engine, remoteHome, binDir) = try makeLoopbackEngine()
        _ = try engine.addRemoteMachine(host: "test-box", displayName: "Test Box", rcloneRemote: "cloud:bucket")

        // Create single large file to offload via Mode B (direct rclone)
        let singleFile = remoteHome.appendingPathComponent("checkpoint.safetensors")
        let payload = Data("safetensors-header-".utf8) + Data(repeating: 0x33, count: 1400 * 1024)
        try payload.write(to: singleFile)

        let offloadRes = try engine.offloadRemoteItem(host: "test-box", target: singleFile.path, mode: "direct", dryRun: false)
        XCTAssertEqual(offloadRes["ok"] as? Bool, true)
        XCTAssertFalse(fm.fileExists(atPath: singleFile.path))
        XCTAssertTrue(fm.fileExists(atPath: "\(singleFile.path).disklessly-remote"))

        let records = try engine.listRemoteOffloaded(host: "test-box")
        XCTAssertEqual(records.count, 1)
        let rec = try XCTUnwrap(records.first)
        XCTAssertEqual(rec.mode, "direct")
        XCTAssertEqual(rec.kind, "file")
        XCTAssertEqual(rec.rcloneRemote, "cloud:bucket")

        // Restore via Mode B
        let restoreRes = try engine.restoreRemoteItem(host: "test-box", recordIdOrPath: rec.id, dryRun: false)
        XCTAssertEqual(restoreRes["ok"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: singleFile), payload)
        XCTAssertFalse(fm.fileExists(atPath: "\(singleFile.path).disklessly-remote"))

        // Binary deploy test: place a fake artifact in binDir and deploy to remote ~/.disklessly/bin/disklessly
        let unameOut = try engine.sshTransport.run("test-box", "uname -sm", nil, 10)
        let plat = try XCTUnwrap(RemotePlatform.parse(unameSM: String(decoding: unameOut, as: UTF8.self)))
        let fakeArtifact = binDir.appendingPathComponent(plat.binaryArtifactName)
        let binScript = """
        #!/bin/sh
        echo "disklessly \(EngineInstall.version)"
        """
        try binScript.write(to: fakeArtifact, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeArtifact.path)

        let deployed = try engine.deployRemoteBinary(host: "test-box", binarySearchDir: binDir)
        XCTAssertEqual(deployed["ok"] as? Bool, true)
        XCTAssertEqual(deployed["upToDate"] as? Bool, false)
        XCTAssertTrue(fm.isExecutableFile(atPath: remoteHome.appendingPathComponent(".disklessly/bin/disklessly").path))

        // Second deploy without force detects matching version and skips re-upload
        let secondDeploy = try engine.deployRemoteBinary(host: "test-box", binarySearchDir: binDir)
        XCTAssertEqual(secondDeploy["upToDate"] as? Bool, true)
    }

    func testInterruptedOffloadJournalRecoveryRemovesOrphanRecordAndStub() throws {
        var (engine, remoteHome, _) = try makeLoopbackEngine()
        let folder = remoteHome.appendingPathComponent("interrupted-dir", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 1200 * 1024).write(to: folder.appendingPathComponent("weights.bin"))

        // Inject failure right after stub is written (before original is moved aside)
        engine.failureInjector = { point in
            if point == "remote.offload.stubbed" {
                throw DisklesslyError.failure("simulated interruption after stubbed")
            }
        }
        XCTAssertThrowsError(try engine.offloadRemoteItem(host: "test-box", target: folder.path))
        let stubPath = "\(folder.path).disklessly-remote"
        XCTAssertTrue(fm.fileExists(atPath: folder.path), "original still exists")
        XCTAssertTrue(fm.fileExists(atPath: stubPath), "dangling stub was written before crash")
        XCTAssertTrue(try engine.listRemoteOffloaded(host: "test-box").isEmpty, "premature record should be cleaned up on failure before movedAside")

        // Run recovery: should remove dangling stub and mark journal rolledBack
        engine.failureInjector = nil
        let recovered = try engine.recoverRemoteJournals(host: "test-box")
        XCTAssertEqual(recovered.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: stubPath), "recovery should clean up dangling stub")
        XCTAssertTrue(fm.fileExists(atPath: folder.path), "original remains intact")
    }

    // MARK: - 6. ManagementUI /api/machines Endpoints

    func testManagementUIMachinesEndpointsWorkOnLinuxAndMac() throws {
        let (engine, remoteHome, _) = try makeLoopbackEngine()
        let folder = remoteHome.appendingPathComponent("big-project", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x77, count: 1500 * 1024).write(to: folder.appendingPathComponent("data.bin"))

        let context = ManagementUIContext(platform: .linux)

        // GET /api/machines
        let getResp = ManagementUI.respond(
            engine: engine,
            webRoot: nil,
            request: UIRequest(method: "GET", path: "/api/machines"),
            context: context
        )
        XCTAssertEqual(getResp.status, 200)
        let overview = try XCTUnwrap(JSONSerialization.jsonObject(with: getResp.body) as? [String: Any])
        XCTAssertEqual(overview["ok"] as? Bool, true)
        let machines = try XCTUnwrap(overview["machines"] as? [[String: Any]])
        XCTAssertTrue(machines.contains(where: { $0["host"] as? String == "test-box" }))

        // POST /api/machines/scan (sync)
        let scanBody = try JSONSerialization.data(withJSONObject: ["host": "test-box", "sync": true])
        let scanResp = ManagementUI.respond(
            engine: engine,
            webRoot: nil,
            request: UIRequest(method: "POST", path: "/api/machines/scan", body: scanBody),
            context: context
        )
        XCTAssertEqual(scanResp.status, 200)

        // POST /api/machines/plan
        let planBody = try JSONSerialization.data(withJSONObject: ["host": "test-box", "action": "offload", "target": folder.path])
        let planResp = ManagementUI.respond(
            engine: engine,
            webRoot: nil,
            request: UIRequest(method: "POST", path: "/api/machines/plan", body: planBody),
            context: context
        )
        XCTAssertEqual(planResp.status, 200)
        let planObj = try XCTUnwrap(JSONSerialization.jsonObject(with: planResp.body) as? [String: Any])
        XCTAssertEqual(planObj["dryRun"] as? Bool, true)

        // POST /api/machines/offload
        let offloadBody = try JSONSerialization.data(withJSONObject: ["host": "test-box", "target": folder.path])
        let offloadResp = ManagementUI.respond(
            engine: engine,
            webRoot: nil,
            request: UIRequest(method: "POST", path: "/api/machines/offload", body: offloadBody),
            context: context
        )
        XCTAssertEqual(offloadResp.status, 200)
        XCTAssertFalse(fm.fileExists(atPath: folder.path))

        // GET /api/machines/detail
        let detailResp = ManagementUI.respond(
            engine: engine,
            webRoot: nil,
            request: UIRequest(method: "GET", path: "/api/machines/detail", query: ["host": "test-box"]),
            context: context
        )
        XCTAssertEqual(detailResp.status, 200)
        let detailObj = try XCTUnwrap(JSONSerialization.jsonObject(with: detailResp.body) as? [String: Any])
        let offloadedArr = try XCTUnwrap(detailObj["offloaded"] as? [[String: Any]])
        XCTAssertEqual(offloadedArr.count, 1)
        let recId = try XCTUnwrap(offloadedArr.first?["id"] as? String)

        // POST /api/machines/restore
        let restoreBody = try JSONSerialization.data(withJSONObject: ["host": "test-box", "id": recId])
        let restoreResp = ManagementUI.respond(
            engine: engine,
            webRoot: nil,
            request: UIRequest(method: "POST", path: "/api/machines/restore", body: restoreBody),
            context: context
        )
        XCTAssertEqual(restoreResp.status, 200)
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
    }
}
