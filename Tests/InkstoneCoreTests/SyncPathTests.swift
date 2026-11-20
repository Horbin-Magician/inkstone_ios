import Foundation
import Testing
@testable import InkstoneCore

struct SyncPathTests {
    private var temporaryRoot: URL {
        ProcessInfo.processInfo.environment["INKSTONE_SYNC_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
    }
    @Test(arguments: [
        ("a.md", "A.md"), ("A.md", "a.md"),
        ("item", "item/note.md"), ("item/note.md", "item"),
        ("Folder/a.md", "folder/a.md")
    ])
    func remotePathTransition(paths: (String, String)) async throws {
        let fm = FileManager.default
        let base = temporaryRoot.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault")
        let recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        if ProcessInfo.processInfo.environment["INKSTONE_SYNC_TEST_ROOT"] != nil {
            #expect(try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true)
        }
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
        let base = temporaryRoot.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
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
        let base = temporaryRoot.appendingPathComponent(UUID().uuidString)
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
        let base = temporaryRoot.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        await remote.set(["old.md": Data("old".utf8)])
        _ = try await vault.synchronize(remote: remote)
        _ = try await vault.create(path: "local.md", text: "local")
        await remote.set(["new.md": Data("new".utf8)])
        await remote.loseNextPublishResponse()
        await #expect(throws: SyncFailure.self) { _ = try await vault.synchronize(remote: remote) }
        #expect(Set(try await vault.scan().notes.map(\.path)) == ["old.md", "local.md"])
        let restarted = try Vault(root: root, recovery: recovery)
        _ = try await restarted.synchronize(remote: remote)
        #expect(Set(try await restarted.scan().notes.map(\.path)) == ["new.md", "local.md"])
        #expect(await remote.value.files == ["new.md": digest(Data("new".utf8)), "local.md": digest(Data("local".utf8))])
    }
}

extension SyncPathTests {
    @Test func hiddenFileBlocksDirectoryReplacementBeforePublish() async throws {
        let fm = FileManager.default
        let base = temporaryRoot.appendingPathComponent(UUID().uuidString)
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

extension SyncPathTests {
    @Test func rejectedPublicationCanRetryWithoutApplyingUnpublishedChanges() async throws {
        let base = temporaryRoot.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        _ = try await vault.create(path: "local.md", text: "local")
        await remote.set(["remote.md": Data("remote".utf8)])
        await remote.reject()
        await #expect(throws: SyncFailure.self) { _ = try await vault.synchronize(remote: remote) }
        #expect(try await vault.scan().notes.map(\.path) == ["local.md"])
        await remote.acceptPublishes()
        let restarted = try Vault(root: root, recovery: recovery)
        _ = try await restarted.synchronize(remote: remote)
        #expect(Set(try await restarted.scan().notes.map(\.path)) == ["local.md", "remote.md"])
        #expect(Set(await remote.value.files.keys) == ["local.md", "remote.md"])
    }

    @Test func concurrentRemoteChangeDuringRejectedPublishDoesNotDeadlock() async throws {
        let base = temporaryRoot.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        await remote.set(["shared.md": Data("v1".utf8)])
        _ = try await vault.synchronize(remote: remote)
        _ = try await vault.save(path: "shared.md", text: "local-v2", expected: "v1")
        await remote.reject()
        await #expect(throws: SyncFailure.self) { _ = try await vault.synchronize(remote: remote) }
        // Another device publishes while our unpublished pending.json is still on disk.
        await remote.acceptPublishes()
        await remote.set(["shared.md": Data("remote-v2".utf8), "other.md": Data("other".utf8)])
        let report = try await vault.synchronize(remote: remote)
        #expect(report.conflicts == ["shared.md"])
        let texts = Set(try await vault.scan().notes.map(\.text))
        #expect(texts.contains("local-v2"))
        #expect(texts.contains("remote-v2"))
        #expect(texts.contains("other"))
    }

    @Test func pureDownloadSkipsPrepareAndPublish() async throws {
        let base = temporaryRoot.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        await remote.set(["a.md": Data("v1".utf8)])
        _ = try await vault.synchronize(remote: remote)
        let preparesBefore = await remote.prepareCount
        let revisionBefore = await remote.revision
        await remote.set(["a.md": Data("v2".utf8), "b.md": Data("b".utf8)])
        let revisionAfterSet = await remote.revision
        let report = try await vault.synchronize(remote: remote)
        #expect(report.downloaded == 2 && report.uploaded == 0)
        #expect(await remote.prepareCount == preparesBefore)
        #expect(await remote.revision == revisionAfterSet)
        #expect(revisionAfterSet != revisionBefore)
    }

    @Test func directoryWithEmptySubdirectoryCanBecomeFile() async throws {
        let base = temporaryRoot.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        await remote.set(["folder/a.md": Data("old".utf8)])
        _ = try await vault.synchronize(remote: remote)
        try await vault.createFolder(path: "folder/empty-sub")
        await remote.set(["folder": Data("file-now".utf8)])
        _ = try await vault.synchronize(remote: remote)
        #expect(try String(contentsOf: root.appendingPathComponent("folder"), encoding: .utf8) == "file-now")
    }

    @Test func caseOnlyRenameSucceedsAndFailedFolderTrashLeavesNoOrphanBackup() async throws {
        let base = temporaryRoot.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        _ = try await vault.create(path: "Note.md", text: "hello")
        try await vault.move(path: "Note.md", to: "note.md")
        #expect(try await vault.scan().notes.map(\.path) == ["note.md"])
        try await vault.createFolder(path: "bad-folder")
        try Data([0xFF, 0xFE, 0x00]).write(to: root.appendingPathComponent("bad-folder/invalid.md"))
        await #expect(throws: VaultError.self) { try await vault.trashFolder(path: "bad-folder") }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad-folder").path))
        let deletedFolders = recovery.appendingPathComponent(".deleted-folders")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: deletedFolders.path)) ?? []
        #expect(leftovers.isEmpty)
    }
}
