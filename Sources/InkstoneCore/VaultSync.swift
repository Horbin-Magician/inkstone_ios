import Foundation

public struct SyncReport: Sendable {
    public var uploaded = 0
    public var downloaded = 0
    public var deleted = 0
    public var conflicts: [String] = []
}
private struct PendingSync: Codable {
    let before: [String: String]
    let target: SyncManifest
}
extension Vault {
    private nonisolated static func bytes(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VaultError.invalidPath }
        guard (values.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw SyncFailure("单个同步文件超过 128 MiB。") }
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 * 1024 else { throw SyncFailure("单个同步文件超过 128 MiB。") }
        return data
    }
    private func snapshot() throws -> [String: String] {
        var files: [String: String] = [:]
        var scanError: Error?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in walker {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw VaultError.invalidPath }
            guard values.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            let checked = try fileURL(path)
            let data = try coordinated(checked, writing: false) { try Self.bytes($0) }
            let hash = digest(data)
            files[path] = hash
        }
        if let scanError { throw scanError }
        try SyncManifest(files: files).validate()
        return files
    }
    public func synchronize(settings: WebDAVSettings, password: String) async throws -> SyncReport {
        try await synchronize(remote: WebDAV(settings: settings, password: password))
    }
    // The actor remains reentrant during network IO. All user mutations check syncing.
    func synchronize(remote: any SyncRemote) async throws -> SyncReport {
        try requireIdle(); syncing = true
        defer { syncing = false }
        let state = recovery.appendingPathComponent(".sync/" + digest(Data(remote.identity.utf8)))
        let objects = state.appendingPathComponent("objects")
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        let baseline = state.appendingPathComponent("baseline.json")
        let pending = state.appendingPathComponent("pending.json")
        var report = SyncReport()
        // A confirmed publish can finish after a process interruption without reinterpreting
        // partially applied downloads as local deletions. Concurrent local edits are retained.
        if fm.fileExists(atPath: pending.path) {
            let transaction = try JSONDecoder().decode(PendingSync.self, from: Data(contentsOf: pending))
            try transaction.target.validate()
            try apply(transaction, objects: objects, state: state, report: &report)
            try JSONEncoder().encode(transaction.target).write(to: baseline, options: .atomic)
            try fm.removeItem(at: pending)
        }
        let hasBaseline = fm.fileExists(atPath: baseline.path)
        let base = hasBaseline ? try SyncManifest.decode(Data(contentsOf: baseline)) : SyncManifest()
        let local = try snapshot()
        let (remoteManifest, revision) = try await remote.manifest()
        try remoteManifest.validate()
        guard !hasBaseline || revision != nil else { throw SyncFailure("云端清单已丢失，已停止同步以保护本地数据。") }
        guard remoteManifest.version >= base.version, (remoteManifest.generation ?? 0) >= (base.generation ?? 0) else {
            throw SyncFailure("云端维护代次发生回退，已停止同步。")
        }
        let (target, conflicts) = try SyncManifest.merge(base: base.files, local: local, remote: remoteManifest)
        report.conflicts = conflicts
        // A no-change sync still reads and hashes local content, but needs no
        // staging, collection creation, or remote manifest publication.
        if revision != nil, local == target.files && target == remoteManifest {
            try JSONEncoder().encode(target).write(to: baseline, options: .atomic)
            try? fm.removeItem(at: objects)
            return report
        }
        let uploads = Set(target.files.values).subtracting(remoteManifest.files.values)
        let installs = Set(target.files.compactMap { path, hash in local[path] == hash ? nil : hash })
        let needed = uploads.union(installs)
        var localPaths: [String: String] = [:]
        for (path, hash) in local where needed.contains(hash) { localPaths[hash] = path }
        var downloads: [String] = []
        for hash in needed.sorted() {
            try Task.checkCancellation()
            let file = objects.appendingPathComponent(hash)
            if fm.fileExists(atPath: file.path), try digest(Self.bytes(file)) == hash { continue }
            if let path = localPaths[hash] {
                let data = try coordinated(fileURL(path), writing: false) { try Self.bytes($0) }
                guard digest(data) == hash else { throw VaultError.conflict }
                try data.write(to: file, options: .atomic)
            } else { downloads.append(hash) }
        }
        // Bounded workers stage results themselves: completed response bodies do
        // not accumulate in the parent task. Publication waits for every worker.
        try await Self.transfer(downloads) { hash in
            let data = try await remote.download(hash)
            guard data.count <= 128 * 1024 * 1024, digest(data) == hash else { throw SyncFailure("云端文件校验失败。") }
            try data.write(to: objects.appendingPathComponent(hash), options: .atomic)
        }
        report.downloaded += downloads.count
        try await remote.prepare()
        try await Self.transfer(uploads.sorted()) { hash in
            let data = try Self.bytes(objects.appendingPathComponent(hash))
            guard digest(data) == hash else { throw SyncFailure("暂存文件校验失败。") }
            try await remote.upload(hash, data: data)
        }
        report.uploaded += uploads.count
        guard try snapshot() == local else { throw VaultError.conflict }
        try Task.checkCancellation()
        try await remote.publish(target, revision: revision)
        // No cancellation from confirmed publication through local commit.
        let transaction = PendingSync(before: local, target: target)
        try JSONEncoder().encode(transaction).write(to: pending, options: .atomic)
        try apply(transaction, objects: objects, state: state, report: &report)
        try JSONEncoder().encode(target).write(to: baseline, options: .atomic)
        try fm.removeItem(at: pending)
        try? fm.removeItem(at: objects)
        return report
    }
    private nonisolated static func transfer(_ hashes: [String], operation: @escaping @Sendable (String) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var remaining = hashes.makeIterator()
            for _ in 0..<3 {
                if let hash = remaining.next() { group.addTask { try Task.checkCancellation(); try await operation(hash) } }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if let hash = remaining.next() { group.addTask { try Task.checkCancellation(); try await operation(hash) } }
            }
        }
    }
    private func apply(_ transaction: PendingSync, objects: URL, state: URL, report: inout SyncReport) throws {
        let target = transaction.target.files
        for path in Set(transaction.before.keys).union(target.keys).sorted() where transaction.before[path] != target[path] {
            let file = try fileURL(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinated(file, writing: true) { file in
                let old = fm.fileExists(atPath: file.path) ? try Self.bytes(file) : nil
                let current = old.map(digest)
                if current == target[path] { return }
                // A file edited since scanning (or since a crash) is preserved and becomes
                // a local change against the newly committed baseline on the next sync.
                guard current == transaction.before[path] else {
                    report.conflicts.append(path)
                    return
                }
                if let old {
                    let backup = state.appendingPathComponent("backups/" + UUID().uuidString)
                    try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                    try old.write(to: backup.appendingPathComponent("content"), options: .atomic)
                    try Data(path.utf8).write(to: backup.appendingPathComponent("path.txt"), options: .atomic)
                    if path.lowercased().hasSuffix(".md"), let text = String(data: old, encoding: .utf8) {
                        let record = RecoveryRecord(path: path, text: text, kind: "同步前版本")
                        try JSONEncoder().encode(record).write(to: recovery.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
                    }
                }
                if let hash = target[path] {
                    let data = try Self.bytes(objects.appendingPathComponent(hash))
                    guard digest(data) == hash else { throw SyncFailure("暂存文件校验失败，已保留同步恢复记录。") }
                    try data.write(to: file, options: .atomic)
                } else if old != nil {
                    try fm.removeItem(at: file)
                    report.deleted += 1
                }
            }
        }
    }
}
