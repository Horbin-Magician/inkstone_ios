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
    @Test func archivePreservesUnicodeAndBinaryFiles() async throws {
        _ = try await vault.create(path: "中文/笔记.md", text: "正文👩‍💻")
        let image = try await vault.insertAttachment(Data([0, 255, 1, 2]), extension: "png", from: "中文/笔记.md")
        try await vault.writeDraft(path: "中文/笔记.md", text: "秘密草稿")
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
    @Test func pruningNeverRemovesDrafts() async throws {
        _ = try await vault.create(path: "a.md", text: "original")
        _ = try await vault.save(path: "a.md", text: "saved", expected: "original")
        try await vault.writeDraft(path: "a.md", text: "draft")
        #expect(try await vault.pruneRecovery(before: Date().addingTimeInterval(1)) == 1)
        #expect(try await vault.draft(path: "a.md")?.text == "draft")
    }
    @Test func resumedDraftRetainsOriginalBaseAcrossExternalEdits() async throws {
        _ = try await vault.create(path: "a.md", text: "original")
        try await vault.writeDraft(path: "a.md", text: "phone draft", expected: "original")
        try Data("desktop edit".utf8).write(to: root.appendingPathComponent("a.md"))
        let draft = try #require(await vault.draft(path: "a.md"))
        #expect(draft.baseText == "original")
        do {
            _ = try await vault.save(path: "a.md", text: draft.text, expected: try #require(draft.baseText))
            Issue.record("Resumed draft overwrote external edit")
        } catch VaultError.conflict {}
        #expect(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8) == "desktop edit")
    }
    @Test func movingUnsavedDraftDoesNotCreateAFileOrOverwriteAnotherDraft() async throws {
        try await vault.writeDraft(path: "a.md", text: "first", expected: "")
        try await vault.writeDraft(path: "b.md", text: "second", expected: "")
        do { try await vault.move(path: "a.md", to: "b.md"); Issue.record("Overwrote another draft") }
        catch VaultError.exists {}
        try await vault.move(path: "a.md", to: "folder/a.md")
        #expect(try await vault.draft(path: "folder/a.md")?.text == "first")
        #expect(try await vault.draft(path: "a.md") == nil)
        #expect(try await vault.scan().notes.isEmpty)
    }
    @Test func newDraftDoesNotCreateMarkdownAndMovesWithFolder() async throws {
        try await vault.writeDraft(path: "folder/new.md", text: "未完成中文", expected: "", isNew: true)
        #expect(try await vault.scan().notes.isEmpty)
        #expect(try await vault.draft(path: "folder/new.md")?.text == "未完成中文")
        _ = try await vault.create(path: "folder/new.md", text: "原文")
        try await vault.move(path: "folder", to: "moved")
        #expect(try await vault.draft(path: "moved/new.md")?.text == "未完成中文")
        #expect(try await vault.draft(path: "moved/new.md")?.isNew == true)
        #expect(try await vault.draft(path: "folder/new.md") == nil)
        _ = try await vault.save(path: "moved/new.md", text: "完成", expected: "原文")
        #expect(try await vault.draft(path: "moved/new.md") == nil)
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
    @Test func testSaveCreatesHistoryAndClearsDraft() async throws {
        _ = try await vault.create(path: "a.md", text: "before")
        try await vault.writeDraft(path: "a.md", text: "after")
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
    @Test func testDraftSurvivesRepositoryReopen() async throws {
        try await vault.writeDraft(path: "a.md", text: "unsaved")
        let reopened = try Vault(root: root, recovery: base.appendingPathComponent("recovery"))
        let records = try await reopened.records()
        #expect(records.first?.text == "unsaved")
        let snapshot = try await reopened.scan()
        #expect((snapshot.notes.isEmpty))
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
