import Foundation
import Testing
@testable import InkstoneCore

struct HTTPRecoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"] != nil))
    func httpTimeoutReturnsFailureAndAllowsRetry() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"])
        var settings = WebDAVSettings()
        settings.url = try #require(URL(string: endpoint)).deletingLastPathComponent()
            .appendingPathComponent("timeout-dav/" + UUID().uuidString).absoluteString
        settings.allowInsecureHTTP = true; settings.username = "interop"
        let remote = try WebDAV(settings: settings, password: "test-only", requestTimeout: 0.2, resourceTimeout: 0.5)
        do {
            _ = try await remote.manifest()
            Issue.record("Stalled response was treated as a successful manifest")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        let (manifest, revision) = try await remote.manifest()
        #expect(manifest.files.isEmpty && revision == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"] != nil))
    func httpInterruptedSyncRecoversLostPublicationAndPartialDownloadAfterRestart() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = WebDAVSettings()
        settings.url = try #require(URL(string: endpoint)).deletingLastPathComponent()
            .appendingPathComponent("fault-dav/" + UUID().uuidString).absoluteString
        settings.allowInsecureHTTP = true
        settings.username = "interop"
        let remote = try WebDAV(settings: settings, password: "test-only")
        let source = try Vault(root: root.appendingPathComponent("source"), recovery: root.appendingPathComponent("source-state"))
        let text = String(repeating: "恢复中的中文正文😀\n", count: 1024)
        _ = try await source.create(path: "note.md", text: text)
        await #expect(throws: (any Error).self) { try await source.synchronize(remote: remote) }
        #expect(try await source.scan().notes.first?.text == text)
        let committed = try await remote.manifest().0
        #expect(committed.files["note.md"] == digest(Data(text.utf8)))
        let restarted = try Vault(root: root.appendingPathComponent("source"), recovery: root.appendingPathComponent("source-state"))
        _ = try await restarted.synchronize(remote: WebDAV(settings: settings, password: "test-only"))
        #expect(try await restarted.scan().notes.map(\.path) == ["note.md"])
        #expect(try await remote.manifest().0.files == committed.files)

        let receiver = try Vault(root: root.appendingPathComponent("receiver"), recovery: root.appendingPathComponent("receiver-state"))
        await #expect(throws: (any Error).self) { try await receiver.synchronize(remote: remote) }
        #expect(try await receiver.scan().notes.isEmpty)
        #expect(try await remote.manifest().0.files == committed.files)
        let resumed = try Vault(root: root.appendingPathComponent("receiver"), recovery: root.appendingPathComponent("receiver-state"))
        _ = try await resumed.synchronize(remote: WebDAV(settings: settings, password: "test-only"))
        #expect(try await resumed.scan().notes.map(\.text) == [text])
        _ = try await resumed.synchronize(remote: remote)
        #expect(try await remote.manifest().0.files == committed.files)
    }
}
