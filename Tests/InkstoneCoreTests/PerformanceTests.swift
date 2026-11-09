import Foundation
import Testing
@testable import InkstoneCore

@Suite(.serialized)
struct PerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_SYNC_BENCHMARK"] == "1"))
    func syncStages() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault")
        let vault = try Vault(root: root, recovery: base.appendingPathComponent("recovery"))
        let remote = MemoryRemote()
        let body = String(repeating: "中文 benchmark paragraph.\n", count: 100)
        for index in 0..<1000 {
            let file = root.appendingPathComponent("folder-\(index % 20)/note-\(index).md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("\(index) " + body).utf8).write(to: file)
        }
        func measure(_ scenario: String, uploaded: Int = 0, downloaded: Int = 0) async throws {
            let report = try await vault.synchronize(remote: remote, measurePerformance: true)
            #expect(report.uploaded == uploaded && report.downloaded == downloaded)
            for phase in report.phaseDurations.keys.sorted() {
                print("SYNCBENCH \(scenario) \(phase) \(report.phaseDurations[phase]!)")
            }
        }
        try await measure("initial1000", uploaded: 1000)
        try await measure("unchanged1000")
        try Data(("modified " + body).utf8).write(to: root.appendingPathComponent("folder-0/note-0.md"))
        try await measure("singleEdit1000", uploaded: 1)
        // Retain exact remote bytes while introducing a batch of remote edits.
        let objects = await remote.objects
        let manifest = await remote.value
        var files = manifest.files.mapValues { objects[$0]! }
        for index in 0..<100 { files["folder-\(index % 20)/note-\(index).md"] = Data(("remote \(index) " + body).utf8) }
        await remote.set(files)
        try await measure("download100", downloaded: 100)
        let attachment = Data(repeating: 0xa5, count: 32 * 1024 * 1024)
        try attachment.write(to: root.appendingPathComponent("large.bin"))
        try await measure("attachment32MiB", uploaded: 1)
        try await measure("unchangedWithAttachment")
        #expect(try Data(contentsOf: root.appendingPathComponent("large.bin")) == attachment)
        #expect(await remote.value.files.count == 1001)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_BENCHMARK"] == "1"))
    func libraryBaseline() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: base.appendingPathComponent("vault"), recovery: base.appendingPathComponent("recovery"))
        let body = String(repeating: "中文 benchmark searchable paragraph.\n\n", count: 40)
        for index in 0..<1000 {
            _ = try await vault.create(path: "note-\(index).md", text: "[[note-0]] [[note-1]]\n\n" + body)
        }
        let clock = ContinuousClock()
        var start = clock.now
        let snapshot = try await vault.scan()
        print("BENCH scan1000 \(start.duration(to: clock.now))")
        let replacement = Note(path: "note-0.md", text: "[[note-2]]\n" + body)
        start = clock.now
        for _ in 0..<30 { _ = await vault.snapshotAfterSaving(replacement) }
        print("BENCH saveSnapshot30 \(start.duration(to: clock.now))")
        start = clock.now
        for _ in 0..<30 { _ = NoteIndex.search(snapshot.notes, query: "中文 searchable") }
        print("BENCH search30 \(start.duration(to: clock.now))")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_BENCHMARK"] == "1"))
    func metadataOnlyRefresh() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault")
        let vault = try Vault(root: root, recovery: base.appendingPathComponent("recovery"))
        let body = String(repeating: "中文 **formatted** [[note-0]] paragraph.\n\n", count: 100)
        for index in 0..<500 { _ = try await vault.create(path: "note-\(index).md", text: body) }
        _ = try await vault.scan()
        let clock = ContinuousClock()
        var total = Duration.zero
        for iteration in 0..<3 {
            for index in 0..<500 {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(iteration + 1))],
                    ofItemAtPath: root.appendingPathComponent("note-\(index).md").path)
            }
            let start = clock.now
            let snapshot = try await vault.scan()
            total += start.duration(to: clock.now)
            #expect(snapshot.notes.count == 500)
            #expect(snapshot.index.backlinks(to: "note-0.md").count == 499)
        }
        print("BENCH metadataRefresh500x3 \(total)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_BENCHMARK"] == "1"))
    func recoveryAndLargeSearch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: base.appendingPathComponent("vault"), recovery: base.appendingPathComponent("recovery"))
        let body = String(repeating: "中文 searchable paragraph. ", count: 100)
        for i in 0..<1000 { try await vault.record(RecoveryRecord(path: "note-\(i % 100).md", text: body, kind: .history)) }
        _ = try await vault.recoverySummaries()
        let clock = ContinuousClock()
        var start = clock.now
        for _ in 0..<10 { _ = try await vault.records(path: "note-0.md") }
        print("BENCH fullHistoryQuery10 \(start.duration(to: clock.now))")
        start = clock.now
        for _ in 0..<10 { _ = try await vault.recoverySummaries(path: "note-0.md") }
        print("BENCH summaryHistoryQuery10 \(start.duration(to: clock.now))")
        let notes = (0..<10000).map { Note(path: "note-\($0).md", text: body + "尾部target") }
        for query in ["中文 searchable", "不存在Absent", "尾部target"] {
            start = clock.now
            for _ in 0..<3 { _ = NoteIndex.search(notes, query: query) }
            print("BENCH search10000x3 \(query) \(start.duration(to: clock.now))")
            start = clock.now
            for _ in 0..<3 { _ = await NoteIndex.searchConcurrently(notes, query: query) }
            print("BENCH parallelSearch10000x3 \(query) \(start.duration(to: clock.now))")
        }
    }

}
