import Foundation
import Darwin
import Testing
@testable import InkstoneCore

private actor DiskBenchmarkRemote: SyncRemote {
    nonisolated let identity = "disk-transfer-benchmark"
    let directory: URL
    var value = SyncManifest()
    var revision: Int?
    init(_ directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func prepare() {}
    func manifest() -> (SyncManifest, String?) { (value, revision.map(String.init)) }
    func publish(_ manifest: SyncManifest, revision: String?) throws {
        guard revision == self.revision.map(String.init) else { throw VaultError.conflict }
        value = manifest; self.revision = (self.revision ?? 0) + 1
    }
    func download(_ hash: String, to file: URL) async throws {
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.copyItem(at: directory.appendingPathComponent(hash), to: file)
    }
    func upload(_ hash: String, from file: URL) async throws {
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(hash))
    }
}

struct AttachmentTransferBenchmarks {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_ATTACHMENT_BENCHMARK"] == "1"))
    func multipleLargeAttachments() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let vault = try Vault(root: source, recovery: base.appendingPathComponent("source-state"))
        for i in 0..<6 {
            let file = source.appendingPathComponent("attachment-\(i).bin")
            #expect(fm.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            let chunk = Data(repeating: UInt8(i), count: 1024 * 1024)
            for _ in 0..<32 { try handle.write(contentsOf: chunk) }
            try handle.close()
        }
        let remote = try DiskBenchmarkRemote(base.appendingPathComponent("remote"))
        let clock = ContinuousClock(), start = ContinuousClock.now
        let sent = try await vault.synchronize(remote: remote)
        let uploaded = clock.now
        let receiverRoot = base.appendingPathComponent("receiver")
        let receiver = try Vault(root: receiverRoot, recovery: base.appendingPathComponent("receiver-state"))
        let received = try await receiver.synchronize(remote: remote)
        let downloaded = clock.now
        #expect(sent.uploaded == 6 && received.downloaded == 6)
        for i in 0..<6 {
            let path = "attachment-\(i).bin"
            #expect(try digestFile(source.appendingPathComponent(path)) == digestFile(receiverRoot.appendingPathComponent(path)))
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var disk: Int64 = 0
        let walker = try #require(fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        while let file = walker.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { disk += Int64(values.fileSize ?? 0) }
        }
        print("ATTACHMENT_BENCH bytesPerDirection=201326592 upload=\(start.duration(to: uploaded)) download=\(uploaded.duration(to: downloaded)) peakRSSBytes=\(usage.ru_maxrss) diskBytes=\(disk)")
    }
}
