import Foundation

public enum RecoveryStorageCategory: String, CaseIterable, Sendable {
    case history = "正文历史", syncBackup = "同步文件备份", deletedFolder = "已删除文件夹", staging = "同步暂存"
}
public struct RecoveryStorageItem: Identifiable, Sendable {
    public let id: String
    public let category: RecoveryStorageCategory
    public let path: String
    public let bytes: Int64
    public let date: Date
    public let protected: Bool
    public let canRestore: Bool
}

extension Vault {
    /// Private recovery paths must stay inside the recovery root and never follow links.
    private func storageURL(_ relative: String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw VaultError.invalidPath }
        var file = recovery
        for part in relative.split(separator: "/") {
            file.appendPathComponent(String(part))
            if fm.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw VaultError.invalidPath }
        }
        return file
    }
    private func storageSize(_ file: URL) throws -> Int64 {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw VaultError.invalidPath }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0, scanError: Error?
        guard let walker = fm.enumerator(at: file, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let child as URL in walker {
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw VaultError.invalidPath }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        if let scanError { throw scanError }
        return total
    }
    public func recoveryStorage() throws -> [RecoveryStorageItem] {
        var items: [RecoveryStorageItem] = []
        func append(_ id: String, category: RecoveryStorageCategory, path: String, protected: Bool, recoverable: Bool = true) throws {
            let file = try storageURL(id)
            let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            items.append(RecoveryStorageItem(id: id, category: category, path: path, bytes: try storageSize(file), date: date, protected: protected, canRestore: recoverable && (category == .syncBackup || category == .deletedFolder)))
        }
        for summary in try recoverySummaries() {
            try append(summary.file, category: .history, path: summary.path + " · " + summary.kind.rawValue, protected: summary.kind == .draft)
        }
        let sync = try storageURL(".sync")
        if fm.fileExists(atPath: sync.path) {
            for endpoint in try fm.contentsOfDirectory(atPath: sync.path).sorted() {
                let relative = ".sync/" + endpoint
                let state = try storageURL(relative)
                guard try state.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                let protected = fm.fileExists(atPath: state.appendingPathComponent("pending.json").path)
                let backups = try storageURL(relative + "/backups")
                if fm.fileExists(atPath: backups.path) {
                    for name in try fm.contentsOfDirectory(atPath: backups.path).sorted() {
                        let id = relative + "/backups/" + name
                        let pathFile = try storageURL(id + "/path.txt")
                        let path = try? String(contentsOf: pathFile, encoding: .utf8)
                        let validPath = path.flatMap { value -> String? in
                            (try? SyncManifest.validatePath(value)) != nil ? value : nil
                        }
                        let content = try storageURL(id + "/content")
                        let complete = validPath != nil && fm.fileExists(atPath: content.path)
                        try append(id, category: .syncBackup, path: validPath ?? "未完成的备份", protected: protected, recoverable: complete)
                    }
                }
                let objects = try storageURL(relative + "/objects")
                if fm.fileExists(atPath: objects.path) {
                    try append(relative + "/objects", category: .staging, path: "已校验的传输缓存", protected: protected)
                }
            }
        }
        let deleted = try storageURL(".deleted-folders")
        if fm.fileExists(atPath: deleted.path) {
            for name in try fm.contentsOfDirectory(atPath: deleted.path).sorted() {
                let file = try storageURL(".deleted-folders/" + name)
                let children = try fm.contentsOfDirectory(atPath: file.path).sorted().joined(separator: "、")
                try append(".deleted-folders/" + name, category: .deletedFolder, path: children, protected: false)
            }
        }
        return items.sorted { $0.date > $1.date }
    }
    public func removeRecoveryStorage(_ id: String) throws {
        try requireIdle()
        // Re-read protection at execution time: stale UI metadata is never authority.
        guard let item = try recoveryStorage().first(where: { $0.id == id }), !item.protected else { throw VaultError.busy }
        let file = try storageURL(id)
        if item.category == .history {
            let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: file))
            try fm.removeItem(at: file)
            removeCatalogRecord(record)
        } else { try fm.removeItem(at: file) }
    }
    /// Restore into a fresh folder so no existing note or attachment can be replaced.
    public func restoreRecoveryStorage(_ id: String) throws -> String {
        try requireIdle()
        guard let item = try recoveryStorage().first(where: { $0.id == id }), item.canRestore else { throw VaultError.invalidPath }
        let folder = "恢复文件-" + UUID().uuidString
        let source = try storageURL(id)
        let destination = try fileURL(folder)
        guard !fm.fileExists(atPath: destination.path) else { throw VaultError.exists }
        if item.category == .deletedFolder {
            _ = try storageSize(source) // validate the entire tree before copying
            try coordinated(destination, writing: true) { try fm.copyItem(at: source, to: $0) }
        } else {
            let content = try storageURL(id + "/content")
            let target = try fileURL(folder + "/" + item.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try coordinated(target, writing: true) { try fm.copyItem(at: content, to: $0) }
        }
        return folder
    }
}
