import Foundation

public enum VaultError: LocalizedError {
    case invalidPath, conflict, exists, tooLarge, invalidUTF8, busy
    public var errorDescription: String? {
        switch self {
        case .busy: return "正在同步，请稍后再试。"
        case .invalidPath: return "文件路径无效，或包含库外链接。"
        case .conflict: return "文件已被其他应用修改或删除。当前编辑已保留，请另存副本后重新打开原文。"
        case .exists: return "同名笔记已存在，请更换名称。"
        case .tooLarge: return "移动端暂不支持超过 8 MB 的笔记。"
        case .invalidUTF8: return "笔记不是 UTF-8 编码，无法读取。"
        }
    }
}
public struct RecoveryRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let text: String
    public let date: Date
    public let kind: String
    public init(path: String, text: String, kind: String) {
        id = UUID(); self.path = path; self.text = text; date = Date(); self.kind = kind
    }
}
public struct VaultSnapshot: Sendable {
    public let notes: [Note]
    public let warnings: [String]
    public let folders: [String]
    public let index: NoteIndex
}

/// All IO is serialized off the main actor. Metadata lives outside the shared vault.
public actor Vault {
    public let root: URL
    let recovery: URL
    let fm = FileManager.default
    public init(root: URL, recovery: URL, createIfNeeded: Bool = true) throws {
        if createIfNeeded {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.recovery = recovery
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    }
    private var noteCache: [String: Note] = [:]
    private var cachedIndex = NoteIndex(notes: [])
    var syncing = false
    func requireIdle() throws { if syncing { throw VaultError.busy } }
    func fileURL(_ path: String) throws -> URL {
        try SyncManifest.validatePath(path)
        return try checkedURL(path)
    }
    private func url(_ path: String) throws -> URL {
        guard path.lowercased().hasSuffix(".md") else { throw VaultError.invalidPath }
        return try fileURL(path)
    }
    private func checkedURL(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { throw VaultError.invalidPath }
        // Resolve each existing component: Foundation does not consistently resolve
        // intermediate symlinks when the final file has not been created yet.
        var result = root
        for component in path.split(separator: "/") {
            result.appendPathComponent(String(component))
            if let attributes = try? fm.attributesOfItem(atPath: result.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw VaultError.invalidPath }
        }
        guard result.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw VaultError.invalidPath }
        return result
    }
    private func read(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw VaultError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw VaultError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalidUTF8 }
        return text
    }
    func coordinated<T>(_ url: URL, writing: Bool, _ operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { file in result = Result { try operation(file) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { file in result = Result { try operation(file) } }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
    public func scan() throws -> VaultSnapshot {
        var notes: [Note] = [], warnings: [String] = [], folders: [String] = []
        var nextCache: [String: Note] = [:]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { url, error in
            warnings.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true
        }) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in walker {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                if values.isDirectory == true { folders.append(String(file.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))); continue }
                guard values.isRegularFile == true, file.pathExtension.lowercased() == "md" else { continue }
                let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
                guard canonical.path.hasPrefix(root.path + "/") else { throw VaultError.invalidPath }
                let path = String(canonical.path.dropFirst(root.path.count + 1))
                let checked = try url(path)
                let text = try coordinated(checked, writing: false) { try read($0) }
                let modified = values.contentModificationDate ?? .distantPast
                // Read external content on every scan, but reuse derived data for
                // unchanged notes, including edits that preserve timestamps.
                let note: Note
                if let cached = noteCache[path], cached.modified == modified, cached.text == text { note = cached }
                else { note = Note(path: path, text: text, modified: modified) }
                nextCache[path] = note
                notes.append(note)
            } catch { warnings.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
        }
        notes.sort { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
        if nextCache != noteCache { cachedIndex = NoteIndex(notes: notes) }
        noteCache = nextCache
        return VaultSnapshot(notes: notes, warnings: warnings, folders: folders.sorted(), index: cachedIndex)
    }
    public func importFile(_ source: URL) throws -> Note {
        try requireIdle()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let text = try coordinated(source, writing: false) { try read($0) }
        return try create(path: source.deletingPathExtension().lastPathComponent + ".md", text: text)
    }
    public func create(path: String, text: String) throws -> Note {
        try requireIdle()
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw VaultError.tooLarge }
        let target = try url(path)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(target, writing: true) { file in
            guard !fm.fileExists(atPath: file.path) else { throw VaultError.exists }
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        }
        return Note(path: path, text: text)
    }
    public func save(path: String, text: String, expected: String) throws -> Note {
        try requireIdle()
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw VaultError.tooLarge }
        let target = try url(path)
        try coordinated(target, writing: true) { file in
            guard fm.fileExists(atPath: file.path), try read(file) == expected else { throw VaultError.conflict }
            if text != expected {
                try record(RecoveryRecord(path: path, text: expected, kind: "历史版本"))
                try Data(text.utf8).write(to: file, options: .atomic)
            }
        }
        try clearDraft(path: path)
        return Note(path: path, text: text)
    }
    public func trash(path: String, expected: String) throws {
        try requireIdle()
        let target = try url(path)
        try coordinated(target, writing: true) { file in
            guard fm.fileExists(atPath: file.path), try read(file) == expected else { throw VaultError.conflict }
            try record(RecoveryRecord(path: path, text: expected, kind: "已删除"))
            try fm.removeItem(at: file)
        }
        try clearDraft(path: path)
    }
    public func createFolder(path: String) throws {
        try requireIdle()
        let target = try fileURL(path)
        guard !fm.fileExists(atPath: target.path) else { throw VaultError.exists }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
    }
    public func move(path: String, to destination: String) throws {
        try requireIdle()
        let source = try fileURL(path), target = try fileURL(destination)
        guard !destination.lowercased().hasPrefix(path.lowercased() + "/") else { throw VaultError.invalidPath }
        guard !fm.fileExists(atPath: target.path) else { throw VaultError.exists }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(source, writing: true) { source in
            try fm.moveItem(at: source, to: target)
        }
    }
    private func record(_ entry: RecoveryRecord) throws {
        let data = try JSONEncoder().encode(entry)
        try data.write(to: recovery.appendingPathComponent(entry.id.uuidString + ".json"), options: .atomic)
    }
    private func draftURL(_ path: String) -> URL {
        let name = Data(path.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        // Paths can exceed filesystem component limits; a stable UUID-shaped digest is unnecessary here.
        // Split the encoded path into directory components to preserve a reversible, collision-free key.
        let chunks = stride(from: 0, to: name.count, by: 100).map { offset -> String in
            String(name.dropFirst(offset).prefix(100))
        }
        return chunks.reduce(recovery.appendingPathComponent("drafts")) { $0.appendingPathComponent($1) }.appendingPathExtension("json")
    }
    public func writeDraft(path: String, text: String) throws {
        _ = try url(path)
        let target = draftURL(path)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(RecoveryRecord(path: path, text: text, kind: "恢复草稿")).write(to: target, options: .atomic)
    }
    public func clearDraft(path: String) throws {
        let target = draftURL(path)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    }
    public func records(path: String? = nil) throws -> [RecoveryRecord] {
        guard let walker = fm.enumerator(at: recovery, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var records: [RecoveryRecord] = []
        for case let file as URL in walker where file.pathExtension == "json" {
            let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: file))
            if path == nil || record.path == path { records.append(record) }
        }
        return records.sorted { $0.date > $1.date }
    }
    public func restoreCopy(_ record: RecoveryRecord) throws -> Note {
        let stem = (record.path as NSString).deletingPathExtension
        return try create(path: stem + "-恢复-" + UUID().uuidString.prefix(8) + ".md", text: record.text)
    }
}
