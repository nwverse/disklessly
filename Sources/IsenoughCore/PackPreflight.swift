import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct SpaceVerdict: Equatable {
    public var need: UInt64
    public var appAllocated: UInt64
    public var imageEstimate: UInt64
    public var staging: UInt64
    public var repoCopy: UInt64
    public var error: IsenoughError?

    public init(need: UInt64, appAllocated: UInt64, imageEstimate: UInt64, staging: UInt64, repoCopy: UInt64, error: IsenoughError?) {
        self.need = need
        self.appAllocated = appAllocated
        self.imageEstimate = imageEstimate
        self.staging = staging
        self.repoCopy = repoCopy
        self.error = error
    }
}

public enum AllocatedSize {
    /// Sum of `st_blocks * 512` for regular files. Symlinks are not followed.
    public static func tree(_ url: URL) -> UInt64 {
        var total: UInt64 = 0
        var pending = [url]
        while let current = pending.popLast() {
            var info = stat()
            guard lstat(current.path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFREG {
                let blocks = info.st_blocks < 0 ? 0 : UInt64(info.st_blocks)
                total += blocks * 512
            } else if kind == S_IFDIR {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
                for name in names {
                    pending.append(current.appendingPathComponent(name))
                }
            }
        }
        return total
    }
}

public enum PackPreflight {
    public static func running(_ usage: UsageClass, name: String = "the app") -> IsenoughError? {
        switch usage {
        case .clean:
            return nil
        case .unknown:
            return .busy("cannot tell whether \(name) is running; nothing was changed")
        case .busy, .held:
            return .busy("\(name) is running; quit it before pack")
        }
    }

    /// `repoOnSameVolume` is true only when the repo is a local directory on the cache volume.
    public static func space(appAllocated: UInt64, free: UInt64, cloneSupported: Bool, repoOnSameVolume: Bool, minFree: UInt64, volume: String = "the cache volume") -> SpaceVerdict {
        let stagingCopy: UInt64 = cloneSupported ? 0 : appAllocated
        let image = appAllocated + appAllocated / 20 + 16 * 1024 * 1024
        let checked = appAllocated
        let repoCopy: UInt64 = repoOnSameVolume ? image : 0
        let need = stagingCopy + image + checked + repoCopy + minFree
        let error: IsenoughError?
        if free < need {
            error = .noSpace("pack needs \(need) bytes free on \(volume) (app \(appAllocated), image ≈\(image), staging \(stagingCopy + checked), repo copy \(repoCopy), floor \(minFree)); available \(free)")
        } else {
            error = nil
        }
        return SpaceVerdict(need: need, appAllocated: appAllocated, imageEstimate: image, staging: stagingCopy + checked, repoCopy: repoCopy, error: error)
    }

    public static func deviceID(_ path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_dev)
    }
}
