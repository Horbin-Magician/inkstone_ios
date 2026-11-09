import Foundation
import Testing
@testable import InkstoneCore

private actor TransferMeter {
    var bytes = 0, tasks = 0, peakBytes = 0, peakTasks = 0, completed = 0
    func started(_ size: Int) {
        bytes += size; tasks += 1
        peakBytes = max(peakBytes, bytes); peakTasks = max(peakTasks, tasks)
    }
    func finished(_ size: Int) { bytes -= size; tasks -= 1; completed += 1 }
}
struct SyncTransferTests {
    @Test func fileSizeRefreshesAfterRewritingTheSameURL() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 1, count: 10).write(to: file)
        #expect(try SyncFile.size(file) == 10)
        try Data(repeating: 2, count: 100).write(to: file)
        #expect(try SyncFile.size(file) == 100)
    }
    @Test func byteBudgetLimitsMixedTransfersIndependentlyOfTaskCount() async throws {
        let meter = TransferMeter()
        let items = [7, 6, 2, 1, 4, 8, 2].enumerated().map { SyncTransfer(hash: String($0.offset), bytes: $0.element) }
        try await SyncTransfer.run(items, taskLimit: 3, byteBudget: 10) { item in
            await meter.started(item.bytes)
            try await Task.sleep(for: .milliseconds(10))
            await meter.finished(item.bytes)
        }
        #expect(await meter.peakBytes <= 10)
        #expect(await meter.peakTasks <= 3)
        #expect(await meter.peakTasks > 1)
        #expect(await meter.completed == items.count)
        #expect(await meter.bytes == 0)
        #expect(await meter.tasks == 0)
        await #expect(throws: SyncFailure.self) {
            try await SyncTransfer.run([SyncTransfer(hash: "oversized", bytes: 11)], byteBudget: 10) { _ in Issue.record("Oversized transfer started") }
        }
    }
    @Test func verifiedCopyRejectsBadDataWithoutOverwritingDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data("bad".utf8).write(to: source)
        try Data("safe".utf8).write(to: target)
        #expect(throws: SyncFailure.self) { try SyncFile.copy(source, to: target, hash: digest(Data("expected".utf8)), replaceCache: true) }
        #expect(try Data(contentsOf: target) == Data("safe".utf8))
        #expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == ["source", "target"])
    }
}

extension SyncTransferTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"] != nil))
    func webDAVFileTransportUsesFullFileAndValidatesExistingObject() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("source.bin"), destination = base.appendingPathComponent("download.bin")
        #expect(fm.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        for i in 0..<32 { try handle.write(contentsOf: Data(repeating: UInt8(i), count: 1024 * 1024)) }
        try handle.close()
        let hash = try SyncFile.hash(source)
        var settings = WebDAVSettings(); settings.allowInsecureHTTP = true
        settings.url = try #require(ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"])
        settings.username = "interop"
        let remote = try WebDAV(settings: settings, password: "test-only")
        try await remote.prepare()
        try await remote.upload(hash, from: source)
        // Conditional 412 must verify the existing object through file download.
        try await remote.upload(hash, from: source)
        try await remote.download(hash, to: destination)
        #expect(try SyncFile.size(destination) == 32 * 1024 * 1024)
        #expect(try SyncFile.hash(destination) == hash)
    }
}
