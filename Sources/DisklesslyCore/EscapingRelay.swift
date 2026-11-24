import Foundation

/// Hands a non-escaping progress callback to work that runs on GCD queues.
///
/// `withoutActuallyEscaping` traps ("closure argument was escaped") when anything still holds the
/// closure as its block ends. A `DispatchQueue.async` block is released a moment *after* it calls
/// `group.leave()`, so code that waits on a group and then returns can still trip the check. Here
/// the escaping wrapper only holds a relay, and the relay drops the real closure before the
/// `withoutActuallyEscaping` block ends, however long the queues keep the wrapper alive.
public func withEscapableBytes<R>(_ onBytes: (UInt64, UInt64) -> Void, _ body: (@escaping (UInt64, UInt64) -> Void) throws -> R) rethrows -> R {
    try withoutActuallyEscaping(onBytes) { escaped in
        let relay = ClosureRelay(escaped)
        defer { relay.clear() }
        return try body { done, total in relay.current?(done, total) }
    }
}

/// The same for a throwing producer that writes into a pipe from another thread.
public func withEscapableProducer<R>(_ producer: (FileHandle) throws -> Void, _ body: (@escaping (FileHandle) throws -> Void) throws -> R) rethrows -> R {
    try withoutActuallyEscaping(producer) { escaped in
        let relay = ClosureRelay(escaped)
        defer { relay.clear() }
        return try body { handle in
            guard let current = relay.current else { throw DisklesslyError.failure("the upload producer was called after its upload ended") }
            try current(handle)
        }
    }
}

final class ClosureRelay<Fn>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Fn?
    init(_ fn: Fn) { stored = fn }
    var current: Fn? { lock.lock(); defer { lock.unlock() }; return stored }
    func clear() { lock.lock(); stored = nil; lock.unlock() }
}
