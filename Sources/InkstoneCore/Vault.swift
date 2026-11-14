import Foundation
import Darwin

public enum VaultError: LocalizedError {
    case invalidPath, conflict, exists, tooLarge, attachmentTooLarge, backupTooLarge, invalidUTF8, busy, editorOpen
    public var errorDescription: String? {
        switch self {
        case .editorOpen: return "请先关闭正在打开的笔记，再切换笔记库或移动文件。"
        case .busy: return "正在同步，请稍后再试。"
        case .invalidPath: return "文件路径无效，或包含库外链接。"
        case .conflict: return "文件已被其他应用修改或删除。当前编辑已保留，请另存副本后重新打开原文。"
        case .exists: return "同名笔记已存在，请更换名称。"
        case .attachmentTooLarge: return "单个附件不能超过 32 MB。"
        case .backupTooLarge: return "整库导出支持总计 128 MB、少于 65,535 个条目的笔记库。请通过文件应用或桌面端备份更大的库。"
        case .tooLarge: return "移动端暂不支持超过 8 MB 的笔记。"
        case .invalidUTF8: return "笔记不是 UTF-8 编码，无法读取。"
        }
    }
}
public struct RecoveryRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let text: String
    public let date: Date
    public let kind: RecoveryKind
    public let baseText: String?
    public let isNew: Bool?
    public init(path: String, text: String, kind: RecoveryKind, baseText: String? = nil, isNew: Bool? = nil) {
        id = UUID(); self.path = path; self.text = text; date = Date(); self.kind = kind; self.baseText = baseText; self.isNew = isNew
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
    private var startupCacheDirty = true
    private let startupCacheURL: URL?
    let fm = FileManager.default
    public init(root: URL, recovery: URL, createIfNeeded: Bool = true, startupCache: URL? = nil) throws {
        if createIfNeeded {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.recovery = recovery.standardizedFileURL.resolvingSymlinksInPath()
        self.startupCacheURL = startupCache
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    }
    private var noteCache: [String: Note] = [:]
    private var cachedIndex = NoteIndex(notes: [])
    private var cachedFolders: [String] = []
    private var cachedNotes: [Note] = []
    private var cachedWarnings: [String] = []
    // Only explicit editor sessions coalesce history; other callers keep every version.
    private var historyCheckpoint: (path: String, session: UUID, date: Date, text: String)?
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
        let rootPath = root.path
        var candidate = rootPath
        for component in path.split(separator: "/") {
            candidate += "/" + component
            // Only file type is needed. lstat avoids allocating Foundation's full
            // attributes dictionary and never follows the final component's link.
            var attributes = stat()
            let (status, code) = candidate.withCString { pointer in
                let status = lstat(pointer, &attributes)
                return (status, errno)
            }
            if status == 0 {
                if attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) { throw VaultError.invalidPath }
            } else {
                // New files and parent directories may not exist yet. All other
                // inspection errors fail closed rather than skipping the check.
                if code != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            }
        }
        let result = URL(fileURLWithPath: candidate)
        guard result.standardizedFileURL.path.hasPrefix(rootPath + "/") else { throw VaultError.invalidPath }
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
    func coordinated<T>(_ url: URL, writing: Bool, coordinator: NSFileCoordinator? = nil, _ operation: (URL) throws -> T) throws -> T {
        let coordinator = coordinator ?? NSFileCoordinator()
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
    private struct StartupCache: Codable {
        let version: Int
        let root: String
        let notes: [Note]
        let folders: [String]
    }
    /// Presentation only: callers must reconcile with scan before opening cached notes.
    /// Decode stored derived fields directly, without reparsing every Markdown body.
    public func cachedSnapshot() -> VaultSnapshot? {
        guard let startupCacheURL,
              let size = try? startupCacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 64 * 1024 * 1024,
              let data = try? Data(contentsOf: startupCacheURL),
              let cache = try? PropertyListDecoder().decode(StartupCache.self, from: data),
              cache.version == 1, cache.root == root.path,
              Set(cache.notes.map(\.path)).count == cache.notes.count,
              cache.notes.allSatisfy({ (try? SyncManifest.validatePath($0.path)) != nil && $0.path.lowercased().hasSuffix(".md") }) else { return nil }
        startupCacheDirty = false
        noteCache = Dictionary(uniqueKeysWithValues: cache.notes.map { ($0.path, $0) })
        cachedNotes = cache.notes
        cachedFolders = cache.folders
        cachedWarnings = []
        cachedIndex = NoteIndex(notes: cachedNotes)
        return VaultSnapshot(notes: cachedNotes, warnings: [], folders: cachedFolders, index: cachedIndex)
    }
    private func persistStartupCache() {
        guard startupCacheDirty, let startupCacheURL else { return }
        // Bound this optional optimization; a large library still works without it.
        guard cachedNotes.reduce(0, { $0 + $1.text.utf8.count }) <= 32 * 1024 * 1024 else {
            try? fm.removeItem(at: startupCacheURL)
            return
        }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(StartupCache(version: 1, root: root.path, notes: cachedNotes, folders: cachedFolders))
            guard data.count <= 64 * 1024 * 1024 else { try? fm.removeItem(at: startupCacheURL); return }
            try fm.createDirectory(at: startupCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: startupCacheURL, options: .atomic)
            startupCacheDirty = false
        } catch {
            // A cache must never prevent opening or saving the actual Markdown files.
            try? fm.removeItem(at: startupCacheURL)
        }
    }
    public func scan() throws -> VaultSnapshot {
        let previousFolders = cachedFolders
        let (snapshot, notesChanged) = try coordinatedReadBatch { coordinator in
            try scan(coordinator: coordinator)
        }
        if notesChanged || previousFolders != snapshot.folders { startupCacheDirty = true }
        persistStartupCache()
        return snapshot
    }
    private func scan(coordinator: NSFileCoordinator) throws -> (VaultSnapshot, Bool) {
        var notes: [Note] = [], warnings: [String] = [], folders: [String] = []
        var nextCache: [String: Note] = [:]
        var changedNotes: [Note] = []
        var addedPath = false
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
                let text = try coordinated(checked, writing: false, coordinator: coordinator) { try read($0) }
                let modified = values.contentModificationDate ?? .distantPast
                // Read external content on every scan, but reuse derived data for
                // unchanged notes, including edits that preserve timestamps.
                let note: Note
                if let cached = noteCache[path], cached.text == text {
                    note = cached.modified == modified ? cached : cached.withModified(modified)
                    if cached.modified != modified { changedNotes.append(note) }
                } else {
                    note = Note(path: path, text: text, modified: modified)
                    changedNotes.append(note)
                    if noteCache[path] == nil { addedPath = true }
                }
                nextCache[path] = note
                notes.append(note)
            } catch { warnings.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
        }
        let notesChanged = !changedNotes.isEmpty || nextCache.count != noteCache.count
        if !notesChanged {
            notes = cachedNotes
        } else {
            notes.sort { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
        }
        // Path changes can affect every link's resolution. For sparse content
        // edits, update only changed sources; rebuild for broad changes to avoid
        // repeatedly sorting shared backlink lists.
        if addedPath || nextCache.count != noteCache.count || changedNotes.count > max(1, notes.count / 10) {
            cachedIndex = NoteIndex(notes: notes)
        } else {
            for note in changedNotes { cachedIndex.replaceExisting(note) }
        }
        noteCache = nextCache; cachedNotes = notes
        cachedFolders = folders.sorted(); cachedWarnings = warnings
        return (VaultSnapshot(notes: notes, warnings: warnings, folders: cachedFolders, index: cachedIndex), notesChanged)
    }
    /// Update the known library after our own write, without reading unrelated files.
    /// Explicit refresh / foreground scans still detect external edits, even unchanged timestamps.
    public func snapshotAfterSaving(_ note: Note) -> VaultSnapshot {
        applySaved(note) ?? VaultSnapshot(notes: cachedNotes, warnings: cachedWarnings, folders: cachedFolders, index: cachedIndex)
    }
    /// Apply a saved note to the cached snapshot, returning nil if it matches the cached version.
    public func applySaved(_ note: Note) -> VaultSnapshot? {
        if noteCache[note.path] == note {
            return nil
        }
        startupCacheDirty = true
        noteCache[note.path] = note
        var parent = note.folder
        var folderAdded = false
        while !parent.isEmpty {
            if !cachedFolders.contains(parent) {
                cachedFolders.append(parent)
                folderAdded = true
            }
            parent = (parent as NSString).deletingLastPathComponent
        }
        if folderAdded { cachedFolders.sort() }
        if let existing = cachedNotes.firstIndex(where: { $0.path == note.path }) {
            cachedNotes.remove(at: existing)
        }
        var low = 0, high = cachedNotes.count
        while low < high {
            let middle = (low + high) / 2, candidate = cachedNotes[middle]
            let comesFirst = candidate.modified == note.modified ? candidate.path < note.path : candidate.modified > note.modified
            if comesFirst { low = middle + 1 } else { high = middle }
        }
        cachedNotes.insert(note, at: low)
        if !cachedIndex.replaceExisting(note) { cachedIndex = NoteIndex(notes: cachedNotes) }
        return VaultSnapshot(notes: cachedNotes, warnings: cachedWarnings, folders: cachedFolders, index: cachedIndex)
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
    public func save(path: String, text: String, expected: String, historySession: UUID? = nil) throws -> Note {
        try requireIdle()
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw VaultError.tooLarge }
        let target = try url(path)
        try coordinated(target, writing: true) { file in
            guard fm.fileExists(atPath: file.path), try read(file) == expected else { throw VaultError.conflict }
            if text != expected {
                let now = Date()
                let checkpoint = historyCheckpoint
                let coalescing = historySession != nil && checkpoint?.session == historySession
                    && checkpoint?.path == path && checkpoint?.text == expected
                    && now.timeIntervalSince(checkpoint!.date) < 60
                if !coalescing { try record(RecoveryRecord(path: path, text: expected, kind: .history)) }
                try Data(text.utf8).write(to: file, options: .atomic)
                if let historySession {
                    historyCheckpoint = (path, historySession, coalescing ? checkpoint!.date : now, text)
                } else { historyCheckpoint = nil }
            }
        }
        return Note(path: path, text: text)
    }
    public func trash(path: String, expected: String) throws {
        try requireIdle()
        let target = try url(path)
        try coordinated(target, writing: true) { file in
            guard fm.fileExists(atPath: file.path), try read(file) == expected else { throw VaultError.conflict }
            try record(RecoveryRecord(path: path, text: expected, kind: .deleted))
            try fm.removeItem(at: file)
        }
    }
    public func trashFolder(path: String) throws {
        try requireIdle()
        let target = try fileURL(path)
        try coordinated(target, writing: true) { folder in
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw VaultError.invalidPath
            }
            // Keep every file, including attachments and hidden files. Hidden backups
            // are excluded from the recovery-record enumerator.
            let backup = recovery.appendingPathComponent(".deleted-folders")
                .appendingPathComponent(UUID().uuidString).appendingPathComponent(path)
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: folder, to: backup)
            var entries: [RecoveryRecord] = []
            var enumerationError: Error?
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw CocoaError(.fileReadUnknown) }
            for case let file as URL in walker {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                guard values.isRegularFile == true, file.pathExtension.lowercased() == "md" else { continue }
                let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
                let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
                let relative = path + "/" + filePath.dropFirst(folderPath.count + 1)
                entries.append(RecoveryRecord(path: relative, text: try read(file), kind: .deleted))
            }
            if let enumerationError { throw enumerationError }
            // Finish all recovery writes before removing any source content.
            for entry in entries { try record(entry) }
            try fm.removeItem(at: folder)
        }
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
    func record(_ entry: RecoveryRecord) throws {
        let file = recovery.appendingPathComponent(entry.id.uuidString + ".json")
        // Index first: interruption may leave an ignored orphan, never an unindexed version.
        try catalogRecord(entry, file: file)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: file, options: .atomic)
    }
    /// Convert old private drafts into real files without overwriting the original.
    /// The record ID makes retries safe if the app exits after writing the copy.
    public func migrateLegacyDrafts() throws {
        try requireIdle()
        for summary in try recoverySummaries() where summary.kind == .draft {
            let entry = try recoveryRecord(summary)
            let file = recovery.appendingPathComponent(summary.file)
            let path = (entry.path as NSString).deletingPathExtension + "-恢复-" + entry.id.uuidString + ".md"
            do { _ = try create(path: path, text: entry.text) }
            catch VaultError.exists {
                guard try coordinated(try url(path), writing: false, { try read($0) }) == entry.text else { throw VaultError.conflict }
            }
            try fm.removeItem(at: file); removeCatalogRecord(entry)
        }
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
    /// Resolve relative attachments without allowing a scheme, hidden file, or symlink escape.
    public func attachment(_ source: String, from note: String) throws -> Data {
        if let embed = ObsidianImageReference(source: source) {
            return try obsidianImage(embed.target, from: note)
        }
        guard let parts = URLComponents(string: source), parts.scheme == nil, parts.host == nil else { throw VaultError.invalidPath }
        // A leading slash denotes the vault root, never the device filesystem.
        var components = parts.path.hasPrefix("/") ? [] : (note as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for component in parts.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw VaultError.invalidPath }
                components.removeLast()
            } else { components.append(String(component)) }
        }
        let target = try fileURL(components.joined(separator: "/"))
        return try coordinated(target, writing: false) { file in
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 * 1024 else { throw VaultError.attachmentTooLarge }
            return try Data(contentsOf: file)
        }
    }
    private func obsidianImage(_ target: String, from note: String) throws -> Data {
        guard !target.hasPrefix("//"), !target.contains(":") else { throw VaultError.invalidPath }
        let rooted = target.hasPrefix("/")
        let target = rooted ? String(target.dropFirst()) : target
        // An explicit leading slash resolves only from the vault root.
        func encoded(_ path: String) -> String {
            path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "%?#"))) ?? path
        }
        let folder = (note as NSString).deletingLastPathComponent
        let local = folder.isEmpty ? target : folder + "/" + target
        for path in (rooted ? [target] : [local, target]) {
            var components: [String] = []
            for component in path.split(separator: "/") {
                if component == "." { continue }
                if component == ".." {
                    guard !components.isEmpty else { throw VaultError.invalidPath }
                    components.removeLast()
                } else { components.append(String(component)) }
            }
            let candidate = components.joined(separator: "/")
            let url = try fileURL(candidate)
            if fm.fileExists(atPath: url.path) { return try attachment(encoded(candidate), from: "") }
        }
        // A bare filename is commonly stored in a separate Obsidian attachment folder.
        guard !rooted, !target.contains("/"), let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var matches: [String] = []
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values.isRegularFile == true && file.lastPathComponent == target {
                matches.append(String(file.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)))
                if matches.count > 1 { throw SyncFailure("有多个同名图片，请在图片引用中填写完整路径。") }
            }
        }
        guard let match = matches.first else { throw CocoaError(.fileReadNoSuchFile) }
        return try attachment(encoded(match), from: "")
    }
    public func importAttachment(_ source: URL, from note: String) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let data = try coordinated(source, writing: false) { file in
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 32 * 1024 * 1024 else { throw VaultError.attachmentTooLarge }
            return try Data(contentsOf: file)
        }
        return try insertAttachment(data, extension: source.pathExtension.isEmpty ? "bin" : source.pathExtension, from: note)
    }
    public func insertAttachment(_ data: Data, extension ext: String, from note: String) throws -> String {
        try requireIdle()
        guard data.count <= 32 * 1024 * 1024 else { throw VaultError.attachmentTooLarge }
        guard !ext.isEmpty, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw VaultError.invalidPath }
        let folder = (note as NSString).deletingLastPathComponent
        let relative = "attachments/" + UUID().uuidString + "." + ext
        let target = try fileURL((folder.isEmpty ? "" : folder + "/") + relative)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(target, writing: true) { try data.write(to: $0, options: .withoutOverwriting) }
        return relative
    }

    public func restoreCopy(_ record: RecoveryRecord) throws -> Note {
        let stem = (record.path as NSString).deletingPathExtension
        return try create(path: stem + "-恢复-" + UUID().uuidString.prefix(8) + ".md", text: record.text)
    }
}
