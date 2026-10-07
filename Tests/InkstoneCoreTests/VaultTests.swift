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
    @Test func testMissingExternalVaultIsNotRecreated() throws {
        let missing = base.appendingPathComponent("removed-external")
        do {
            _ = try Vault(root: missing, recovery: base.appendingPathComponent("recovery"), createIfNeeded: false)
            #expect(false, "Missing external folder must fail")
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
        do { _ = try await vault.save(path: "a.md", text: "phone", expected: "before"); #expect(false, "Expected conflict") }
        catch VaultError.conflict {}
        #expect(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8) == "desktop")
    }
    @Test func testExternalDeletionIsNotResurrected() async throws {
        _ = try await vault.create(path: "a.md", text: "before")
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
        do { _ = try await vault.save(path: "a.md", text: "phone", expected: "before"); #expect(false, "Expected conflict") }
        catch VaultError.conflict {}
        #expect(!(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.md").path)))
    }
    @Test func testDuplicateCreationFails() async throws {
        _ = try await vault.create(path: "a.md", text: "first")
        do { _ = try await vault.create(path: "a.md", text: "second"); #expect(false, "Expected exists") }
        catch VaultError.exists {}
        let snapshot = try await vault.scan()
        #expect(snapshot.notes.first?.text == "first")
    }
    @Test func testRejectsTraversalHiddenMetadataAndAbsolutePaths() async throws {
        for path in ["../outside.md", "/outside.md", ".inkstone/settings.md", "folder/../../bad.md", "a.txt"] {
            do { _ = try await vault.create(path: path, text: "bad"); #expect(false, "Unexpected path accepted: \(path)") }
            catch VaultError.invalidPath {}
        }
    }
    @Test func testSymlinkOutsideVaultRejected() async throws {
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        do { _ = try await vault.create(path: "link/a.md", text: "bad"); #expect(false, "Expected rejection") }
        catch VaultError.invalidPath {}
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
