import Foundation
import CryptoKit

public struct SyncFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

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
    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4096 else { throw VaultError.invalidPath }
        for part in path.components(separatedBy: "/") {
            let stem = part.components(separatedBy: ".")[0].uppercased()
            guard !part.isEmpty, part.utf8.count <= 255, !part.hasPrefix("."),
                  !part.hasSuffix(" "), !part.hasSuffix("."),
                  !part.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "\\:<>\"|?*".unicodeScalars.contains($0) }),
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
                    let ext = (path as NSString).pathExtension
                    let stem = ext.isEmpty ? path : (path as NSString).deletingPathExtension
                    let copy = stem + " (云端冲突 \(r))" + (ext.isEmpty ? "" : "." + ext)
                    for files in [base, local, remote.files] {
                        guard files[copy] == nil || files[copy] == r else { throw SyncFailure("冲突副本名称已被占用。") }
                    }
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
