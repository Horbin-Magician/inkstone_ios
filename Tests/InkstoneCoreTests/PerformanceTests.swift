import Foundation
import Testing
@testable import InkstoneCore

@Suite(.serialized)
struct PerformanceTests {
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
    func recoveryAndLargeSearch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: base.appendingPathComponent("vault"), recovery: base.appendingPathComponent("recovery"))
        let body = String(repeating: "中文 searchable paragraph. ", count: 100)
        for i in 0..<1000 { try await vault.record(RecoveryRecord(path: "note-\(i % 100).md", text: body, kind: "历史版本")) }
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
