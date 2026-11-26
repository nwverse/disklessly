import Foundation

/// Runs `body` in an autorelease pool on Darwin, where streaming reads such as
/// `FileHandle.read(upToCount:)` return autoreleased buffers that a long loop on a background
/// thread would otherwise keep until the loop ends. Linux Foundation has no autorelease pools,
/// so there it just runs `body`.
@inline(__always)
public func drainingPool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}
