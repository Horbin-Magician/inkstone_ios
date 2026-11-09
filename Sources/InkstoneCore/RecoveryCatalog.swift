import Foundation

public enum RecoveryKind: String, Codable, Hashable, Sendable {
    case history = "历史版本", syncBefore = "同步前版本", deleted = "已删除", draft = "恢复草稿", other = "其他恢复记录"
    public var isHistory: Bool { self == .history || self == .syncBefore || self == .other }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .other
    }
}

/// Small list metadata; the full version is loaded only when opened.
public struct RecoverySummary: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let date: Date
    public let kind: RecoveryKind
    public let excerpt: String
    let file: String
    init(_ record: RecoveryRecord, file: String) {
        id = record.id; path = record.path; date = record.date; kind = record.kind
        excerpt = String(record.text.prefix(100)); self.file = file
    }
}

extension Vault {
    private var catalog: URL { recovery.appendingPathComponent(".catalog-v1") }
    private func bucket(_ path: String) -> URL { catalog.appendingPathComponent(digest(Data(path.utf8))) }
    func catalogRecord(_ record: RecoveryRecord, file: URL) throws {
        let directory = bucket(record.path)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let rootPath = recovery.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(rootPath + "/") else { throw VaultError.invalidPath }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        try JSONEncoder().encode(RecoverySummary(record, file: relative)).write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
    }
    func removeCatalogRecord(_ record: RecoveryRecord) {
        try? fm.removeItem(at: bucket(record.path).appendingPathComponent(record.id.uuidString + ".json"))
    }
    private func prepareCatalog() throws {
        let ready = catalog.appendingPathComponent("ready")
        if fm.fileExists(atPath: ready.path) { return }
        try fm.createDirectory(at: catalog, withIntermediateDirectories: true)
        var scanError: Error?
        guard let walker = fm.enumerator(at: recovery, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in walker where file.pathExtension == "json" {
            let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: file))
            try catalogRecord(record, file: file)
        }
        if let scanError { throw scanError }
        try Data().write(to: ready, options: .atomic)
    }
    private func recordURL(_ summary: RecoverySummary) throws -> URL {
        let file = recovery.appendingPathComponent(summary.file).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(recovery.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              file.lastPathComponent == summary.id.uuidString + ".json" else { throw VaultError.invalidPath }
        return file
    }
    public func recoverySummaries(path: String? = nil) throws -> [RecoverySummary] {
        try prepareCatalog()
        do { return try readSummaries(path: path) }
        catch is DecodingError {
            // The catalog is derived data; rebuild it if interrupted storage corrupts a sidecar.
            try fm.removeItem(at: catalog)
            try prepareCatalog()
            return try readSummaries(path: path)
        }
    }
    private func readSummaries(path: String?) throws -> [RecoverySummary] {
        let directory = path.map(bucket) ?? catalog
        guard fm.fileExists(atPath: directory.path) else { return [] }
        var result: [RecoverySummary] = []
        var scanError: Error?
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in walker where file.pathExtension == "json" {
            let summary = try JSONDecoder().decode(RecoverySummary.self, from: Data(contentsOf: file))
            // A crash between catalog and original writes may leave an orphan summary.
            if (path == nil || summary.path == path), fm.fileExists(atPath: try recordURL(summary).path) { result.append(summary) }
        }
        if let scanError { throw scanError }
        return result.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }
    public func recoveryRecord(_ summary: RecoverySummary) throws -> RecoveryRecord {
        let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: recordURL(summary)))
        guard record.id == summary.id, record.path == summary.path else { throw VaultError.conflict }
        return record
    }
}
