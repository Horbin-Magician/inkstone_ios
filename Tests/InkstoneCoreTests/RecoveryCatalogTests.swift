import Foundation
import Testing
@testable import InkstoneCore

struct RecoveryCatalogTests {
    @Test func catalogMigratesLegacyRecordsAndLoadsBodiesOnlyOnDemand() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: base.appendingPathComponent("vault"), recovery: recovery)
        let legacy = RecoveryRecord(path: "中文/a.md", text: String(repeating: "历史正文", count: 1000), kind: .history)
        let original = recovery.appendingPathComponent(legacy.id.uuidString + ".json")
        try JSONEncoder().encode(legacy).write(to: original)
        let summary = try #require(try await vault.recoverySummaries(path: legacy.path).first)
        #expect(summary.excerpt.count == 100)
        #expect(try await vault.recoveryRecord(summary) == legacy)
        // A warm listing must not decode a large/corrupt body, even after reopening.
        try Data([0xff]).write(to: original)
        let reopened = try Vault(root: base.appendingPathComponent("vault"), recovery: recovery)
        #expect(try await reopened.recoverySummaries(path: legacy.path) == [summary])
        do { _ = try await reopened.recoveryRecord(summary); Issue.record("Invalid body accepted") } catch {}
        #expect(try await reopened.recoverySummaries(path: "missing.md").isEmpty)
    }
    @Test func newVersionsPruningAndInterruptedCatalogWritesStayConsistent() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: base.appendingPathComponent("vault"), recovery: base.appendingPathComponent("recovery"))
        #expect(try await vault.recoverySummaries().isEmpty)
        _ = try await vault.create(path: "a.md", text: "before")
        _ = try await vault.save(path: "a.md", text: "after", expected: "before")
        let first = try #require(try await vault.recoverySummaries(path: "a.md").first)
        let sidecar = base.appendingPathComponent("recovery/.catalog-v1/" + digest(Data("a.md".utf8)) + "/" + first.id.uuidString + ".json")
        try Data([0xff]).write(to: sidecar)
        #expect(try await vault.recoverySummaries(path: "a.md").count == 1)
        let orphan = RecoveryRecord(path: "a.md", text: "orphan", kind: .history)
        try await vault.catalogRecord(orphan, file: base.appendingPathComponent("recovery/" + orphan.id.uuidString + ".json"))
        #expect(try await vault.recoverySummaries(path: "a.md").count == 1)
        #expect(try await vault.pruneRecovery(before: .distantFuture) == 1)
        #expect(try await vault.recoverySummaries().isEmpty)
    }
}

extension RecoveryCatalogTests {
    @Test func legacySyncVersionsAppearInHistoryAndRestoreAsCopies() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: base.appendingPathComponent("vault"), recovery: base.appendingPathComponent("recovery"))
        let remote = MemoryRemote()
        await remote.set(["a.md": Data("before".utf8)])
        _ = try await vault.synchronize(remote: remote)
        await remote.set(["a.md": Data("after".utf8)])
        _ = try await vault.synchronize(remote: remote)
        let summary = try #require(try await vault.recoverySummaries(path: "a.md").first { $0.kind.isHistory })
        #expect(summary.kind == .syncBefore)
        let record = try await vault.recoveryRecord(summary)
        let bytes = try JSONEncoder().encode(record)
        #expect(String(decoding: bytes, as: UTF8.self).contains("同步前版本"))
        #expect(try JSONDecoder().decode(RecoveryRecord.self, from: bytes).kind == .syncBefore)
        let restored = try await vault.restoreCopy(record)
        #expect(restored.path != "a.md" && restored.text == "before")
        #expect(try await vault.scan().notes.first { $0.path == "a.md" }?.text == "after")
        await remote.set([:])
        _ = try await vault.synchronize(remote: remote)
        #expect(try await vault.recoverySummaries(path: "a.md").filter { $0.kind.isHistory }.count >= 2)
    }
}
