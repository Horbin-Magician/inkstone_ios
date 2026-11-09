import Foundation
import Testing
@testable import InkstoneCore

actor MemoryRemote: SyncRemote {
    nonisolated let identity: String
    init(identity: String = "test-endpoint\nuser") { self.identity = identity }
    var value = SyncManifest()
    var revision: Int? = nil
    var objects: [String: Data] = [:]
    var prepareCount = 0
    var downloadCount = 0
    var uploadCount = 0
    var activeTransfers = 0
    var maxTransfers = 0
    var delayTransfers = false
    func enableDelay() { delayTransfers = true }
    private func transferStarted() async throws {
        activeTransfers += 1; maxTransfers = max(maxTransfers, activeTransfers)
        if delayTransfers { try await Task.sleep(for: .milliseconds(20)) }
    }
    var rejectPublish = false
    var losePublishResponse = false
    func loseNextPublishResponse() { losePublishResponse = true }
    var corrupt = false
    var paused = false
    var reachedPause = false
    var startedWaiter: CheckedContinuation<Void, Never>?
    var resumeWaiter: CheckedContinuation<Void, Never>?
    func pause() { paused = true }
    func waitUntilPaused() async {
        if reachedPause { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func resume() { paused = false; resumeWaiter?.resume(); resumeWaiter = nil }
    func prepare() { prepareCount += 1 }
    func manifest() async -> (SyncManifest, String?) {
        if paused {
            reachedPause = true; startedWaiter?.resume(); startedWaiter = nil
            await withCheckedContinuation { resumeWaiter = $0 }
        }
        return (value, revision.map(String.init))
    }
    func download(_ hash: String) async throws -> Data {
        downloadCount += 1
        defer { activeTransfers -= 1 }
        try await transferStarted()
        if corrupt { return Data("corrupt".utf8) }
        return try #require(objects[hash])
    }
    func upload(_ hash: String, data: Data) async throws {
        uploadCount += 1
        defer { activeTransfers -= 1 }
        try await transferStarted()
        objects[hash] = data
    }
    func publish(_ manifest: SyncManifest, revision: String?) throws {
        guard !rejectPublish, revision == self.revision.map(String.init) else { throw SyncFailure("stale") }
        value = manifest; self.revision = (self.revision ?? 0) + 1
        if losePublishResponse { losePublishResponse = false; throw SyncFailure("response lost") }
    }
    func set(_ files: [String: Data], version: Int = 1, generation: UInt64? = nil) {
        value = SyncManifest(version: version, files: files.mapValues(digest), generation: generation)
        for data in files.values { objects[digest(data)] = data }
        revision = (revision ?? 0) + 1
    }
    func reject() { rejectPublish = true }
    func acceptPublishes() { rejectPublish = false }
    func corruptDownloads() { corrupt = true }
    func loseManifest() { revision = nil; value = SyncManifest() }
}
/// Model an editor whose latest content has not reached disk yet.
private final class UnsavedFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let content: Data
    init(url: URL, content: Data) {
        presentedItemURL = url; self.content = content
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        do {
            try content.write(to: presentedItemURL!, options: .atomic)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}

final class SyncTests {
    let base: URL
    let root: URL
    let recovery: URL
    let vault: Vault
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("phone")
        recovery = base.appendingPathComponent("recovery")
        vault = try Vault(root: root, recovery: recovery)
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    @Test func foldersMoveAndEmptyFolders() async throws {
        try await vault.createFolder(path: "读书/文学")
        #expect(try await vault.scan().folders == ["读书", "读书/文学"])
        _ = try await vault.create(path: "读书/文学/笔记.md", text: "text")
        try await vault.move(path: "读书/文学", to: "归档/文学")
        #expect(try await vault.scan().notes.first?.path == "归档/文学/笔记.md")
        await #expect(throws: VaultError.self) { try await self.vault.move(path: "归档", to: "归档/子目录") }
    }
    @Test func twoDevicesRoundTripAttachmentsRenameAndDelete() async throws {
        let remote = MemoryRemote()
        let pc = try Vault(root: base.appendingPathComponent("pc"), recovery: base.appendingPathComponent("pc-state"))
        _ = try await pc.create(path: "项目/想法.md", text: "desktop")
        let image = Data([0, 255, 1, 128])
        try image.write(to: base.appendingPathComponent("pc/项目/附件.png"))
        _ = try await pc.synchronize(remote: remote)
        _ = try await vault.synchronize(remote: remote)
        #expect(try await vault.scan().notes.first?.text == "desktop")
        #expect(try Data(contentsOf: root.appendingPathComponent("项目/附件.png")) == image)
        _ = try await vault.save(path: "项目/想法.md", text: "mobile", expected: "desktop")
        try await vault.move(path: "项目/想法.md", to: "归档/想法.md")
        _ = try await vault.synchronize(remote: remote)
        _ = try await pc.synchronize(remote: remote)
        #expect(try await pc.scan().notes.first?.path == "归档/想法.md")
        #expect(try await pc.scan().notes.first?.text == "mobile")
        try await pc.trash(path: "归档/想法.md", expected: "mobile")
        _ = try await pc.synchronize(remote: remote)
        _ = try await vault.synchronize(remote: remote)
        #expect(try await vault.scan().notes.isEmpty)
        #expect(try await vault.records().contains { $0.text == "mobile" })
    }
    @Test func simultaneousEditsAndDeleteModifyKeepBothContents() async throws {
        let remote = MemoryRemote()
        await remote.set(["a.md": Data("base".utf8)])
        _ = try await vault.synchronize(remote: remote)
        _ = try await vault.save(path: "a.md", text: "phone", expected: "base")
        await remote.set(["a.md": Data("pc".utf8)])
        let report = try await vault.synchronize(remote: remote)
        #expect(report.conflicts == ["a.md"])
        #expect(Set(try await vault.scan().notes.map(\.text)) == ["phone", "pc"])
        try await vault.trash(path: "a.md", expected: "phone")
        let current = await remote.manifest().0
        var files = current.files.mapValues { _ in Data("pc".utf8) }
        files["a.md"] = Data("pc edited again".utf8)
        await remote.set(files)
        _ = try await vault.synchronize(remote: remote)
        #expect(try await vault.scan().notes.contains { $0.text == "pc edited again" })
    }
    @Test func stalePublishAndCorruptDownloadDoNotChangeLocalFiles() async throws {
        let remote = MemoryRemote()
        _ = try await vault.create(path: "local.md", text: "safe")
        await remote.set(["remote.md": Data("remote".utf8)])
        await remote.reject()
        await #expect(throws: SyncFailure.self) { _ = try await self.vault.synchronize(remote: remote) }
        #expect(try await vault.scan().notes.map(\.path) == ["local.md"])
        let corrupt = MemoryRemote(identity: "corrupt-endpoint\nuser")
        await corrupt.set(["bad.md": Data("correct".utf8)])
        await corrupt.corruptDownloads()
        await #expect(throws: SyncFailure.self) { _ = try await self.vault.synchronize(remote: corrupt) }
        #expect(try await vault.scan().notes.map(\.path) == ["local.md"])
    }
    @Test func missingManifestAndGenerationRollbackAreRejected() async throws {
        let remote = MemoryRemote()
        await remote.set(["a.md": Data("safe".utf8)], version: 2, generation: 3)
        _ = try await vault.synchronize(remote: remote)
        #expect(await remote.manifest().0.generation == 3)
        await remote.set([:], version: 2, generation: 2)
        await #expect(throws: SyncFailure.self) { _ = try await self.vault.synchronize(remote: remote) }
        await remote.loseManifest()
        await #expect(throws: SyncFailure.self) { _ = try await self.vault.synchronize(remote: remote) }
        #expect(try await vault.scan().notes.first?.text == "safe")
    }
    @Test func mutationsAndOverlappingSyncAreRejectedDuringNetworkWait() async throws {
        let remote = MemoryRemote()
        await remote.pause()
        let task = Task { try await vault.synchronize(remote: remote) }
        await remote.waitUntilPaused()
        await #expect(throws: VaultError.self) { _ = try await self.vault.create(path: "blocked.md", text: "blocked") }
        await #expect(throws: VaultError.self) { try await self.vault.createFolder(path: "blocked") }
        await #expect(throws: VaultError.self) { _ = try await self.vault.synchronize(remote: remote) }
        await remote.resume()
        _ = try await task.value
        _ = try await vault.create(path: "allowed.md", text: "allowed")
        #expect(try await vault.scan().notes.map(\.path) == ["allowed.md"])
    }
    @Test func unchangedSyncSkipsTransfersPreparationAndPublish() async throws {
        let remote = MemoryRemote()
        _ = try await vault.create(path: "a.md", text: "same")
        _ = try await vault.synchronize(remote: remote)
        let revision = await remote.revision
        let preparations = await remote.prepareCount
        let uploads = await remote.uploadCount
        let baseline = recovery.appendingPathComponent(".sync/" + digest(Data(remote.identity.utf8)) + "/baseline.json")
        let timestamp = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: baseline.path)
        let report = try await vault.synchronize(remote: remote)
        let attributes = try FileManager.default.attributesOfItem(atPath: baseline.path)
        #expect(attributes[.modificationDate] as? Date == timestamp)
        #expect(report.uploaded == 0 && report.downloaded == 0)
        #expect(!report.changed)
        #expect(await remote.revision == revision)
        #expect(await remote.prepareCount == preparations)
        #expect(await remote.uploadCount == uploads)
        #expect(await remote.downloadCount == 0)
    }
    @Test func pathOnlySyncCountsAsActivityWithoutUploadingBytes() async throws {
        let remote = MemoryRemote()
        _ = try await vault.create(path: "a.md", text: "same")
        _ = try await vault.synchronize(remote: remote)
        try await vault.move(path: "a.md", to: "b.md")
        let report = try await vault.synchronize(remote: remote)
        #expect(report.changed)
        #expect(report.uploaded == 0)
    }
    @Test func emptyFirstSyncCreatesManifest() async throws {
        let remote = MemoryRemote()
        _ = try await vault.synchronize(remote: remote)
        #expect(await remote.revision != nil)
        _ = try await vault.synchronize(remote: remote)
    }
    @Test func transfersOverlapWithinBoundAndPreserveContents() async throws {
        let remote = MemoryRemote()
        await remote.enableDelay()
        for i in 0..<9 { _ = try await vault.create(path: "upload-\(i).md", text: "upload \(i)") }
        await remote.set(Dictionary(uniqueKeysWithValues: (0..<9).map { ("download-\($0).md", Data("download \($0)".utf8)) }))
        let report = try await vault.synchronize(remote: remote)
        #expect(report.uploaded == 9 && report.downloaded == 9)
        #expect(await remote.maxTransfers > 1)
        #expect(await remote.maxTransfers <= 3)
        #expect(await remote.activeTransfers == 0)
        #expect(try await vault.scan().notes.count == 18)
    }
    @Test func onlyChangedContentIsStagedAndTimestampPreservingEditsAreFound() async throws {
        let remote = MemoryRemote()
        for i in 0..<5 { _ = try await vault.create(path: "\(i).md", text: "old \(i)") }
        _ = try await vault.synchronize(remote: remote)
        let file = root.appendingPathComponent("0.md")
        let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try Data("new 0".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        await remote.reject()
        await #expect(throws: SyncFailure.self) { _ = try await self.vault.synchronize(remote: remote) }
        let objects = recovery.appendingPathComponent(".sync/" + digest(Data(remote.identity.utf8)) + "/objects")
        #expect(try FileManager.default.contentsOfDirectory(atPath: objects.path) == [digest(Data("new 0".utf8))])
        #expect(try String(contentsOf: file, encoding: .utf8) == "new 0")
    }
    @Test func batchedReadsAskFilePresentersToSaveBeforeHashing() async throws {
        let remote = MemoryRemote()
        _ = try await vault.create(path: "note.md", text: "on disk")
        let current = Data("unsaved editor content".utf8)
        let presenter = UnsavedFilePresenter(url: root.appendingPathComponent("note.md"), content: current)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        _ = try await vault.synchronize(remote: remote)
        let hash = digest(current)
        #expect(await remote.value.files["note.md"] == hash)
        #expect(await remote.objects[hash] == current)
    }

    @Test func externalEditDuringTransferAbortsBeforePublishEvenWithSameTimestamp() async throws {
        let remote = MemoryRemote()
        _ = try await vault.create(path: "local.md", text: "before")
        let file = root.appendingPathComponent("local.md")
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        await remote.set(["remote.md": Data("remote".utf8)])
        let revision = await remote.revision
        await remote.pause()
        let task = Task { try await vault.synchronize(remote: remote) }
        await remote.waitUntilPaused()
        try Data("edited".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        await remote.resume()
        do { _ = try await task.value; Issue.record("Expected prepublication conflict") }
        catch VaultError.conflict {}
        #expect(await remote.revision == revision)
        #expect(try String(contentsOf: file, encoding: .utf8) == "edited")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("remote.md").path))
        #expect(await remote.activeTransfers == 0)
        // Retry must release the failed batch and stage the new content.
        _ = try await vault.synchronize(remote: remote)
        #expect(await remote.value.files["local.md"] == digest(Data("edited".utf8)))
    }
    @Test func cancellationBeforePublishLeavesLocalFilesAndRemoteManifestUntouched() async throws {
        let remote = MemoryRemote()
        _ = try await vault.create(path: "local.md", text: "safe")
        await remote.set(["remote.md": Data("remote".utf8)])
        let revision = await remote.revision
        await remote.pause()
        let task = Task { try await vault.synchronize(remote: remote) }
        await remote.waitUntilPaused()
        task.cancel()
        await remote.resume()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        #expect(await remote.revision == revision)
        #expect(await remote.activeTransfers == 0)
        #expect(try await vault.scan().notes.map(\.path) == ["local.md"])
        _ = try await vault.synchronize(remote: remote)
        #expect(try await vault.scan().notes.count == 2)
    }
    @Test func batchedScanRejectsSymlinksAndOversizedFilesAndReleasesOnFailure() async throws {
        let remote = MemoryRemote()
        let outside = base.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        await #expect(throws: VaultError.self) { _ = try await self.vault.synchronize(remote: remote) }
        #expect(await remote.revision == nil)
        try FileManager.default.removeItem(at: link)
        let large = root.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 129 * 1024 * 1024)
        try handle.close()
        await #expect(throws: SyncFailure.self) { _ = try await self.vault.synchronize(remote: remote) }
        #expect(await remote.revision == nil)
        try FileManager.default.removeItem(at: large)
        _ = try await vault.create(path: "safe.md", text: "safe")
        _ = try await vault.synchronize(remote: remote)
        #expect(await remote.value.files == ["safe.md": digest(Data("safe".utf8))])
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    }

    @Test func pathValidationKeepsUnicodeAndByteLimits() throws {
        let valid = ["资料 %2E%2E/笔记😀.md", "cafe\u{301}/百分号%25.md", "COM１.md", "a..b.md",
                     String(repeating: "a", count: 255), String(repeating: "a/", count: 2047) + "bb"]
        for path in valid { try SyncManifest.validatePath(path) }
        let invalid = ["/a", "a//b", "a/", ".hidden/a", "a/..", "cOn.txt", "com0.md", "lpt9.md",
                       "a ", "a.", "a\u{7f}.md", "a\u{85}.md", "a?.md", "a|b.md", "joined👩‍💻.md",
                       String(repeating: "中", count: 86), String(repeating: "a", count: 256),
                       String(repeating: "a/", count: 2047) + "bbb"]
        for path in invalid { #expect(throws: VaultError.self) { try SyncManifest.validatePath(path) } }
    }
    @Test func unicodeAndPercentPathsRoundTripAndCorruptStagingIsRevalidated() async throws {
        let path = "资料 %2E%2E/cafe\u{301}😀%25.md"
        let content = Data("正文保持原样".utf8)
        _ = try await vault.create(path: path, text: String(decoding: content, as: UTF8.self))
        let rejecting = MemoryRemote()
        await rejecting.reject()
        await #expect(throws: SyncFailure.self) { _ = try await self.vault.synchronize(remote: rejecting) }
        let staged = recovery.appendingPathComponent(".sync/" + digest(Data(rejecting.identity.utf8)) + "/objects/" + digest(content))
        try Data("corrupted cache".utf8).write(to: staged)
        let remote = MemoryRemote()
        let report = try await vault.synchronize(remote: remote)
        #expect(report.uploaded == 1)
        #expect(await remote.value.files == [path: digest(content)])
        #expect(await remote.objects[digest(content)] == content)
        let receiver = try Vault(root: base.appendingPathComponent("receiver"), recovery: base.appendingPathComponent("receiver-state"))
        let received = try await receiver.synchronize(remote: remote)
        #expect(received.downloaded == 1 && received.uploaded == 0)
        #expect(try Data(contentsOf: base.appendingPathComponent("receiver").appendingPathComponent(path)) == content)
    }
    @Test func replacingParentWithSymlinkDuringSyncCannotBypassPathChecks() async throws {
        _ = try await vault.create(path: "folder/note.md", text: "safe")
        let remote = MemoryRemote()
        await remote.pause()
        let task = Task { try await vault.synchronize(remote: remote) }
        await remote.waitUntilPaused()
        let folder = root.appendingPathComponent("folder")
        let outside = base.appendingPathComponent("moved-folder")
        try FileManager.default.moveItem(at: folder, to: outside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        await remote.resume()
        do { _ = try await task.value; Issue.record("Expected symlink rejection") }
        catch VaultError.invalidPath {}
        #expect(await remote.revision == nil)
        #expect(try String(contentsOf: outside.appendingPathComponent("note.md"), encoding: .utf8) == "safe")
    }

    @Test func protocolValidation() throws {
        for path in ["a//b", "../x", "a/", "CON.md", "a\\b", "a:1", "a/hidden.", "LPT1.txt"] {
            #expect(throws: VaultError.self) { try SyncManifest.validatePath(path) }
        }
        #expect(throws: Error.self) { try SyncManifest.decode(Data(#"{"version":3,"files":{}}"#.utf8)) }
        #expect(throws: Error.self) { try SyncManifest.decode(Data(#"{"version":1,"files":{},"unknown":true}"#.utf8)) }
        #expect(throws: Error.self) { try SyncManifest(files: ["A.md": digest(Data()), "a.md": digest(Data())]).validate() }
        #expect(throws: Error.self) { try SyncManifest(files: ["a": digest(Data()), "a/b.md": digest(Data())]).validate() }
        #expect(WebDAV.strongETag("\"a,b\\c\""))
        for tag in ["W/\"a\"", "\"a\", \"b\"", "a", "\"a\n\""] { #expect(!WebDAV.strongETag(tag)) }
    }
    @Test func resumesConfirmedPublishWithoutResurrectingDeletedFiles() async throws {
        let remote = MemoryRemote()
        _ = try await vault.create(path: "a.md", text: "before")
        _ = try await vault.synchronize(remote: remote)
        let state = recovery.appendingPathComponent(".sync/" + digest(Data(remote.identity.utf8)))
        let target = SyncManifest(files: ["b.md": digest(Data("new".utf8))])
        let pending: [String: Any] = ["before": ["a.md": digest(Data("before".utf8))], "target": ["version": 1, "files": target.files]]
        try FileManager.default.createDirectory(at: state.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: state.appendingPathComponent("objects/" + digest(Data("new".utf8))))
        try JSONSerialization.data(withJSONObject: pending).write(to: state.appendingPathComponent("pending.json"))
        // Simulate a crash after deleting a.md but before installing b.md.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.md"))
        await remote.set(["b.md": Data("new".utf8)])
        _ = try await vault.synchronize(remote: remote)
        #expect(try await vault.scan().notes.map(\.path) == ["b.md"])
        #expect(await remote.manifest().0.files == target.files)
    }
}

extension SyncTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"] != nil))
    func desktopHTTPInterop() async throws {
        let env = ProcessInfo.processInfo.environment
        let endpoint = try #require(env["INKSTONE_INTEROP_URL"])
        let executable = try #require(env["INKSTONE_INTEROP_DESKTOP"])
        let pcRoot = base.appendingPathComponent("desktop")
        try FileManager.default.createDirectory(at: pcRoot.appendingPathComponent("项目/资料"), withIntermediateDirectories: true)
        let pcNote = pcRoot.appendingPathComponent("项目/资料/笔记.md")
        try Data("desktop original".utf8).write(to: pcNote)
        let attachment = Data([0, 1, 255, 254, 128])
        try attachment.write(to: pcRoot.appendingPathComponent("项目/资料/image.bin"))
        func desktopSync() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [pcRoot.path, base.appendingPathComponent("desktop-state").path, endpoint]
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        var settings = WebDAVSettings(); settings.url = endpoint; settings.username = "interop"
        let remote = try WebDAV(settings: settings, password: "test-only")
        try desktopSync()
        _ = try await vault.synchronize(remote: remote)
        #expect(try await vault.scan().notes.first?.text == "desktop original")
        #expect(try Data(contentsOf: root.appendingPathComponent("项目/资料/image.bin")) == attachment)
        _ = try await vault.save(path: "项目/资料/笔记.md", text: "phone edit", expected: "desktop original")
        _ = try await vault.synchronize(remote: remote)
        try desktopSync()
        #expect(try String(contentsOf: pcNote, encoding: .utf8) == "phone edit")
        try Data("pc conflict".utf8).write(to: pcNote)
        _ = try await vault.save(path: "项目/资料/笔记.md", text: "phone conflict", expected: "phone edit")
        try desktopSync()
        let report = try await vault.synchronize(remote: remote)
        #expect(report.conflicts.count == 1)
        try desktopSync()
        #expect(try String(contentsOf: pcNote, encoding: .utf8) == "phone conflict")
        #expect(try await vault.scan().notes.contains { $0.text == "pc conflict" })
        try await vault.move(path: "项目/资料/笔记.md", to: "归档/笔记.md")
        _ = try await vault.synchronize(remote: remote)
        try desktopSync()
        #expect(!FileManager.default.fileExists(atPath: pcNote.path))
        #expect(try String(contentsOf: pcRoot.appendingPathComponent("归档/笔记.md"), encoding: .utf8) == "phone conflict")
        try FileManager.default.removeItem(at: pcRoot.appendingPathComponent("归档/笔记.md"))
        try desktopSync()
        _ = try await vault.synchronize(remote: remote)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("归档/笔记.md").path))
    }
}
