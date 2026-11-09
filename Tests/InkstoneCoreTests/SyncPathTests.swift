import Foundation
import Testing
@testable import InkstoneCore

struct SyncPathTests {
    @Test(arguments: [
        ("a.md", "A.md"), ("A.md", "a.md"),
        ("item", "item/note.md"), ("item/note.md", "item"),
        ("Folder/a.md", "folder/a.md")
    ])
    func remotePathTransition(paths: (String, String)) async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault")
        let recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        let data = Data("content".utf8)
        await remote.set([paths.0: data])
        _ = try await vault.synchronize(remote: remote)
        await remote.set([paths.1: data])
        _ = try await vault.synchronize(remote: remote)
        let restarted = try Vault(root: root, recovery: recovery)
        _ = try await restarted.synchronize(remote: remote)
        #expect(try Data(contentsOf: root.appendingPathComponent(paths.1)) == data)
        #expect(await remote.value.files == [paths.1: digest(data)])
        let walker = try #require(fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var names: [String] = []
        for case let url as URL in walker where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            names.append(url.path.components(separatedBy: "/vault/").last!)
        }
        #expect(names == [paths.1])
    }
}

extension SyncPathTests {
    @Test(arguments: [false, true])
    func restartAfterRemovalBarrier(partiallyInstalled: Bool) async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        let data = Data("same".utf8), other = Data("other".utf8)
        await remote.set(["a.md": data, "folder/old.md": other])
        _ = try await vault.synchronize(remote: remote)
        let before = await remote.value.files
        await remote.set(["A.md": data, "folder": other])
        let target = await remote.value
        let state = recovery.appendingPathComponent(".sync/" + digest(Data(remote.identity.utf8)))
        try fm.createDirectory(at: state.appendingPathComponent("objects"), withIntermediateDirectories: true)
        for bytes in [data, other] { try bytes.write(to: state.appendingPathComponent("objects/" + digest(bytes))) }
        try fm.removeItem(at: root.appendingPathComponent("a.md"))
        try fm.removeItem(at: root.appendingPathComponent("folder"))
        if partiallyInstalled { try data.write(to: root.appendingPathComponent("A.md")) }
        let journal: [String: Any] = ["before": before, "target": ["version": 1, "files": target.files],
            "removalsComplete": true, "published": true]
        try JSONSerialization.data(withJSONObject: journal).write(to: state.appendingPathComponent("pending.json"))
        let restarted = try Vault(root: root, recovery: recovery)
        _ = try await restarted.synchronize(remote: remote)
        _ = try await restarted.synchronize(remote: remote)
        #expect(try Data(contentsOf: root.appendingPathComponent("A.md")) == data)
        #expect(try Data(contentsOf: root.appendingPathComponent("folder")) == other)
        #expect(await remote.value == target)
        #expect(!fm.fileExists(atPath: state.appendingPathComponent("pending.json").path))
    }

    @Test func corruptStagingDoesNotDeleteAnyOriginalsDuringRecovery() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        await remote.set(["old.md": Data("old".utf8)])
        _ = try await vault.synchronize(remote: remote)
        let before = await remote.value.files
        let state = recovery.appendingPathComponent(".sync/" + digest(Data(remote.identity.utf8)))
        await remote.set(["new.md": Data("new".utf8)])
        let target = await remote.value
        let journal: [String: Any] = ["before": before, "target": ["version": 1, "files": target.files], "published": true]
        try JSONSerialization.data(withJSONObject: journal).write(to: state.appendingPathComponent("pending.json"))
        await #expect(throws: Error.self) { _ = try await vault.synchronize(remote: remote) }
        #expect(try String(contentsOf: root.appendingPathComponent("old.md"), encoding: .utf8) == "old")
        #expect(await remote.value == target)
    }
}

extension SyncPathTests {
    @Test func lostPublishResponseResumesOnRestart() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        await remote.set(["old.md": Data("old".utf8)])
        _ = try await vault.synchronize(remote: remote)
        await remote.set(["new.md": Data("new".utf8)])
        await remote.loseNextPublishResponse()
        await #expect(throws: SyncFailure.self) { _ = try await vault.synchronize(remote: remote) }
        #expect(try String(contentsOf: root.appendingPathComponent("old.md"), encoding: .utf8) == "old")
        let restarted = try Vault(root: root, recovery: recovery)
        _ = try await restarted.synchronize(remote: remote)
        #expect(try await restarted.scan().notes.map(\.path) == ["new.md"])
        #expect(await remote.value.files == ["new.md": digest(Data("new".utf8))])
    }
}

extension SyncPathTests {
    @Test func hiddenFileBlocksDirectoryReplacementBeforePublish() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        await remote.set(["folder/a.md": Data("old".utf8)])
        _ = try await vault.synchronize(remote: remote)
        let hidden = root.appendingPathComponent("folder/.keep")
        try Data("external".utf8).write(to: hidden)
        await remote.set(["folder": Data("new".utf8)])
        let revision = await remote.revision
        await #expect(throws: VaultError.self) { _ = try await vault.synchronize(remote: remote) }
        #expect(await remote.revision == revision)
        #expect(try String(contentsOf: hidden, encoding: .utf8) == "external")
        #expect(try String(contentsOf: root.appendingPathComponent("folder/a.md"), encoding: .utf8) == "old")
    }
}
