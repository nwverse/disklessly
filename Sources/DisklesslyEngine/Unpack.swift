import Foundation
import DisklesslyCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension DisklesslyEngine {
    /// Lines for journals sitting in `needsAttention`. Doctor reports these and the CLI exits 14.
    public func unpackAttentionLines() -> [String] {
        let journals = (try? UnpackStore.loadAll(stateDir: config.stateDir)) ?? []
        return journals.filter { $0.phase == "needsAttention" }.map {
            "unpack \($0.appId) needs attention at \($0.dest). The journal is \(UnpackStore.file(config.stateDir, txid: $0.txid).path). Nothing was deleted."
        }
    }

    /// Replay local unpack and restore journals. `doctor --fix` calls this.
    /// Remote trash, legacy purge, and cache LRU stay on `gc`.
    @discardableResult
    public func recoverLocalJournals() throws -> [String] {
        var lines = try recoverPackJournals()
        lines.append(contentsOf: try recoverUnpackJournals())
        restore.loadConfiguredFaults()
        lines.append(contentsOf: try restore.recoverAll(shortLived: true))
        return lines
    }

    /// Replay open unpack journals. `gc` and the start of `unpack` both call this.
    /// A journal already marked `needsAttention` is left untouched. A journal whose
    /// app lock is held belongs to an unpack that is still running and is skipped.
    @discardableResult
    public func recoverUnpackJournals() throws -> [String] {
        let journals = try UnpackStore.loadAll(stateDir: config.stateDir)
        var notes: [String] = []
        for journal in journals {
            let directory = URL(fileURLWithPath: config.stateDir).appendingPathComponent("locks/app")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var lock = FileLock(path: directory.appendingPathComponent(journal.appId + ".lock").path)
            guard try lock.tryLock() else {
                notes.append("unpack \(journal.txid) is still running")
                continue
            }
            defer { lock.unlock() }
            notes.append(try recoverUnpack(journal))
        }
        return notes
    }

    /// Replace the stub at `manifest.app.originalPath` with the verified app.
    /// `to` copies the verified app into that directory and leaves the stub in place.
    public func unpack(_ manifest: ImageManifest, to directory: String? = nil) throws {
        try ensureDevice()
        let notes = try recoverUnpackJournals()
        let attention = notes.filter { $0.contains("needs attention") }
        if !attention.isEmpty {
            throw DisklesslyError.resolution(attention.joined(separator: "; "))
        }
        if let directory {
            try unpackCopy(manifest, directory: directory)
            return
        }
        // Held from preflight through install, so a stub click (which takes the same
        // lock to launch) cannot start the app while its stub is being replaced.
        try restore.withLock(manifest.bundleId) {
            try unpackInPlace(manifest)
        }
    }

    private func recoverUnpack(_ journal: UnpackJournal) throws -> String {
        if journal.phase == "needsAttention" {
            return "noop unpack \(journal.txid)"
        }
        let observed = try observeUnpack(journal)
        let action = UnpackRecovery.decide(
            phase: journal.phase,
            destIsStub: observed.destIsStub,
            destIsApp: observed.destIsApp,
            appNewVerified: observed.appNewVerified,
            parkedStubExists: observed.parkedStubExists
        )
        let dest = URL(fileURLWithPath: journal.dest)
        let staging = URL(fileURLWithPath: journal.staging)
        switch action {
        case .rollback:
            try removeStaging(staging)
            try UnpackStore.remove(stateDir: config.stateDir, txid: journal.txid)
            return "rolled back unpack \(journal.txid)"
        case .restoreStub:
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                return try markUnpackAttention(journal)
            }
            let parked = staging.appendingPathComponent("stub.app")
            guard FileManager.default.fileExists(atPath: parked.path) else {
                return try markUnpackAttention(journal)
            }
            try FileManager.default.moveItem(at: parked, to: dest)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
            try removeStaging(staging)
            try UnpackStore.remove(stateDir: config.stateDir, txid: journal.txid)
            return "restored stub unpack \(journal.txid)"
        case .installAndFinish:
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                return try markUnpackAttention(journal)
            }
            let appNew = staging.appendingPathComponent("app.new")
            guard observed.appNewVerified, FileManager.default.fileExists(atPath: appNew.path) else {
                return try markUnpackAttention(journal)
            }
            try failureInjector?("unpack.recover.install")
            try FileManager.default.moveItem(at: appNew, to: dest)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
            try finishInstalledUnpack(journal, dest: dest, staging: staging)
            return "installed unpack \(journal.txid)"
        case .deleteParkedStub:
            guard observed.destIsApp else { return try markUnpackAttention(journal) }
            try finishInstalledUnpack(journal, dest: dest, staging: staging)
            return "closed unpack \(journal.txid)"
        case .needsAttention:
            return try markUnpackAttention(journal)
        }
    }

    private func finishInstalledUnpack(_ journal: UnpackJournal, dest: URL, staging: URL) throws {
        try removeStaging(staging)
        try StateStore(config.stateDir).update { state in
            var app = state.apps[journal.appId] ?? AppState()
            app.imageId = journal.imageId
            app.state = "unpacked"
            app.mountPoint = nil
            state.apps[journal.appId] = app
        }
        try unregister(bundleId: journal.appId, imageId: journal.imageId, installPath: journal.dest)
        registerLaunchServices(dest)
        try UnpackStore.remove(stateDir: config.stateDir, txid: journal.txid)
    }

    private func markUnpackAttention(_ journal: UnpackJournal) throws -> String {
        var marked = journal
        marked.phase = "needsAttention"
        try UnpackStore.save(marked, stateDir: config.stateDir)
        let line = "unpack \(journal.appId) needs attention at \(journal.dest)"
        FileHandle.standardError.write(Data("disklessly: \(line)\n".utf8))
        return line
    }

    private func unpackCopy(_ manifest: ImageManifest, directory: String) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let target = folder.appendingPathComponent("\(manifest.name).app")
        if FileManager.default.fileExists(atPath: target.path) {
            throw DisklesslyError.usage("unpack target already exists: \(target.path)")
        }
        try preflightUnpack(manifest)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("disklessly-unpack-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        // extractVerifiedApp writes `staging/app.new`; the parent must exist first.
        // ditto creates it, but a plain copy (Darwin FileManager) does not.
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try extractVerifiedApp(manifest, staging: staging)
        if FileManager.default.fileExists(atPath: target.path) {
            throw DisklesslyError.usage("unpack target already exists: \(target.path)")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: staging.appendingPathComponent("app.new"), to: target)
    }

    private func unpackInPlace(_ manifest: ImageManifest) throws {
        try preflightUnpack(manifest)
        guard let tree = manifest.app.treeHash, let cdhash = manifest.app.cdhash, !tree.isEmpty, !cdhash.isEmpty else {
            throw DisklesslyError.integrity("unpack manifest is missing app.cdhash or app.treeHash")
        }
        let dest = URL(fileURLWithPath: manifest.app.originalPath)
        let txid = UUID().uuidString.lowercased()
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".disklessly-unpack-\(txid)")
        var journal = UnpackJournal(
            txid: txid,
            appId: manifest.bundleId,
            imageId: manifest.imageId,
            dest: dest.path,
            staging: staging.path,
            phase: "prepared",
            manifestTreeHash: tree,
            manifestCdhash: cdhash
        )
        do {
            try phaseUnpackPrepared(&journal)
            try phaseUnpackExtracted(&journal, manifest: manifest)
            try phaseUnpackStubParked(&journal, manifest: manifest)
            try phaseUnpackInstalled(&journal)
            try phaseUnpackStubDeleted(&journal)
            try phaseUnpackClosed(&journal)
        } catch let error as InjectedFault {
            throw error
        } catch {
            if Self.unpackPhaseIndex(journal.phase) < Self.unpackPhaseIndex("stubParked") {
                try? removeStaging(staging)
                try? UnpackStore.remove(stateDir: config.stateDir, txid: txid)
            } else {
                // The stub may already be in staging. Never delete staging or the
                // journal here: settle dest to the stub or the app first.
                settleFailedUnpack(journal)
            }
            throw error
        }
    }

    static func unpackPhaseIndex(_ phase: String) -> Int {
        ["prepared", "extracted", "stubParked", "installed", "stubDeleted", "closed"].firstIndex(of: phase) ?? 0
    }

    /// Called with the app lock held after a failure at or past `stubParked`. Runs the
    /// recovery table, then makes sure dest holds the stub or the verified app.
    private func settleFailedUnpack(_ failed: UnpackJournal) {
        let fm = FileManager.default
        var journal = failed
        let dest = URL(fileURLWithPath: journal.dest)
        let staging = URL(fileURLWithPath: journal.staging)
        if let observed = try? observeUnpack(journal) {
            if observed.destIsStub {
                // Failed before the stub moved. Nothing to undo but staging.
                try? removeStaging(staging)
                try? UnpackStore.remove(stateDir: config.stateDir, txid: journal.txid)
                return
            }
            if observed.destIsApp && journal.phase == "closed" {
                // Staging is gone already; retry the bookkeeping as a finished install.
                journal.phase = "stubDeleted"
                try? UnpackStore.save(journal, stateDir: config.stateDir)
            }
        }
        do {
            _ = try recoverUnpack(journal)
        } catch {
            FileHandle.standardError.write(Data("disklessly: unpack recovery failed: \(error)\n".utf8))
        }
        guard !fm.fileExists(atPath: dest.path) else { return }
        // Recovery could not install the app. Put the stub back.
        let parked = staging.appendingPathComponent("stub.app")
        guard fm.fileExists(atPath: parked.path) else {
            FileHandle.standardError.write(Data("disklessly: unpack \(journal.appId) left \(dest.path) empty; the journal \(UnpackStore.file(config.stateDir, txid: journal.txid).path) is kept\n".utf8))
            return
        }
        do {
            try fm.moveItem(at: parked, to: dest)
            try? DurableIO.syncItem(dest.deletingLastPathComponent())
            try? removeStaging(staging)
            try? UnpackStore.remove(stateDir: config.stateDir, txid: journal.txid)
        } catch {
            FileHandle.standardError.write(Data("disklessly: could not put the stub back at \(dest.path): \(error)\n".utf8))
        }
    }

    private func preflightUnpack(_ manifest: ImageManifest) throws {
        if restore.needsResolution(manifest.bundleId) != nil {
            throw DisklesslyError.resolution(restore.resolutionMessage(manifest.bundleId) ?? "\(manifest.bundleId) needs resolution before unpack")
        }
        if let reason = restore.blockReason(appId: manifest.bundleId) {
            throw DisklesslyError.busy(reason)
        }
        let dest = URL(fileURLWithPath: manifest.app.originalPath)
        let usage = services.probe([dest.path])
        let mounted = DisklesslyEngine.isActiveMountPoint(URL(fileURLWithPath: config.mountRoot).appendingPathComponent(manifest.imageId).path)
        if manifest.mode == .mount && mounted {
            throw DisklesslyError.busy("\(manifest.name) is mounted; detach it before unpack")
        }
        if usage != .clean {
            throw DisklesslyError.busy("\(manifest.name) is running; quit it before unpack")
        }
        try assertUnpackStub(manifest, dest: dest)
        let parent = dest.deletingLastPathComponent().path
        let free = try VolumeSpace.availableBytes(at: parent)
        let estimate = manifest.image.size * 3
        let need = estimate + config.minFreeBytes
        guard free >= need else {
            throw DisklesslyError.noSpace("free space \(free) bytes on \(parent) is below \(need) (unpacked estimate \(estimate) = 3 x \(manifest.image.size), minFree \(config.minFreeBytes))")
        }
    }

    func assertUnpackStub(_ manifest: ImageManifest, dest: URL) throws {
        let info = BundleFacts.readInfo(dest)
        let identifier = info?["CFBundleIdentifier"] as? String
        guard identifier == manifest.bundleId + ".256stub" else {
            throw DisklesslyError.integrity("unpack destination is not the stub for \(manifest.bundleId) at \(dest.path)")
        }
        let stubURL = dest.appendingPathComponent("Contents/Resources/stub.json")
        guard let data = try? Data(contentsOf: stubURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imageId = object["imageId"] as? String,
              imageId == manifest.imageId else {
            throw DisklesslyError.integrity("unpack destination stub.json does not match image \(manifest.imageId)")
        }
    }

    private func phaseUnpackPrepared(_ journal: inout UnpackJournal) throws {
        journal.phase = "prepared"
        try UnpackStore.save(journal, stateDir: config.stateDir)
        try faults.hit("unpack.prepared", "afterJournal")
        let staging = URL(fileURLWithPath: journal.staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(journal.txid.utf8).write(to: staging.appendingPathComponent(".txn"))
        try DurableIO.syncItem(staging)
        try faults.hit("unpack.prepared", "afterMutation")
    }

    private func phaseUnpackExtracted(_ journal: inout UnpackJournal, manifest: ImageManifest) throws {
        journal.phase = "extracted"
        try UnpackStore.save(journal, stateDir: config.stateDir)
        try faults.hit("unpack.extracted", "afterJournal")
        try extractVerifiedApp(manifest, staging: URL(fileURLWithPath: journal.staging))
        try faults.hit("unpack.extracted", "afterMutation")
    }

    private func extractVerifiedApp(_ manifest: ImageManifest, staging: URL) throws {
        guard let tree = manifest.app.treeHash, let cdhash = manifest.app.cdhash else {
            throw DisklesslyError.integrity("unpack manifest is missing app.cdhash or app.treeHash")
        }
        let image = try prefetch(manifest)
        let mount = URL(fileURLWithPath: config.mountRoot).appendingPathComponent("unpack-\(UUID().uuidString)")
        // Keeps the orphan reaper off this mount while it is in use.
        var lease = MountLease.tryAcquire(stateDir: config.stateDir, name: mount.lastPathComponent)
        defer { lease?.release() }
        let mounted = try services.attach(image, mount)
        defer {
            try? services.detach(mounted)
            try? FileManager.default.removeItem(at: mount)
        }
        let appNew = staging.appendingPathComponent("app.new")
        try services.extract(mounted, manifest.image.appPathInVolume, appNew)
        BundleHasher.removeMetadataSidecars(appNew)
        let actualTree = try services.treeHash(appNew)
        let actualCdhash = try services.cdhash(appNew)
        guard actualTree == tree, actualCdhash == cdhash else {
            throw DisklesslyError.integrity("unpacked bundle does not match manifest cdhash and tree hash (cdhash \(actualCdhash) vs \(cdhash), tree \(actualTree) vs \(tree))")
        }
        if let warning = try MASReceiptStore.reconcile(app: appNew, bundleId: manifest.bundleId, stateDir: URL(fileURLWithPath: config.stateDir)) {
            FileHandle.standardError.write(Data("disklessly: \(warning)\n".utf8))
        }
    }

    private func phaseUnpackStubParked(_ journal: inout UnpackJournal, manifest: ImageManifest) throws {
        let dest = URL(fileURLWithPath: journal.dest)
        let parked = URL(fileURLWithPath: journal.staging).appendingPathComponent("stub.app")
        // Extraction can take minutes. Look again right before moving dest, while
        // the phase is still `extracted` so a refusal only deletes staging.
        try assertUnpackStub(manifest, dest: dest)
        if services.probe([dest.path]) != .clean {
            throw DisklesslyError.busy("\(manifest.name) started while it was being unpacked; the stub was left in place")
        }
        journal.phase = "stubParked"
        try UnpackStore.save(journal, stateDir: config.stateDir)
        try faults.hit("unpack.stubParked", "afterJournal")
        try failureInjector?("unpack.stubParked.beforeMutation")
        if FileManager.default.fileExists(atPath: dest.path), !FileManager.default.fileExists(atPath: parked.path) {
            try FileManager.default.moveItem(at: dest, to: parked)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
            try DurableIO.syncItem(URL(fileURLWithPath: journal.staging))
        }
        try faults.hit("unpack.stubParked", "afterMutation")
        try failureInjector?("unpack.stubParked.afterMutation")
    }

    private func phaseUnpackInstalled(_ journal: inout UnpackJournal) throws {
        journal.phase = "installed"
        try UnpackStore.save(journal, stateDir: config.stateDir)
        try faults.hit("unpack.installed", "afterJournal")
        try failureInjector?("unpack.installed.beforeMutation")
        let dest = URL(fileURLWithPath: journal.dest)
        let appNew = URL(fileURLWithPath: journal.staging).appendingPathComponent("app.new")
        if FileManager.default.fileExists(atPath: appNew.path), !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.moveItem(at: appNew, to: dest)
            try DurableIO.syncItem(dest.deletingLastPathComponent())
        }
        try faults.hit("unpack.installed", "afterMutation")
        try failureInjector?("unpack.installed.afterMutation")
    }

    private func phaseUnpackStubDeleted(_ journal: inout UnpackJournal) throws {
        journal.phase = "stubDeleted"
        try UnpackStore.save(journal, stateDir: config.stateDir)
        try faults.hit("unpack.stubDeleted", "afterJournal")
        try failureInjector?("unpack.stubDeleted.beforeMutation")
        try removeStaging(URL(fileURLWithPath: journal.staging))
        try faults.hit("unpack.stubDeleted", "afterMutation")
        try failureInjector?("unpack.stubDeleted.afterMutation")
    }

    private func phaseUnpackClosed(_ journal: inout UnpackJournal) throws {
        journal.phase = "closed"
        try UnpackStore.save(journal, stateDir: config.stateDir)
        try faults.hit("unpack.closed", "afterJournal")
        try failureInjector?("unpack.closed.beforeMutation")
        try StateStore(config.stateDir).update { state in
            var app = state.apps[journal.appId] ?? AppState()
            app.imageId = journal.imageId
            app.state = "unpacked"
            app.mountPoint = nil
            state.apps[journal.appId] = app
        }
        try unregister(bundleId: journal.appId, imageId: journal.imageId, installPath: journal.dest)
        registerLaunchServices(URL(fileURLWithPath: journal.dest))
        try UnpackStore.remove(stateDir: config.stateDir, txid: journal.txid)
        try faults.hit("unpack.closed", "afterMutation")
    }

    private struct UnpackObservation {
        var destIsStub: Bool
        var destIsApp: Bool
        var appNewVerified: Bool
        var parkedStubExists: Bool
    }

    private func observeUnpack(_ journal: UnpackJournal) throws -> UnpackObservation {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: journal.dest)
        let staging = URL(fileURLWithPath: journal.staging)
        var destIsStub = false
        var destIsApp = false
        if fm.fileExists(atPath: dest.path) {
            let identifier = BundleFacts.readInfo(dest)?["CFBundleIdentifier"] as? String
            destIsApp = identifier == journal.appId
            if identifier == journal.appId + ".256stub" {
                let stubURL = dest.appendingPathComponent("Contents/Resources/stub.json")
                if let data = try? Data(contentsOf: stubURL),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (object["imageId"] as? String) == journal.imageId {
                    destIsStub = true
                }
            }
        }
        let appNew = staging.appendingPathComponent("app.new")
        var verified = false
        if fm.fileExists(atPath: appNew.path) {
            let tree = try? services.treeHash(appNew)
            let cdhash = try? services.cdhash(appNew)
            verified = tree == journal.manifestTreeHash && cdhash == journal.manifestCdhash
        }
        return UnpackObservation(
            destIsStub: destIsStub,
            destIsApp: destIsApp,
            appNewVerified: verified,
            parkedStubExists: fm.fileExists(atPath: staging.appendingPathComponent("stub.app").path)
        )
    }

    private func removeStaging(_ staging: URL) throws {
        let name = staging.lastPathComponent
        guard name.hasPrefix(".disklessly-unpack-") || name.hasPrefix("disklessly-unpack-copy-") else { return }
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
            try? DurableIO.syncItem(staging.deletingLastPathComponent())
        }
    }

    private func registerLaunchServices(_ dest: URL) {
        #if os(macOS)
        do {
            try ProcessRunner.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", dest.path])
        } catch {
            FileHandle.standardError.write(Data("disklessly: lsregister failed: \(error)\n".utf8))
        }
        #else
        _ = dest
        #endif
    }
}
