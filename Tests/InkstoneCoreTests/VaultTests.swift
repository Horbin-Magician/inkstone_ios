import Foundation
import Testing
@testable import InkstoneCore

final class VaultTests {
    var base: URL!
    var root: URL!
    var vault: Vault!
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("vault")
        vault = try Vault(root: root, recovery: base.appendingPathComponent("recovery"))
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    @Test func folderDeletionPreservesNotesAttachmentsAndSiblingFolders() async throws {
        _ = try await vault.create(path: "folder/nested/a.md", text: "正文")
        _ = try await vault.create(path: "folder-other/keep.md", text: "keep")
        let attachment = try await vault.insertAttachment(Data([0, 255, 2]), extension: "png", from: "folder/nested/a.md")
        try await vault.trashFolder(path: "folder")
        let snapshot = try await vault.scan()
        #expect(snapshot.notes.map(\.path) == ["folder-other/keep.md"])
        #expect(!snapshot.folders.contains("folder"))
        let records = try await vault.records()
        #expect(records.count == 1)
        #expect(records.first?.path == "folder/nested/a.md")
        #expect(records.first?.text == "正文")
        let backups = base.appendingPathComponent("recovery/.deleted-folders")
        let backup = try #require(FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: backup.appendingPathComponent("folder/nested/" + attachment)) == Data([0, 255, 2]))
        _ = try await vault.restoreCopy(try #require(records.first))
        #expect(try await vault.scan().notes.contains { $0.text == "正文" })
    }
    @Test func folderDeletionHandlesEmptyFoldersAndRejectsUnsafeTargets() async throws {
        try await vault.createFolder(path: "empty")
        try await vault.trashFolder(path: "empty")
        #expect(try await vault.scan().folders.isEmpty)
        _ = try await vault.create(path: "a.md", text: "keep")
        for path in ["", "../outside", "/", "a.md"] {
            do { try await vault.trashFolder(path: path); Issue.record("Unsafe folder deletion accepted") }
            catch VaultError.invalidPath {}
        }
        #expect(try await vault.scan().notes.count == 1)
    }
    @Test func folderDeletionPreservesSourceWhenRecoveryCannotBeCreated() async throws {
        _ = try await vault.create(path: "folder/a.md", text: "keep")
        try Data([0xff]).write(to: root.appendingPathComponent("folder/bad.md"))
        do { try await vault.trashFolder(path: "folder"); Issue.record("Expected invalid UTF-8") }
        catch VaultError.invalidUTF8 {}
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder/a.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder/bad.md").path))
        #expect(try await vault.records().isEmpty)
    }
    @Test func archivePreservesUnicodeAndBinaryFiles() async throws {
        _ = try await vault.create(path: "中文/笔记.md", text: "正文👩‍💻")
        let image = try await vault.insertAttachment(Data([0, 255, 1, 2]), extension: "png", from: "中文/笔记.md")
        try legacyDraft(path: "中文/笔记.md", text: "秘密草稿")
        try await vault.createFolder(path: "空目录")
        let bytes = try await vault.exportArchive()
        #if os(macOS)
        let archive = base.appendingPathComponent("backup.zip")
        try bytes.write(to: archive)
        let extracted = base.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("空目录").path))
        #expect(try Data(contentsOf: extracted.appendingPathComponent("中文/笔记.md")) == Data("正文👩‍💻".utf8))
        #expect(try Data(contentsOf: extracted.appendingPathComponent("中文/" + image)) == Data([0, 255, 1, 2]))
        #endif
        #expect(!String(decoding: bytes, as: UTF8.self).contains("秘密草稿"))
    }
    private func legacyDraft(path: String, text: String) throws {
        let entry = RecoveryRecord(path: path, text: text, kind: "恢复草稿")
        let directory = base.appendingPathComponent("recovery/drafts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(entry.id.uuidString + ".json"))
    }
    @Test func migrationPreservesOriginalAndCreatesMarkdownExactlyOnce() async throws {
        _ = try await vault.create(path: "中文/a.md", text: "desktop edit")
        try legacyDraft(path: "中文/a.md", text: "phone edit")
        try legacyDraft(path: "new.md", text: "new note")
        try await vault.migrateLegacyDrafts()
        try await vault.migrateLegacyDrafts()
        let notes = try await vault.scan().notes
        #expect(notes.count == 3)
        #expect(notes.first { $0.path == "中文/a.md" }?.text == "desktop edit")
        #expect(notes.contains { $0.text == "phone edit" && $0.path.hasPrefix("中文/a-恢复-") })
        #expect(notes.contains { $0.text == "new note" })
        #expect(try await vault.records().isEmpty)
    }
    @Test func migrationRetriesAfterCopyWasAlreadyWritten() async throws {
        try legacyDraft(path: "a.md", text: "unsaved")
        let entry = try #require(await vault.records().first)
        let path = "a-恢复-" + entry.id.uuidString + ".md"
        _ = try await vault.create(path: path, text: entry.text)
        try await vault.migrateLegacyDrafts()
        #expect(try await vault.scan().notes.count == 1)
        #expect(try await vault.records().isEmpty)
    }
    @Test func migrationDoesNotRemoveLegacyRecordOnConflict() async throws {
        try legacyDraft(path: "a.md", text: "unsaved")
        let entry = try #require(await vault.records().first)
        let path = "a-恢复-" + entry.id.uuidString + ".md"
        _ = try await vault.create(path: path, text: "changed copy")
        do { try await vault.migrateLegacyDrafts(); Issue.record("Expected conflict") }
        catch VaultError.conflict {}
        #expect(try await vault.records().first?.text == "unsaved")
        #expect(try await vault.scan().notes.first?.text == "changed copy")
    }
    @Test func localAttachmentsRoundTripAndRejectEscape() async throws {
        let data = Data([1, 2, 3])
        let relative = try await vault.insertAttachment(data, extension: "png", from: "folder/note.md")
        #expect(try await vault.attachment(relative, from: "folder/note.md") == data)
        #expect(try await vault.attachment("../" + relative, from: "folder/nested/note.md") == data)
        for source in ["../../outside.png", "file:///tmp/test.png", "https://example.com/a.png", ".hidden/a.png"] {
            do { _ = try await vault.attachment(source, from: "note.md"); Issue.record("Unsafe attachment accepted") }
            catch {}
        }
    }
    @Test func scanInvalidatesLinksAfterCreateMoveAndDelete() async throws {
        _ = try await vault.create(path: "link.md", text: "[[target]]")
        #expect(try await vault.scan().index.resolve("target", from: "link.md") == .missing)
        _ = try await vault.create(path: "target.md", text: "original")
        let before = try await vault.scan()
        #expect(before.index.backlinks(to: "target.md").map(\.path) == ["link.md"])
        #expect(try await vault.scan().index.backlinks(to: "target.md").map(\.path) == ["link.md"])
        try await vault.move(path: "target.md", to: "moved.md")
        let moved = try await vault.scan()
        #expect(moved.index.resolve("target", from: "link.md") == .missing)
        #expect(moved.index.backlinks(to: "target.md").isEmpty)
        try await vault.trash(path: "moved.md", expected: "original")
        #expect(try await vault.scan().index.resolve("moved", from: "link.md") == .missing)
        #expect(before.index.resolve("target", from: "link.md") == .found("target.md"))
    }
    @Test func importPreservesBytesRejectsDuplicatesAndInvalidEncoding() async throws {
        let source = base.appendingPathComponent("import.md")
        let text = "# 中文\r\n👩‍💻 é\r\n"
        try Data(text.utf8).write(to: source)
        let imported = try await vault.importFile(source)
        #expect(imported.text == text)
        #expect(try Data(contentsOf: root.appendingPathComponent("import.md")) == Data(text.utf8))
        do { _ = try await vault.importFile(source); Issue.record("Duplicate import must fail") }
        catch VaultError.exists {}
        let invalid = base.appendingPathComponent("invalid.md")
        try Data([0xff]).write(to: invalid)
        do { _ = try await vault.importFile(invalid); Issue.record("Invalid UTF-8 must fail") }
        catch VaultError.invalidUTF8 {}
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("invalid.md").path))
    }
    @Test func scanCacheDetectsSameSizeEditWithPreservedTimestampAndDeletion() async throws {
        _ = try await vault.create(path: "cache.md", text: "# Old\n[[one]]")
        _ = try await vault.scan()
        let file = root.appendingPathComponent("cache.md")
        let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try Data("# New\n[[two]]".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let updated = try await vault.scan().notes.first
        #expect(updated?.metadata.headings.first?.title == "New")
        #expect(updated?.metadata.links.first?.target == "two")
        try FileManager.default.removeItem(at: file)
        #expect(try await vault.scan().notes.isEmpty)
    }
    @Test func refreshUpdatesSparseLinksAndTimestampOnlyOrdering() async throws {
        _ = try await vault.create(path: "target.md", text: "# Target")
        _ = try await vault.create(path: "other.md", text: "# Other")
        _ = try await vault.create(path: "a.md", text: "[[target]]")
        _ = try await vault.create(path: "b.md", text: "[[target]]")
        for i in 0..<20 { _ = try await vault.create(path: "filler-\(i).md", text: "unchanged") }
        let before = try await vault.scan()
        let file = root.appendingPathComponent("a.md")
        let later = Date(timeIntervalSince1970: 4_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
        let touched = try await vault.scan()
        #expect(touched.notes.first?.path == "a.md")
        #expect(touched.notes.first?.modified == later)
        #expect(touched.notes.first?.metadata == before.notes.first { $0.path == "a.md" }?.metadata)
        #expect(touched.index.backlinks(to: "target.md").first?.modified == later)
        try Data("[[other]]".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
        let edited = try await vault.scan()
        #expect(edited.index.backlinks(to: "target.md").map(\.path) == ["b.md"])
        #expect(edited.index.backlinks(to: "other.md").map(\.path) == ["a.md"])
        #expect(touched.index.backlinks(to: "target.md").count == 2)
        let unchanged = try await vault.scan()
        #expect(unchanged.notes == edited.notes)
        let saved = await vault.snapshotAfterSaving(try #require(edited.notes.first))
        #expect(saved.notes == edited.notes)
        #expect(saved.index.backlinks(to: "other.md") == edited.index.backlinks(to: "other.md"))
    }

    @Test func pathInspectionFailsWhenAParentIsNotADirectory() async throws {
        _ = try await vault.create(path: "parent.md", text: "keep")
        do {
            _ = try await vault.fileURL("parent.md/child/grandchild.md")
            Issue.record("Expected parent inspection failure")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain)
            #expect(failure.code == Int(POSIXErrorCode.ENOTDIR.rawValue))
        }
        #expect(try String(contentsOf: root.appendingPathComponent("parent.md"), encoding: .utf8) == "keep")
    }

    @Test func testMissingExternalVaultIsNotRecreated() throws {
        let missing = base.appendingPathComponent("removed-external")
        do {
            _ = try Vault(root: missing, recovery: base.appendingPathComponent("recovery"), createIfNeeded: false)
            Issue.record("Missing external folder must fail")
        } catch is CocoaError {}
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
    @Test func testUnicodeRoundTripAndNestedFolder() async throws {
        let text = "# 中文\r\n\r\n👩‍💻 é **文字**\n"
        _ = try await vault.create(path: "读书/笔记.md", text: text)
        let snapshot = try await vault.scan()
        #expect(snapshot.notes.map(\.text) == [text])
        #expect(snapshot.notes.first?.path == "读书/笔记.md")
    }
    @Test func incrementalSaveUpdatesLinksAndFoldersWithoutReadingOtherFiles() async throws {
        _ = try await vault.create(path: "other.md", text: "original")
        _ = try await vault.scan()
        // A corrupt unrelated file must not be read by the save update.
        try Data([0xff]).write(to: root.appendingPathComponent("other.md"))
        let saved = try await vault.create(path: "new/nested/link.md", text: "[[other]]")
        let snapshot = await vault.snapshotAfterSaving(saved)
        #expect(snapshot.notes.count == 2)
        #expect(snapshot.notes.first { $0.path == "other.md" }?.text == "original")
        #expect(snapshot.folders == ["new", "new/nested"])
        #expect(snapshot.index.backlinks(to: "other.md").map(\.path) == [saved.path])
        let refreshed = try await vault.scan()
        #expect(refreshed.notes.count == 1)
        #expect(refreshed.warnings.count == 1)
    }
    @Test func editorHistoryCoalescesButProtectsSessionAndExternalBoundaries() async throws {
        let session = UUID()
        _ = try await vault.create(path: "a.md", text: "original")
        _ = try await vault.save(path: "a.md", text: "one", expected: "original", historySession: session)
        _ = try await vault.save(path: "a.md", text: "two", expected: "one", historySession: session)
        #expect(try await vault.records().map(\.text) == ["original"])
        _ = try await vault.save(path: "a.md", text: "three", expected: "two", historySession: UUID())
        #expect(try await vault.records().count == 2)
        try Data("external".utf8).write(to: root.appendingPathComponent("a.md"))
        _ = try await vault.save(path: "a.md", text: "four", expected: "external", historySession: session)
        #expect(try await vault.records().contains { $0.text == "external" })
        #expect(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8) == "four")
    }
    @Test func testSaveCreatesHistory() async throws {
        _ = try await vault.create(path: "a.md", text: "before")
        _ = try await vault.save(path: "a.md", text: "after", expected: "before")
        let records = try await vault.records()
        #expect(records.count == 1)
        #expect(records.first?.text == "before")
        #expect(records.first?.kind == "历史版本")
        let snapshot = try await vault.scan()
        #expect(snapshot.notes.first?.text == "after")
    }
    @Test func testExternalEditIsNeverOverwritten() async throws {
        _ = try await vault.create(path: "a.md", text: "before")
        try "desktop".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        do { _ = try await vault.save(path: "a.md", text: "phone", expected: "before"); Issue.record("Expected conflict") }
        catch VaultError.conflict {}
        #expect(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8) == "desktop")
    }
    @Test func testExternalDeletionIsNotResurrected() async throws {
        _ = try await vault.create(path: "a.md", text: "before")
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
        do { _ = try await vault.save(path: "a.md", text: "phone", expected: "before"); Issue.record("Expected conflict") }
        catch VaultError.conflict {}
        #expect(!(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.md").path)))
    }
    @Test func testDuplicateCreationFails() async throws {
        _ = try await vault.create(path: "a.md", text: "first")
        do { _ = try await vault.create(path: "a.md", text: "second"); Issue.record("Expected exists") }
        catch VaultError.exists {}
        let snapshot = try await vault.scan()
        #expect(snapshot.notes.first?.text == "first")
    }
    @Test func testRejectsTraversalHiddenMetadataAndAbsolutePaths() async throws {
        for path in ["../outside.md", "/outside.md", ".inkstone/settings.md", "folder/../../bad.md", "a.txt"] {
            do { _ = try await vault.create(path: path, text: "bad"); Issue.record("Unexpected path accepted: \(path)") }
            catch VaultError.invalidPath {}
        }
    }
    @Test func testSymlinkOutsideVaultRejected() async throws {
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        do { _ = try await vault.create(path: "link/a.md", text: "bad"); Issue.record("Expected rejection") }
        catch VaultError.invalidPath {}
    }
    @Test func testTrashRejectsStaleListSnapshot() async throws {
        _ = try await vault.create(path: "a.md", text: "original")
        let listed = try #require(try await vault.scan().notes.first)
        try Data("edited elsewhere".utf8).write(to: root.appendingPathComponent("a.md"), options: .atomic)
        do {
            try await vault.trash(path: listed.path, expected: listed.text)
            Issue.record("Deleting an outdated list item must fail")
        } catch VaultError.conflict {}
        #expect(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8) == "edited elsewhere")
        #expect(try await vault.records().isEmpty)
    }
    @Test func testTrashCanRestoreWithoutOverwritingRecreatedOriginal() async throws {
        _ = try await vault.create(path: "a.md", text: "original")
        try await vault.trash(path: "a.md", expected: "original")
        _ = try await vault.create(path: "a.md", text: "new")
        let records = try await vault.records()
        let restored = try await vault.restoreCopy(try #require(records.first))
        #expect(restored.path != "a.md")
        #expect(restored.text == "original")
        #expect(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8) == "new")
    }
    @Test func savedEditsSurviveRepositoryReopenWithoutPrivateDrafts() async throws {
        _ = try await vault.create(path: "a.md", text: "first")
        _ = try await vault.save(path: "a.md", text: "finished", expected: "first")
        let reopened = try Vault(root: root, recovery: base.appendingPathComponent("recovery"))
        #expect(try await reopened.scan().notes.first?.text == "finished")
        #expect(try await reopened.records().allSatisfy { $0.kind == "历史版本" })
    }
    @Test func testScanReportsInvalidEncodingAndIgnoresHiddenDirectories() async throws {
        try Data([0xff, 0xfe, 0xff]).write(to: root.appendingPathComponent("bad.md"))
        let hidden = root.appendingPathComponent(".inkstone")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: hidden.appendingPathComponent("private.md"))
        let snapshot = try await vault.scan()
        #expect((snapshot.notes.isEmpty))
        #expect(snapshot.warnings.count == 1)
    }
}
