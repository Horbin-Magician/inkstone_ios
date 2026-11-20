import Foundation

public struct SyncReport: Sendable {
    public var changed = false
    public var uploaded = 0
    public var downloaded = 0
    public var deleted = 0
    public var conflicts: [String] = []
    var phaseDurations: [String: Duration] = [:]
}
private struct PendingSync: Codable {
    let before: [String: String]
    let target: SyncManifest
    // Optional fields preserve compatibility with journals from earlier releases.
    var plan: SyncPathPlan?
    var removalsComplete: Bool?
    var published: Bool?
    var previousRemote: SyncManifest?
}

private struct SyncPathPlan: Codable {
    let removals: [String]
    let installs: [String]
    init(before: [String: String], target: [String: String]) {
        removals = before.keys.filter { before[$0] != target[$0] }.sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a == b ? $0 < $1 : a > b
        }
        installs = target.keys.filter { before[$0] != target[$0] }.sorted()
    }
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
    /// Batch preparation is not a read lock: every access inside must still use
    /// coordinated(..., coordinator:). Keep default read options so presenters save.
    func coordinatedReadBatch<T>(_ operation: (NSFileCoordinator) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<T, Error>?
        coordinator.prepare(forReadingItemsAt: [root], options: [], writingItemsAt: [], options: [], error: &error) { completed in
            defer { completed() }
            result = Result { try operation(coordinator) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
    private func snapshot(measure: ((String, Duration) -> Void)? = nil) throws -> [String: String] {
        try coordinatedReadBatch { coordinator in
            let clock = ContinuousClock()
            var files: [String: String] = [:]
            let rootPrefix = root.path + "/"
            var scanError: Error?
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
            for case let url as URL in walker {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw VaultError.invalidPath }
                guard values.isRegularFile == true else { continue }
                let pathStart = measure == nil ? nil : clock.now
                // Keep the enumerated lexical path. fileURL checks every existing
                // component for symlinks on each access; resolving here is redundant
                // and could turn a symlink into a seemingly valid target path.
                let absolutePath = url.standardizedFileURL.path
                guard absolutePath.hasPrefix(rootPrefix) else { throw VaultError.invalidPath }
                let path = String(absolutePath.dropFirst(rootPrefix.count))
                let checked = try fileURL(path)
                if let pathStart { measure?("paths", pathStart.duration(to: clock.now)) }
                let readStart = measure == nil ? nil : clock.now
                let hash = try coordinated(checked, writing: false, coordinator: coordinator) { file in
                    let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw VaultError.invalidPath }
                    guard (attributes.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw SyncFailure("单个同步文件超过 128 MiB。") }
                    let hashStart = measure == nil ? nil : clock.now
                    let result = try digestFile(file)
                    if let hashStart { measure?("hash", hashStart.duration(to: clock.now)) }
                    return result
                }
                if let readStart { measure?("coordinatedRead", readStart.duration(to: clock.now)) }
                files[path] = hash
            }
            if let scanError { throw scanError }
            try SyncManifest(files: files).validate()
            return files
        }
    }
    public func synchronize(settings: WebDAVSettings, password: String) async throws -> SyncReport {
        try await synchronize(remote: WebDAV(settings: settings, password: password))
    }
    // The actor remains reentrant during network IO. All user mutations check syncing.
    func synchronize(remote: any SyncRemote, measurePerformance: Bool = false) async throws -> SyncReport {
        let clock = ContinuousClock()
        let started = clock.now
        var phaseStart = started
        var timings: [String: Duration] = [:]
        func mark(_ phase: String) {
            guard measurePerformance else { return }
            let now = clock.now
            timings[phase] = phaseStart.duration(to: now)
            phaseStart = now
        }
        func finish(_ report: SyncReport) -> SyncReport {
            guard measurePerformance else { return report }
            var result = report
            result.phaseDurations = timings
            result.phaseDurations["total"] = started.duration(to: clock.now)
            return result
        }
        try requireIdle(); syncing = true
        defer { syncing = false }
        let state = recovery.appendingPathComponent(".sync/" + digest(Data(remote.identity.utf8)))
        let objects = state.appendingPathComponent("objects")
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        if let stagedEntries = try? fm.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) {
            for entry in stagedEntries where entry.lastPathComponent.hasPrefix(".download-") || entry.lastPathComponent.hasPrefix(".sync-") {
                try? fm.removeItem(at: entry)
            }
        }
        let baseline = state.appendingPathComponent("baseline.json")
        let pending = state.appendingPathComponent("pending.json")
        var report = SyncReport()
        func recordConflict(_ path: String) {
            if !report.conflicts.contains(path) { report.conflicts.append(path) }
        }
        func writeBaseline(from transaction: PendingSync, skipped: Set<String>) throws {
            var nextBaseline = transaction.target
            for path in skipped {
                if let prior = transaction.before[path] { nextBaseline.files[path] = prior }
                else { nextBaseline.files.removeValue(forKey: path) }
            }
            try JSONEncoder().encode(nextBaseline).write(to: baseline, options: .atomic)
        }
        // A confirmed publish can finish after a process interruption without reinterpreting
        // partially applied downloads as local deletions. Concurrent local edits are retained.
        if fm.fileExists(atPath: pending.path) {
            report.changed = true
            var transaction = try JSONDecoder().decode(PendingSync.self, from: Data(contentsOf: pending))
            try transaction.target.validate()
            try SyncManifest(files: transaction.before).validate()
            if transaction.published == false {
                let (observed, _) = try await remote.manifest()
                try observed.validate()
                if observed == transaction.target {
                    transaction.published = true
                    try JSONEncoder().encode(transaction).write(to: pending, options: .atomic)
                } else {
                    // Publication did not produce `target` on remote; local files have not been touched,
                    // so discarding the unpublished journal and running a fresh 3-way merge is safe.
                    try fm.removeItem(at: pending)
                }
            }
            if fm.fileExists(atPath: pending.path) {
                let skipped = try apply(transaction, objects: objects, state: state, report: &report)
                try writeBaseline(from: transaction, skipped: skipped)
                try fm.removeItem(at: pending)
            }
        }
        let hasBaseline = fm.fileExists(atPath: baseline.path)
        let base = hasBaseline ? try SyncManifest.decode(Data(contentsOf: baseline)) : SyncManifest()
        mark("recoveryAndBaseline")
        let local = try snapshot(measure: measurePerformance ? { key, duration in
            timings["scan." + key, default: .zero] += duration
        } : nil)
        mark("scan")
        let (remoteManifest, revision) = try await remote.manifest()
        mark("fetchManifest")
        try remoteManifest.validate()
        guard !hasBaseline || revision != nil else { throw SyncFailure("云端清单已丢失，已停止同步以保护本地数据。") }
        guard remoteManifest.version >= base.version, (remoteManifest.generation ?? 0) >= (base.generation ?? 0) else {
            throw SyncFailure("云端维护代次发生回退，已停止同步。")
        }
        // The local scan already hashed every file. Identical sides always merge
        // to the validated remote manifest, regardless of the previous baseline.
        if revision != nil, local == remoteManifest.files {
            mark("validateAndMerge")
            if !hasBaseline || base != remoteManifest {
                try JSONEncoder().encode(remoteManifest).write(to: baseline, options: .atomic)
            }
            try? fm.removeItem(at: objects)
            mark("finishUnchanged")
            return finish(report)
        }
        let (target, conflicts) = try SyncManifest.merge(base: base.files, local: local, remote: remoteManifest)
        for path in conflicts { recordConflict(path) }
        mark("validateAndMerge")
        report.changed = true
        let pathPlan = SyncPathPlan(before: local, target: target.files)
        try preflight(pathPlan)
        let uploads = Set(target.files.values).subtracting(remoteManifest.files.values)
        let installs = Set(target.files.compactMap { path, hash in local[path] == hash ? nil : hash })
        let needed = uploads.union(installs)
        var localPaths: [String: String] = [:]
        for (path, hash) in local where needed.contains(hash) { localPaths[hash] = path }
        var downloads: [String] = []
        var staging: [(hash: String, path: String)] = []
        for hash in needed.sorted() {
            try Task.checkCancellation()
            let file = objects.appendingPathComponent(hash)
            if fm.fileExists(atPath: file.path), try SyncFile.hash(file) == hash { continue }
            if let path = localPaths[hash] { staging.append((hash, path)) }
            else { downloads.append(hash) }
        }
        func stage(using coordinator: NSFileCoordinator?) throws {
            for (hash, path) in staging {
                try Task.checkCancellation()
                try coordinated(fileURL(path), writing: false, coordinator: coordinator) { source in
                    try SyncFile.copy(source, to: objects.appendingPathComponent(hash), hash: hash, replaceCache: true, mismatchIsConflict: true)
                }
            }
        }
        // Batch only actual local reads. Cached objects and downloads need no
        // library preparation; a single local read keeps normal file coordination.
        if staging.count > 1 {
            try coordinatedReadBatch { try stage(using: $0) }
        } else if !staging.isEmpty {
            try stage(using: nil)
        }
        mark("stageLocal")
        // Bounded workers stage results themselves: completed response bodies do
        // not accumulate in the parent task. Publication waits for every worker.
        // The manifest has no object sizes. Reserve the maximum accepted size
        // per download rather than underestimating unknown responses.
        try await SyncTransfer.run(downloads.map { SyncTransfer(hash: $0, bytes: SyncTransfer.fileLimit) }) { item in
            let destination = objects.appendingPathComponent(item.hash)
            let temporary = objects.appendingPathComponent(".download-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await remote.download(item.hash, to: temporary)
            try SyncFile.promoteVerified(temporary, to: destination, hash: item.hash)
        }
        mark("download")
        report.downloaded += downloads.count
        let needsPublish = revision == nil || target != remoteManifest || !uploads.isEmpty
        if needsPublish {
            try await remote.prepare()
            mark("prepareRemote")
            let uploadItems = try uploads.sorted().map { hash in
                SyncTransfer(hash: hash, bytes: max(1, try SyncFile.size(objects.appendingPathComponent(hash))))
            }
            try await SyncTransfer.run(uploadItems) { item in
                let file = objects.appendingPathComponent(item.hash)
                guard try max(1, SyncFile.size(file)) == item.bytes, try SyncFile.hash(file) == item.hash else { throw SyncFailure("暂存文件校验失败。") }
                try await remote.upload(item.hash, from: file)
            }
            mark("upload")
            report.uploaded += uploads.count
        } else {
            mark("prepareRemote")
            mark("upload")
        }
        guard try snapshot(measure: measurePerformance ? { key, duration in
            timings["revalidateLocal." + key, default: .zero] += duration
        } : nil) == local else { throw VaultError.conflict }
        mark("revalidateLocal")
        try Task.checkCancellation()
        // Persist the complete plan before publication, including an uncertain-response
        // state. No local mutation is allowed until publication is confirmed.
        var transaction = PendingSync(before: local, target: target,
            plan: pathPlan,
            removalsComplete: false, published: !needsPublish, previousRemote: remoteManifest)
        try JSONEncoder().encode(transaction).write(to: pending, options: .atomic)
        if needsPublish {
            do {
                try await remote.publish(target, revision: revision)
            } catch {
                if let failure = error as? SyncFailure, failure.definitePublishRejection {
                    try? fm.removeItem(at: pending)
                }
                throw error
            }
            mark("publish")
            // No cancellation from confirmed publication through local commit.
            transaction.published = true
            try JSONEncoder().encode(transaction).write(to: pending, options: .atomic)
        } else {
            mark("publish")
        }
        let skipped = try apply(transaction, objects: objects, state: state, report: &report)
        try writeBaseline(from: transaction, skipped: skipped)
        try fm.removeItem(at: pending)
        try? fm.removeItem(at: objects)
        mark("commitAndCleanup")
        return finish(report)
    }
    private func preflight(_ plan: SyncPathPlan) throws {
        let removable = Set(plan.removals.map { $0.lowercased() })
        for path in plan.installs {
            let parts = path.split(separator: "/")
            for count in 1...parts.count {
                let prefix = parts.prefix(count).joined(separator: "/")
                let file = try fileURL(prefix)
                guard fm.fileExists(atPath: file.path) else { break }
                let values = try file.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory != true {
                    guard removable.contains(prefix.lowercased()) else { throw VaultError.conflict }
                    break // planned removal makes the remaining suffix available
                }
                if count == parts.count {
                    // A directory becoming a file must contain only planned removals.
                    // Include hidden entries, which ordinary library scans skip.
                    var scanError: Error?
                    guard let walker = fm.enumerator(at: file, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, error in
                        scanError = error; return false
                    }) else { throw CocoaError(.fileReadUnknown) }
                    for case let child as URL in walker {
                        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isSymbolicLink != true else { throw VaultError.invalidPath }
                        if values.isDirectory == true { continue }
                        let relative = prefix + "/" + child.pathComponents.suffix(walker.level).joined(separator: "/")
                        guard removable.contains(relative.lowercased()) else { throw VaultError.conflict }
                    }
                    if let scanError { throw scanError }
                }
            }
        }
    }
    private func removeEmptyDirectoryTree(_ directory: URL) throws {
        var directories: [URL] = []
        var scanError: Error?
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, error in
            scanError = error; return false
        }) else { throw CocoaError(.fileReadUnknown) }
        for case let child as URL in walker {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw VaultError.invalidPath }
            guard values.isDirectory == true else { throw VaultError.conflict }
            directories.append(child)
        }
        if let scanError { throw scanError }
        for sub in directories.reversed() {
            guard try fm.contentsOfDirectory(atPath: sub.path).isEmpty else { throw VaultError.conflict }
            try fm.removeItem(at: sub)
        }
        guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else { throw VaultError.conflict }
        try fm.removeItem(at: directory)
    }
    private func apply(_ transaction: PendingSync, objects: URL, state: URL, report: inout SyncReport) throws -> Set<String> {
        var transaction = transaction
        var skipped: Set<String> = []
        func noteConflict(_ path: String) {
            skipped.insert(path)
            if !report.conflicts.contains(path) { report.conflicts.append(path) }
        }
        let target = transaction.target.files
        let plan = SyncPathPlan(before: transaction.before, target: target)
        // Never trust path lists supplied by a damaged journal.
        if let saved = transaction.plan {
            guard saved.removals == plan.removals, saved.installs == plan.installs else {
                throw SyncFailure("同步恢复计划损坏。")
            }
        }
        // Validate every staged install before the first destructive operation.
        for path in plan.installs {
            let hash = target[path]!
            guard try SyncFile.hash(objects.appendingPathComponent(hash), cancellable: false) == hash else {
                throw SyncFailure("暂存文件校验失败，已保留同步恢复记录。")
            }
        }
        if transaction.removalsComplete != true {
            for path in plan.removals {
                let file = try fileURL(path)
                try coordinated(file, writing: true) { file in
                    guard fm.fileExists(atPath: file.path) else { return }
                    let current = try SyncFile.hash(file, cancellable: false)
                    // Legacy journals may already have installed this target.
                    if current == target[path] { return }
                    guard current == transaction.before[path] else {
                        noteConflict(path)
                        return
                    }
                    let backup = state.appendingPathComponent("backups/" + UUID().uuidString)
                    try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                    try SyncFile.copy(file, to: backup.appendingPathComponent("content"), hash: current, cancellable: false)
                    try Data(path.utf8).write(to: backup.appendingPathComponent("path.txt"), options: .atomic)
                    if path.lowercased().hasSuffix(".md"),
                       (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? Int.max <= 8 * 1024 * 1024,
                       let text = String(data: try Self.bytes(file), encoding: .utf8) {
                        try self.record(RecoveryRecord(path: path, text: text, kind: .syncBefore))
                    }
                    try fm.removeItem(at: file)
                    if target[path] == nil { report.deleted += 1 }
                }
                // Only remove empty parents of removed files. Never recursively delete
                // folders: hidden files and concurrent external edits must survive.
                let rootPrefix = root.path + "/"
                var parent = file.deletingLastPathComponent()
                while parent.path.hasPrefix(rootPrefix) {
                    let checked = try fileURL(String(parent.path.dropFirst(rootPrefix.count)))
                    if !fm.fileExists(atPath: checked.path) { parent.deleteLastPathComponent(); continue }
                    guard try fm.contentsOfDirectory(atPath: checked.path).isEmpty else { break }
                    let removed = try coordinated(checked, writing: true) { folder -> Bool in
                        guard try fm.contentsOfDirectory(atPath: folder.path).isEmpty else { return false }
                        try fm.removeItem(at: folder)
                        return true
                    }
                    if !removed { break }
                    parent.deleteLastPathComponent()
                }
            }
            // This durable barrier prevents a retry from deleting a new file through
            // its old case-insensitive alias after any installs have completed.
            transaction.plan = plan
            transaction.removalsComplete = true
            try JSONEncoder().encode(transaction).write(to: state.appendingPathComponent("pending.json"), options: .atomic)
        }
        for path in plan.installs {
            let file = try fileURL(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinated(file, writing: true) { file in
                if fm.fileExists(atPath: file.path) {
                    let values = try file.resourceValues(forKeys: [.isDirectoryKey])
                    if values.isDirectory == true {
                        try removeEmptyDirectoryTree(file)
                    } else {
                        if try SyncFile.hash(file, cancellable: false) != target[path] { noteConflict(path) }
                        return // retain external edits and already installed content
                    }
                }
                let hash = target[path]!
                try SyncFile.copy(objects.appendingPathComponent(hash), to: file, hash: hash, cancellable: false)
            }
        }
        return skipped
    }
}
