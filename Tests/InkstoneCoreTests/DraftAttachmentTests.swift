import Foundation
import Testing
@testable import InkstoneCore

struct DraftAttachmentTests {
    @Test(arguments: ["", "命名", "命名.MD"])
    func selectedFolderOwnsBodyAndAttachment(filename: String) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault"), recovery = base.appendingPathComponent("recovery")
        let vault = try Vault(root: root, recovery: recovery)
        let path = try Note.draftPath(folder: "选中/子目录", filename: filename, fallback: "原目录/未命名.md")
        let created = try await vault.create(path: path, text: "")
        let image = Data([1, 2, 3, 4])
        let link = try await vault.insertAttachment(image, extension: "png", from: created.path)
        _ = try await vault.save(path: created.path, text: "![图片](\(link))", expected: "")
        let reopened = try Vault(root: root, recovery: recovery)
        #expect(try await reopened.attachment(link, from: path) == image)
        #expect(path.hasPrefix("选中/子目录/"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("原目录").path))
    }
}
