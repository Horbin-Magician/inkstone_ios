import Foundation

struct SyncTransfer: Sendable {
    let hash: String
    let bytes: Int
    static let fileLimit = 128 * 1024 * 1024
    static let byteBudget = 256 * 1024 * 1024

    static func run(_ items: [Self], taskLimit: Int = 3, byteBudget: Int = byteBudget,
                    operation: @escaping @Sendable (Self) async throws -> Void) async throws {
        guard taskLimit > 0, items.allSatisfy({ $0.bytes > 0 && $0.bytes <= byteBudget }) else {
            throw SyncFailure("同步传输超出并发字节预算。")
        }
        try await withThrowingTaskGroup(of: Int.self) { group in
            var next = 0, active = 0, bytes = 0
            while next < items.count || active > 0 {
                try Task.checkCancellation()
                while next < items.count && active < taskLimit && bytes + items[next].bytes <= byteBudget {
                    let item = items[next]
                    next += 1; active += 1; bytes += item.bytes
                    group.addTask { try Task.checkCancellation(); try await operation(item); return item.bytes }
                }
                if let completed = try await group.next() { active -= 1; bytes -= completed }
            }
        }
    }
}

enum SyncFile {
    static func size(_ url: URL) throws -> Int {
        // URL resource values can survive external rewrites of the same path.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VaultError.invalidPath }
        let count = values.fileSize ?? 0
        guard count <= SyncTransfer.fileLimit else { throw SyncFailure("单个同步文件超过 128 MiB。") }
        return count
    }
    static func hash(_ url: URL, cancellable: Bool = true) throws -> String {
        _ = try size(url)
        return try digestFile(url, cancellable: cancellable)
    }
    /// Copy to a sibling temporary file, verify all bytes, then expose the complete
    /// file. Public destinations never replace a concurrent external creation.
    static func copy(_ source: URL, to destination: URL, hash: String, replaceCache: Bool = false, cancellable: Bool = true, mismatchIsConflict: Bool = false) throws {
        let fm = FileManager.default
        _ = try size(source)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".sync-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        guard try Self.hash(temporary, cancellable: cancellable) == hash else {
            if mismatchIsConflict { throw VaultError.conflict }
            throw SyncFailure("同步文件校验失败。")
        }
        if replaceCache, fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
    }
}
