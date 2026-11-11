import Foundation
import Testing
@testable import InkstoneCore

struct StartupCacheTests {
    private func fixture() throws -> (URL, URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (base, base.appendingPathComponent("vault"), base.appendingPathComponent("recovery"), base.appendingPathComponent("cache/library.plist"))
    }

    @Test func cacheRestoresDerivedDataThenDetectsExternalEditsMovesAndDeletion() async throws {
        let (base, root, recovery, cache) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: root, recovery: recovery, startupCache: cache)
        _ = try await vault.create(path: "a.md", text: "# Old\n[[b]]")
        _ = try await vault.create(path: "b.md", text: "target")
        _ = try await vault.create(path: "deleted.md", text: "remove")
        let original = try await vault.scan()
        let restarted = try Vault(root: root, recovery: recovery, startupCache: cache)
        let cached = try #require(await restarted.cachedSnapshot())
        #expect(cached.notes == original.notes)
        #expect(cached.index.backlinks(to: "b.md").map(\.path) == ["a.md"])
        let date = try #require(original.notes.first { $0.path == "a.md" }?.modified)
        try Data("# New\n[[c]]".utf8).write(to: root.appendingPathComponent("a.md"))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent("a.md").path)
        try FileManager.default.moveItem(at: root.appendingPathComponent("b.md"), to: root.appendingPathComponent("c.md"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.md"))
        let verified = try await restarted.scan()
        #expect(Set(verified.notes.map(\.path)) == ["a.md", "c.md"])
        #expect(verified.notes.first { $0.path == "a.md" }?.metadata.headings.first?.title == "New")
        #expect(verified.index.backlinks(to: "c.md").map(\.path) == ["a.md"])
        let reopened = try Vault(root: root, recovery: recovery, startupCache: cache)
        #expect(await reopened.cachedSnapshot()?.notes == verified.notes)
    }

    @Test func missingCorruptForeignAndUnsupportedCachesFallBackToScan() async throws {
        let (base, root, recovery, cache) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: root, recovery: recovery, startupCache: cache)
        #expect(await vault.cachedSnapshot() == nil)
        _ = try await vault.create(path: "a.md", text: "real text")
        _ = try await vault.scan()
        let foreign = try Vault(root: base.appendingPathComponent("other"), recovery: recovery, startupCache: cache)
        #expect(await foreign.cachedSnapshot() == nil)
        var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: cache), format: nil) as? [String: Any])
        plist["version"] = 999
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: cache)
        let unsupported = try Vault(root: root, recovery: recovery, startupCache: cache)
        #expect(await unsupported.cachedSnapshot() == nil)
        try Data("broken".utf8).write(to: cache)
        let restarted = try Vault(root: root, recovery: recovery, startupCache: cache)
        #expect(await restarted.cachedSnapshot() == nil)
        #expect(try await restarted.scan().notes.first?.text == "real text")
        let repaired = try Vault(root: root, recovery: recovery, startupCache: cache)
        #expect(await repaired.cachedSnapshot()?.notes.first?.text == "real text")
    }

    @Test func unchangedScanDoesNotRewriteCacheAndSaveRefreshPersists() async throws {
        let (base, root, recovery, cache) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: root, recovery: recovery, startupCache: cache)
        _ = try await vault.create(path: "a.md", text: "old")
        _ = try await vault.scan()
        let marker = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: cache.path)
        _ = try await vault.scan()
        #expect(try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == marker)
        let saved = try await vault.save(path: "a.md", text: "new", expected: "old")
        _ = await vault.snapshotAfterSaving(saved)
        _ = try await vault.scan()
        let restarted = try Vault(root: root, recovery: recovery, startupCache: cache)
        #expect(await restarted.cachedSnapshot()?.notes.first?.text == "new")
    }

    @Test func cacheWriteFailureDoesNotHideNotesAndVerificationRejectsSymlinks() async throws {
        let (base, root, recovery, cache) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: root, recovery: recovery, startupCache: cache)
        _ = try await vault.create(path: "a.md", text: "original")
        _ = try await vault.scan()
        let restarted = try Vault(root: root, recovery: recovery, startupCache: cache)
        #expect(await restarted.cachedSnapshot()?.notes.count == 1)
        let outside = base.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a.md"), withDestinationURL: outside)
        #expect(try await restarted.scan().notes.isEmpty)
        // A regular file in place of the parent directory makes the cache unwritable.
        let blocked = base.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let uncached = try Vault(root: root, recovery: recovery, startupCache: blocked.appendingPathComponent("cache"))
        _ = try await uncached.create(path: "real.md", text: "still readable")
        #expect(try await uncached.scan().notes.map(\.text) == ["still readable"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_STARTUP_BENCHMARK"] == "1"))
    func startupThousandNotes() async throws {
        let (base, root, recovery, cache) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = try Vault(root: root, recovery: recovery, startupCache: cache)
        let body = "# Title\n[[note-0]]\n" + String(repeating: "中文 **formatted** paragraph.\n\n", count: 40)
        for i in 0..<1000 { try Data(body.utf8).write(to: root.appendingPathComponent("note-\(i).md")) }
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await vault.scan()
        print("STARTUP coldScan1000 \(start.duration(to: clock.now))")
        let restarted = try Vault(root: root, recovery: recovery, startupCache: cache)
        let cacheStart = clock.now
        #expect(await restarted.cachedSnapshot()?.notes.count == 1000)
        print("STARTUP cachedList1000 \(cacheStart.duration(to: clock.now))")
        let verifyStart = clock.now
        #expect(try await restarted.scan().notes.count == 1000)
        print("STARTUP verification1000 \(verifyStart.duration(to: clock.now))")
    }
}
