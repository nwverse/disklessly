import Foundation

public struct CacheItem: Equatable {
    public var imageId: String
    public var bytes: UInt64
    public var lastUsed: Date?
    public var pinned: Bool
    public var mounted: Bool
    public var inUse: Bool
    public var protectedUntil: Date?
    public var needsResolution: Bool
    public var justUsed: Bool

    public init(imageId: String, bytes: UInt64, lastUsed: Date?, pinned: Bool, mounted: Bool, inUse: Bool, protectedUntil: Date?, needsResolution: Bool, justUsed: Bool) {
        self.imageId = imageId
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.pinned = pinned
        self.mounted = mounted
        self.inUse = inUse
        self.protectedUntil = protectedUntil
        self.needsResolution = needsResolution
        self.justUsed = justUsed
    }
}

public struct EvictionPlan: Equatable {
    public var victims: [String]
    public var freed: UInt64
    public var shortBy: UInt64
    public var skipped: [String: String]

    public init(victims: [String], freed: UInt64, shortBy: UInt64, skipped: [String: String]) {
        self.victims = victims
        self.freed = freed
        self.shortBy = shortBy
        self.skipped = skipped
    }
}

public enum CachePlanner {
    public static func planEviction(_ items: [CacheItem], leftovers: [(path: String, bytes: UInt64)], quota: UInt64, now: Date) -> EvictionPlan {
        let itemBytes = items.reduce(UInt64(0)) { $0 + $1.bytes }
        let leftoverBytes = leftovers.reduce(UInt64(0)) { $0 + $1.bytes }
        let used = itemBytes + leftoverBytes
        if used <= quota {
            return EvictionPlan(victims: [], freed: 0, shortBy: 0, skipped: [:])
        }
        var victims: [String] = []
        var freed: UInt64 = 0
        var remaining = used
        var skipped: [String: String] = [:]
        for item in items {
            if item.pinned { skipped[item.imageId] = "pinned" }
            else if item.mounted { skipped[item.imageId] = "mounted" }
            else if item.inUse { skipped[item.imageId] = "inUse" }
            else if let until = item.protectedUntil, until > now { skipped[item.imageId] = "protectedUntil" }
            else if item.needsResolution { skipped[item.imageId] = "needsResolution" }
        }
        for left in leftovers {
            victims.append(left.path)
            freed += left.bytes
            remaining = remaining >= left.bytes ? remaining - left.bytes : 0
            if remaining <= quota { break }
        }
        let eligible = items.filter { skipped[$0.imageId] == nil }
        let ordered = eligible.filter { !$0.justUsed }.sorted { lhs, rhs in
            let left = lhs.lastUsed ?? .distantPast
            let right = rhs.lastUsed ?? .distantPast
            if left != right { return left < right }
            return lhs.imageId < rhs.imageId
        }
        let justUsed = eligible.filter(\.justUsed).sorted { $0.imageId < $1.imageId }
        for item in ordered where remaining > quota {
            victims.append(item.imageId)
            freed += item.bytes
            remaining = remaining >= item.bytes ? remaining - item.bytes : 0
        }
        for item in justUsed where remaining > quota {
            if item.bytes > quota {
                skipped[item.imageId] = "alone exceeds quota"
                continue
            }
            victims.append(item.imageId)
            freed += item.bytes
            remaining = remaining >= item.bytes ? remaining - item.bytes : 0
        }
        let shortBy = remaining > quota ? remaining - quota : 0
        return EvictionPlan(victims: victims, freed: freed, shortBy: shortBy, skipped: skipped)
    }
}
