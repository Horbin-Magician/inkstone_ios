import Foundation

extension Vault {
    /// A portable ZIP containing regular vault files; private recovery and symlinks are excluded.
    public func exportArchive() throws -> Data {
        try requireIdle()
        let temporary = fm.temporaryDirectory.appendingPathComponent("inkstone-backup-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: temporary) }
        let writer = try StreamingArchive(url: temporary)
        defer { writer.close() }
        var scanError: Error?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in walker {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            let path = String(file.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            if values.isDirectory == true { try writer.append(name: path + "/", source: nil); continue }
            guard values.isRegularFile == true else { continue }
            guard (values.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw VaultError.backupTooLarge }
            try coordinated(try fileURL(path), writing: false) { try writer.append(name: path, source: $0) }
        }
        if let scanError { throw scanError }
        try writer.finish()
        // Keep the existing FileDocument API, backed by a mapping when supported.
        return try Data(contentsOf: temporary, options: .mappedIfSafe)
    }

    public func pruneRecovery(before date: Date) throws -> Int {
        guard let walker = fm.enumerator(at: recovery, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for case let file as URL in walker where file.pathExtension == "json" {
            let entry = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: file))
            if entry.kind != "恢复草稿" && entry.date < date {
                try fm.removeItem(at: file); removeCatalogRecord(entry); removed += 1
            }
        }
        return removed
    }
}

/// ZIP32, stored entries, UTF-8 filenames. No platform-specific compressor is required.
public enum VaultArchive {
    public static func encode(_ entries: [(String, Data)]) throws -> Data {
        guard entries.count < 65535 else { throw VaultError.backupTooLarge }
        var output = Data(), central = Data()
        for (name, bytes) in entries.sorted(by: { $0.0 < $1.0 }) {
            try SyncManifest.validatePath(name.hasSuffix("/") ? String(name.dropLast()) : name)
            let filename = Data(name.utf8)
            guard filename.count <= 65535, bytes.count <= UInt32.max, output.count <= UInt32.max else { throw VaultError.backupTooLarge }
            let offset = output.count
            let crc = checksum(bytes)
            output.le32(0x04034b50); output.le16(20); output.le16(0x0800); output.le16(0)
            output.le16(0); output.le16(33); output.le32(crc)
            output.le32(UInt32(bytes.count)); output.le32(UInt32(bytes.count)); output.le16(UInt16(filename.count)); output.le16(0)
            output.append(filename); output.append(bytes)
            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(0); central.le16(33); central.le32(crc)
            central.le32(UInt32(bytes.count)); central.le32(UInt32(bytes.count)); central.le16(UInt16(filename.count))
            central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(name.hasSuffix("/") ? 16 : 0); central.le32(UInt32(offset)); central.append(filename)
        }
        let offset = output.count
        guard offset <= UInt32.max, central.count <= UInt32.max else { throw VaultError.backupTooLarge }
        output.append(central)
        output.le32(0x06054b50); output.le16(0); output.le16(0)
        output.le16(UInt16(entries.count)); output.le16(UInt16(entries.count)); output.le32(UInt32(central.count)); output.le32(UInt32(offset)); output.le16(0)
        return output
    }
    private static func checksum(_ data: Data) -> UInt32 { ~ArchiveCRC.update(0xffffffff, data) }
}

private enum ArchiveCRC {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        return crc
    }
    static func update(_ initial: UInt32, _ data: Data) -> UInt32 {
        var crc = initial
        for byte in data { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xff)] }
        return crc
    }
}

/// ZIP data descriptors allow one pass over each file with a 256 KiB buffer.
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
    func append(name: String, source: URL?) throws {
        guard count < 65534 else { throw VaultError.backupTooLarge }
        try SyncManifest.validatePath(name.hasSuffix("/") ? String(name.dropLast()) : name)
        let filename = Data(name.utf8), offset = try handle.offset()
        guard filename.count <= 65535, offset <= UInt32.max else { throw VaultError.backupTooLarge }
        var header = Data()
        header.le32(0x04034b50); header.le16(20); header.le16(0x0808); header.le16(0)
        header.le16(0); header.le16(33); header.le32(0); header.le32(0); header.le32(0)
        header.le16(UInt16(filename.count)); header.le16(0); header.append(filename)
        try handle.write(contentsOf: header)
        var crc: UInt32 = 0xffffffff
        var size: UInt32 = 0
        if let source {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                loaded += chunk.count
                guard loaded <= 128 * 1024 * 1024 else { throw VaultError.backupTooLarge }
                crc = ArchiveCRC.update(crc, chunk); size += UInt32(chunk.count)
                try handle.write(contentsOf: chunk)
            }
        }
        crc = ~crc
        var descriptor = Data()
        descriptor.le32(0x08074b50); descriptor.le32(crc); descriptor.le32(size); descriptor.le32(size)
        try handle.write(contentsOf: descriptor)
        central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0808); central.le16(0)
        central.le16(0); central.le16(33); central.le32(crc); central.le32(size); central.le32(size)
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
