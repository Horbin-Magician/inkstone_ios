import Foundation
import CryptoKit

public struct SyncFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Hash every byte, with bounded memory; timestamps are never trusted as content identity.
func digestFile(_ url: URL, limit: Int = 128 * 1024 * 1024, cancellable: Bool = true) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256(), count = 0
    while try autoreleasepool(invoking: { () throws -> Bool in
        if cancellable { try Task.checkCancellation() }
        guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { return false }
        count += chunk.count
        guard count <= limit else { throw SyncFailure("单个同步文件超过 128 MiB。") }
        hash.update(data: chunk)
        return true
    }) {}
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

struct SyncManifest: Codable, Equatable {
    var version = 1
    var files: [String: String] = [:]
    var generation: UInt64?
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "files", "generation"]) else {
            throw SyncFailure("云端清单过大或包含未知字段，请更新应用后重试。")
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
    private static let forbiddenPathCharacters = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\\:<>\"|?*"))
    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096 else { throw VaultError.invalidPath }
        for part in path.components(separatedBy: "/") {
            let stem = part.components(separatedBy: ".")[0].uppercased()
            guard !part.isEmpty, part.utf8.count <= 255, !part.hasPrefix("."),
                  !part.hasSuffix(" "), !part.hasSuffix("."),
                  !part.unicodeScalars.contains(where: { forbiddenPathCharacters.contains($0) }),
                  !["CON", "PRN", "AUX", "NUL"].contains(stem),
                  !(stem.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT")) && stem.last!.isASCII && stem.last!.isNumber) else { throw VaultError.invalidPath }
        }
    }
    func validate() throws {
        guard (version == 1 && generation == nil) || (version == 2 && (generation ?? 0) > 0), files.count <= 100_000 else {
            throw SyncFailure("不支持的云端同步版本或维护代次。")
        }
        var names = Set<String>()
        for (path, hash) in files {
            try Self.validatePath(path)
            guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  names.insert(path.lowercased()).inserted else { throw SyncFailure("清单存在无效摘要或大小写冲突。") }
        }
        for path in names {
            var parts = path.components(separatedBy: "/")
            while parts.count > 1 {
                parts.removeLast()
                guard !names.contains(parts.joined(separator: "/")) else { throw SyncFailure("文件与文件夹路径冲突。") }
            }
        }
    }
    /// Shared desktop/mobile rule: reserve UTF-8 bytes for the full digest suffix
    /// and extension, truncate only at Unicode scalar boundaries, then number clashes.
    static func conflictPath(_ path: String, hash: String, occupied: [[String: String]]) throws -> String {
        let name = (path as NSString).lastPathComponent
        let parent = String(path.dropLast(name.count))
        let ext = (name as NSString).pathExtension
        let ending = ext.isEmpty ? "" : "." + ext
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let componentLimit = min(255, 4096 - parent.utf8.count)
        for number in 1...100_001 {
            let suffix = " (云端冲突 \(hash)" + (number == 1 ? "" : " \(number)") + ")"
            let budget = componentLimit - suffix.utf8.count - ending.utf8.count
            guard budget >= 0 else { throw SyncFailure("文件扩展名过长，无法安全生成冲突副本。") }
            var prefix = "", used = 0
            for scalar in stem.unicodeScalars {
                let count = scalar.utf8.count
                if used + count > budget { break }
                prefix.unicodeScalars.append(scalar); used += count
            }
            let candidate = parent + prefix + suffix + ending
            let folded = candidate.lowercased()
            let blocked = occupied.contains { files in
                files.contains { original, value in
                    let other = original.lowercased()
                    return (other == folded && (original != candidate || value != hash)) || other.hasPrefix(folded + "/") || folded.hasPrefix(other + "/")
                }
            }
            if !blocked { try validatePath(candidate); return candidate }
        }
        throw SyncFailure("无法分配冲突副本名称。")
    }
    static func merge(base: [String: String], local: [String: String], remote: Self) throws -> (Self, [String]) {
        var result = remote
        result.files = [:]
        var copies: [String: String] = [:], conflicts: [String] = []
        for path in Set(base.keys).union(local.keys).union(remote.files.keys).sorted() {
            let b = base[path], l = local[path], r = remote.files[path]
            let chosen: String?
            if l == r { chosen = l }
            else if l == b { chosen = r }
            else if r == b { chosen = l }
            else {
                conflicts.append(path)
                chosen = l ?? r
                if l != nil, let r {
                    let copy = try conflictPath(path, hash: r, occupied: [base, local, remote.files, copies])
                    copies[copy] = r
                }
            }
            result.files[path] = chosen
        }
        result.files.merge(copies) { _, new in new }
        try result.validate()
        return (result, conflicts)
    }
}
