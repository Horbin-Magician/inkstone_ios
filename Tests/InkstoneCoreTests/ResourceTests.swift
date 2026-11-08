import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import InkstoneCore

struct ResourceTests {
    @Test func thumbnailBoundsPixelsAndRejectsInvalidImages() throws {
        let context = try #require(CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let original = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, nil)
        #expect(CGImageDestinationFinalize(destination))
        let thumbnail = try #require(AttachmentThumbnail.make(data: data as Data, maxPixelSize: 640))
        #expect(thumbnail.width == 640)
        #expect(thumbnail.height == 320)
        let preview = try #require(AttachmentThumbnail.webPreview(data: data as Data, maxPixelSize: 640))
        let previewSource = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(previewSource, 0, nil))
        #expect(decoded.width == 640 && decoded.height == 320)
        #expect(AttachmentThumbnail.webPreview(data: preview, maxPixelSize: 640) == nil)
        #expect(AttachmentThumbnail.webPreview(data: Data([0xff])) == nil)
        let animated = NSMutableData()
        let gif = try #require(CGImageDestinationCreateWithData(animated, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(gif, original, nil)
        CGImageDestinationAddImage(gif, original, nil)
        #expect(CGImageDestinationFinalize(gif))
        #expect(AttachmentThumbnail.webPreview(data: animated as Data, maxPixelSize: 640) == nil)
        #expect(AttachmentThumbnail.make(data: Data([0xff, 0]), maxPixelSize: 640) == nil)
        #expect(AttachmentThumbnail.make(data: data as Data, maxPixelSize: 0) == nil)
    }

    @Test func streamedHashesMatchWholeFileAndEnforceSizeLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("binary")
        for size in [0, 1, 256 * 1024, 700_003] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            try data.write(to: file)
            #expect(try digestFile(file) == digest(data))
        }
        #expect(throws: SyncFailure.self) { try digestFile(file, limit: 256 * 1024) }
    }

    @Test func streamingArchivePreservesMultipleChunksAndEmptyFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("vault")
        let vault = try Vault(root: root, recovery: directory.appendingPathComponent("recovery"))
        let content = Data((0..<700_003).map { UInt8(truncatingIfNeeded: $0) })
        try content.write(to: root.appendingPathComponent("附件.bin"))
        _ = try await vault.create(path: "empty.md", text: "")
        let bytes = try await vault.exportArchive()
        let archive = directory.appendingPathComponent("backup.zip")
        try bytes.write(to: archive)
        #if os(macOS)
        let extracted = directory.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: extracted.appendingPathComponent("附件.bin")) == content)
        #expect(try Data(contentsOf: extracted.appendingPathComponent("empty.md")).isEmpty)
        #endif
        let large = root.appendingPathComponent("too-large.bin")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 128 * 1024 * 1024 + 1); try handle.close()
        do { _ = try await vault.exportArchive(); Issue.record("Oversized archive accepted") }
        catch VaultError.backupTooLarge {}
    }
}
