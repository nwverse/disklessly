import Foundation

/// The active repo plus its mirrors (`mirrorBackendIds`).
///
/// Writes, deletes, and `ensureCollection` go to the primary only; mirrors are filled
/// by `syncMirrors`. Reads fail over:
/// - `get`, `getResumable`, and `download` try each mirror in order when the primary
///   errors, which includes an object the primary does not have.
/// - `list`, `entries`, and `stat` fail over only when the primary errors. A primary that
///   answers "not there" is believed, so publish dedupe never skips an upload because a
///   mirror still holds an old copy.
///
/// Mirrors are opened lazily (an SMB mirror is mounted only when a read needs it). A
/// mirror that cannot be opened is skipped.
public final class FailoverBackend: StorageBackend {
    public typealias Opener = () throws -> any StorageBackend

    public let primary: any StorageBackend
    public let mirrorIds: [String]
    private let openers: [Opener]
    private var opened: [Int: any StorageBackend] = [:]
    private var unavailable: Set<Int> = []
    private let lock = NSLock()
    /// Id of the mirror that served the last failed-over read; nil when the primary did.
    public private(set) var lastServedBy: String?

    public init(primary: any StorageBackend, mirrors: [(id: String, open: Opener)]) {
        self.primary = primary
        self.mirrorIds = mirrors.map(\.id)
        self.openers = mirrors.map(\.open)
    }

    private func mirror(_ index: Int) -> (any StorageBackend)? {
        lock.lock(); defer { lock.unlock() }
        if let backend = opened[index] { return backend }
        if unavailable.contains(index) { return nil }
        do {
            let backend = try openers[index]()
            opened[index] = backend
            return backend
        } catch {
            unavailable.insert(index)
            return nil
        }
    }

    private func served(_ id: String?) {
        lock.lock(); lastServedBy = id; lock.unlock()
    }

    /// Runs `body` on the primary, then on each mirror until one succeeds. Throws the primary's error.
    private func read<T>(_ body: (any StorageBackend) throws -> T) throws -> T {
        do {
            let value = try body(primary)
            served(nil)
            return value
        } catch {
            for index in openers.indices {
                guard let backend = mirror(index) else { continue }
                if let value = try? body(backend) {
                    served(mirrorIds[index])
                    return value
                }
            }
            throw error
        }
    }

    public func list(_ path: String) throws -> [String] { try read { try $0.list(path) } }
    public func entries(_ path: String) throws -> [BackendEntry] { try read { try $0.entries(path) } }
    public func stat(_ path: String) throws -> BackendStat? { try read { try $0.stat(path) } }
    public func get(_ path: String, range: Range<UInt64>?) throws -> Data { try read { try $0.get(path, range: range) } }
    public func getResumable(_ path: String, offset: UInt64) throws -> ResumableBody { try read { try $0.getResumable(path, offset: offset) } }
    public func download(_ path: String, to destination: URL, offset: UInt64) throws -> ResumableFile {
        try read { try $0.download(path, to: destination, offset: offset) }
    }

    public func put(_ path: String, data: Data) throws { try primary.put(path, data: data) }
    public func put(_ path: String, file: URL) throws { try primary.put(path, file: file) }
    public func delete(_ path: String) throws { try primary.delete(path) }
    public func putStream(_ path: String, from producer: (FileHandle) throws -> Void) throws { try primary.putStream(path, from: producer) }
    public func move(_ from: String, to: String) throws { try primary.move(from, to: to) }
    public func localRoot() -> URL? { primary.localRoot() }
    public func ensureCollection(_ path: String) throws { try primary.ensureCollection(path) }
}
