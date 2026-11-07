import Foundation

extension Vault {
    /// A portable ZIP containing regular vault files; private recovery and symlinks are excluded.
    public func exportArchive() throws -> Data {
        try requireIdle()
        var entries: [(String, Data)] = []
        var total = 0, loaded = 0
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            let path = String(file.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            if values.isDirectory == true { entries.append((path + "/", Data())); continue }
            guard values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
            guard total <= 128 * 1024 * 1024 else { throw VaultError.backupTooLarge }
            let data = try coordinated(try fileURL(path), writing: false) { try Data(contentsOf: $0) }
            loaded += data.count
            guard loaded <= 128 * 1024 * 1024 else { throw VaultError.backupTooLarge }
            entries.append((path, data))
        }
        return try VaultArchive.encode(entries)
    }
    public func pruneRecovery(before date: Date) throws -> Int {
        guard let walker = fm.enumerator(at: recovery, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for case let file as URL in walker where file.pathExtension == "json" {
            let entry = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: file))
            if entry.kind != "恢复草稿" && entry.date < date {
                try fm.removeItem(at: file); removed += 1
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
    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        return ~crc
    }
}
private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
}
