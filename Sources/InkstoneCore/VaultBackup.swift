import Foundation
import zlib

extension Vault {
    /// A portable ZIP containing regular vault files; private recovery and symlinks are excluded.
    public func exportArchive() throws -> Data {
        try requireIdle()
        let temporary = fm.temporaryDirectory.appendingPathComponent("inkstone-backup-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: temporary) }
        let writer = try StreamingArchive(url: temporary)
        defer { writer.close() }
        try coordinatedReadBatch { coordinator in
            let rootPrefix = root.path + "/"
            var scanError: Error?
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
            for case let file as URL in walker {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                let lexicalPath = file.standardizedFileURL.path
                guard lexicalPath.hasPrefix(rootPrefix) else { throw VaultError.invalidPath }
                let path = String(lexicalPath.dropFirst(rootPrefix.count))
                let checked = try fileURL(path)
                if values.isDirectory == true {
                    try writer.append(name: path + "/", source: nil, modified: values.contentModificationDate)
                    continue
                }
                guard values.isRegularFile == true else { continue }
                guard (values.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw VaultError.backupTooLarge }
                try coordinated(checked, writing: false, coordinator: coordinator) { coordinatedFile in
                    let attrs = try coordinatedFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                    guard attrs.isRegularFile == true, attrs.isSymbolicLink != true else { throw VaultError.invalidPath }
                    try writer.append(name: path, source: coordinatedFile, modified: attrs.contentModificationDate ?? values.contentModificationDate)
                }
            }
            if let scanError { throw scanError }
        }
        try writer.finish()
        // Read into memory before removing the temporary file so no mmap outlives an unlinked inode.
        return try Data(contentsOf: temporary)
    }

    public func pruneRecovery(before date: Date) throws -> Int {
        try requireIdle()
        var removed = 0
        for summary in try recoverySummaries() where summary.kind != .draft && summary.date < date {
            if let file = try? recordURL(summary), fm.fileExists(atPath: file.path) {
                try fm.removeItem(at: file)
                removed += 1
            }
            removeCatalogSummary(summary)
        }
        // Also prune expired unprotected sync binary backups.
        let syncRoot = recovery.appendingPathComponent(".sync")
        if fm.fileExists(atPath: syncRoot.path),
           let endpoints = try? fm.contentsOfDirectory(atPath: syncRoot.path) {
            for endpoint in endpoints where !endpoint.hasPrefix(".") {
                let state = syncRoot.appendingPathComponent(endpoint)
                guard !fm.fileExists(atPath: state.appendingPathComponent("pending.json").path) else { continue }
                let backups = state.appendingPathComponent("backups")
                guard fm.fileExists(atPath: backups.path),
                      let names = try? fm.contentsOfDirectory(atPath: backups.path) else { continue }
                for name in names where !name.hasPrefix(".") {
                    let entry = backups.appendingPathComponent(name)
                    let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
                    if modified < date {
                        try? fm.removeItem(at: entry)
                        removed += 1
                    }
                }
            }
        }
        return removed
    }
}

private enum ArchiveCRC {
    static func update(_ initial: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.bindMemory(to: UInt8.self).baseAddress else { return initial }
            return UInt32(crc32_z(uLong(initial), bytes, buffer.count))
        }
    }
}

/// Standard ZIP32 stored entries with UTF-8 filenames and DOS timestamps.
/// Patches local file headers in place via seek so no data descriptor is needed.
private final class StreamingArchive {
    let handle: FileHandle
    var central = Data()
    var count = 0
    var loaded = 0
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }
    func close() { try? handle.close() }
    private static func dosTimestamp(_ date: Date?) -> (time: UInt16, date: UInt16) {
        guard let date else { return (0, 33) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980)) - 1980
        let month = max(1, min(12, c.month ?? 1))
        let day = max(1, min(31, c.day ?? 1))
        let hour = max(0, min(23, c.hour ?? 0))
        let minute = max(0, min(59, c.minute ?? 0))
        let second = max(0, min(59, c.second ?? 0)) / 2
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
    func append(name: String, source: URL?, modified: Date? = nil) throws {
        guard count < 65534 else { throw VaultError.backupTooLarge }
        try SyncManifest.validatePath(name.hasSuffix("/") ? String(name.dropLast()) : name)
        let filename = Data(name.utf8), offset = try handle.offset()
        guard filename.count <= 65535, offset <= UInt32.max else { throw VaultError.backupTooLarge }
        let stamp = Self.dosTimestamp(modified)
        var header = Data()
        header.le32(0x04034b50); header.le16(20); header.le16(0x0800); header.le16(0)
        header.le16(stamp.time); header.le16(stamp.date); header.le32(0); header.le32(0); header.le32(0)
        header.le16(UInt16(filename.count)); header.le16(0); header.append(filename)
        try handle.write(contentsOf: header)
        var crc: UInt32 = 0
        var size: UInt32 = 0
        if let source {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { return false }
                loaded += chunk.count
                guard loaded <= 128 * 1024 * 1024 else { throw VaultError.backupTooLarge }
                crc = ArchiveCRC.update(crc, chunk); size += UInt32(chunk.count)
                try handle.write(contentsOf: chunk)
                return true
            }) {}
            let endOffset = try handle.offset()
            var patch = Data()
            patch.le32(crc); patch.le32(size); patch.le32(size)
            try handle.seek(toOffset: offset + 14)
            try handle.write(contentsOf: patch)
            try handle.seek(toOffset: endOffset)
        }
        central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0)
        central.le16(stamp.time); central.le16(stamp.date); central.le32(crc); central.le32(size); central.le32(size)
        central.le16(UInt16(filename.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(source == nil ? 16 : 0); central.le32(UInt32(offset)); central.append(filename)
        count += 1
    }
    func finish() throws {
        let offset = try handle.offset()
        guard offset <= UInt32.max, central.count <= UInt32.max else { throw VaultError.backupTooLarge }
        try handle.write(contentsOf: central)
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0); end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(UInt32(offset)); end.le16(0)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
}
