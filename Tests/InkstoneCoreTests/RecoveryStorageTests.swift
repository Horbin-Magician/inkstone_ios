import Foundation
import Testing
@testable import InkstoneCore

struct RecoveryStorageTests {
    @Test func hiddenBackupsCanBeRestoredAndCleanedButPendingObjectsAreProtected() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let remote = MemoryRemote()
        let original = Data([1, 2, 3]), edited = Data([4, 5, 6])
        await remote.set(["images/a.bin": original])
        _ = try await vault.synchronize(remote: remote)
        await remote.set(["images/a.bin": edited])
        _ = try await vault.synchronize(remote: remote)
        let backup = try #require(try await vault.recoveryStorage().first { $0.category == .syncBackup })
        #expect(backup.bytes >= 3 && !backup.protected)
        let restored = try await vault.restoreRecoveryStorage(backup.id)
        #expect(try Data(contentsOf: root.appendingPathComponent(restored + "/images/a.bin")) == original)
        #expect(try Data(contentsOf: root.appendingPathComponent("images/a.bin")) == edited)
        let state = recovery.appendingPathComponent(".sync/" + digest(Data(remote.identity.utf8)))
        try fm.createDirectory(at: state.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try original.write(to: state.appendingPathComponent("objects/" + digest(original)))
        try Data("pending".utf8).write(to: state.appendingPathComponent("pending.json"))
        let staged = try #require(try await vault.recoveryStorage().first { $0.category == .staging })
        #expect(staged.protected && staged.bytes == 3)
        await #expect(throws: VaultError.self) { try await vault.removeRecoveryStorage(staged.id) }
        #expect(try await vault.recoveryStorage().first { $0.id == backup.id }?.protected == true)
        await #expect(throws: VaultError.self) { try await vault.removeRecoveryStorage(backup.id) }
        try fm.removeItem(at: state.appendingPathComponent("pending.json"))
        try await vault.removeRecoveryStorage(backup.id)
        #expect(try await vault.recoveryStorage().allSatisfy { $0.id != backup.id })
        _ = try await vault.create(path: "deleted/a.md", text: "body")
        try original.write(to: root.appendingPathComponent("deleted/.hidden"))
        try await vault.trashFolder(path: "deleted")
        let folder = try #require(try await vault.recoveryStorage().first { $0.category == .deletedFolder })
        let restoredFolder = try await vault.restoreRecoveryStorage(folder.id)
        #expect(try String(contentsOf: root.appendingPathComponent(restoredFolder + "/deleted/a.md"), encoding: .utf8) == "body")
        #expect(try Data(contentsOf: root.appendingPathComponent(restoredFolder + "/deleted/.hidden")) == original)
        try await vault.removeRecoveryStorage(folder.id)
        #expect(try await vault.recoveryStorage().allSatisfy { $0.id != folder.id })
    }
}

extension RecoveryStorageTests {
    @Test func deletedFolderLinksDoNotHideRecoveryCatalogOrTouchExternalFiles() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let outside = base.appendingPathComponent("outside.bin")
        let original = Data("external data".utf8)
        try original.write(to: outside)
        _ = try await vault.create(path: "deleted/note.md", text: "retained body")
        try fm.createSymbolicLink(at: root.appendingPathComponent("deleted/link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("deleted/broken"), withDestinationURL: base.appendingPathComponent("missing"))
        try await vault.trashFolder(path: "deleted")
        let items = try await vault.recoveryStorage()
        #expect(items.contains { $0.category == .history })
        let folder = try #require(items.first { $0.category == .deletedFolder })
        #expect(!folder.canRestore)
        #expect(folder.bytes >= Data("retained body".utf8).count)
        await #expect(throws: VaultError.self) { _ = try await vault.restoreRecoveryStorage(folder.id) }
        try await vault.removeRecoveryStorage(folder.id)
        #expect(try Data(contentsOf: outside) == original)
        #expect(try await vault.recoveryStorage().allSatisfy { $0.id != folder.id })
        // The regular note remains independently recoverable from its history record.
        let summary = try #require(try await vault.recoverySummaries().first)
        let record = try await vault.recoveryRecord(summary)
        #expect(try await vault.restoreCopy(record).text == "retained body")
    }
}
