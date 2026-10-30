import Foundation
import IsenoughCore
import IsenoughStubSupport

public struct StubRefreshReport: Equatable {
    /// Stubs rewritten (engine path refreshed, `repoId` added when missing).
    public var updated: [String]
    /// Stubs left alone because they belong to another repo.
    public var foreign: [String]

    public init(updated: [String] = [], foreign: [String] = []) {
        self.updated = updated
        self.foreign = foreign
    }
}

extension IsenoughEngine {
    /// `isenough stub refresh --all`: rewrite this repo's installed stubs so
    /// they carry the repo's `repoId` and the stable engine path, then re-sign.
    ///
    /// A legacy stub (no `repoId`) is this repo's when its image has a manifest
    /// here. A stub that names another repo is reported in `foreign` and not
    /// touched. Old stubs keep launching either way; this only scopes claims.
    public func refreshOwnedStubs(appId: String?) throws -> StubRefreshReport {
        try ensureDevice()
        let backend = try repo
        let manifests = try readManifests(backend)
        let scope = try stubScope(backend, manifests: manifests)
        let enginePath = try installedEnginePath()
        var candidates = locatedStubs(matching: appId)
        for root in stubSearchRoots() {
            for app in RecommendPaths.topLevelApps(in: root) where Self.stub(app, matches: appId) {
                if !candidates.contains(where: { StubGenerator.pathsReferToSameLocation($0.path, app.path) }) {
                    candidates.append(app)
                }
            }
        }
        var report = StubRefreshReport()
        for bundle in candidates {
            guard let stub = StubIdentity.read(bundle: bundle) else { continue }
            let imageId = stub.imageId ?? Self.embeddedImageId(bundle) ?? ""
            guard !imageId.isEmpty, scope.owns(stub, imageId: imageId) else {
                report.foreign.append(bundle.path)
                continue
            }
            try rewriteStubEngine(bundle: bundle, enginePath: enginePath, repoId: scope.repoId, knownImageIds: scope.manifestIds)
            report.updated.append(bundle.path)
        }
        if appId != nil, report.updated.isEmpty, report.foreign.isEmpty {
            throw IsenoughError.usage("no installed stub for \(appId ?? "")")
        }
        // Claims may have changed now that stubs name this repo.
        try ensureDevice()
        return report
    }

    static func stub(_ app: URL, matches appId: String?) -> Bool {
        guard let stub = StubIdentity.read(bundle: app) else { return false }
        guard let appId else { return true }
        let name = app.deletingPathExtension().lastPathComponent
        return stub.appId == appId || stub.imageId == appId || name.caseInsensitiveCompare(appId) == .orderedSame
    }

    static func embeddedImageId(_ bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/manifest.json")),
              let manifest = try? ImageManifest.decode(data), !manifest.imageId.isEmpty else { return nil }
        return manifest.imageId
    }
}
