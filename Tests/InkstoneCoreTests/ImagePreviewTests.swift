import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import InkstoneCore

func imageFixture(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
private actor ImageLoadMeter {
    var count = 0, active = 0, peak = 0
    func load(_ data: Data) async throws -> Data {
        count += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        return data
    }
}
struct ImagePreviewTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"] != nil))
    func remoteImagePreviewDownloadsThumbnailAndRejectsOversizedResponse() async throws {
        var settings = WebDAVSettings()
        settings.url = try #require(ProcessInfo.processInfo.environment["INKSTONE_INTEROP_URL"])
        settings.username = "interop"
        let remote = try WebDAV(settings: settings, password: "test-only")
        try await remote.prepare()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pipeline = ImagePreviewPipeline()
        let context = ImageResourceContext(library: "remote", notePath: "images.md", generation: "0")
        for oversized in [false, true] {
            let data = oversized ? Data(repeating: 0, count: 33 * 1024 * 1024) : try imageFixture(width: 2400, height: 1200)
            try data.write(to: file)
            let hash = digest(data)
            try await remote.upload(hash, from: file)
            let url = try #require(URL(string: settings.url)).deletingLastPathComponent().appendingPathComponent("image-test/" + hash)
            do {
                let preview = try await pipeline.preview(source: url.absoluteString, context: context, maxPixelSize: 640) { _ in
                    Issue.record("Remote preview unexpectedly called the local loader")
                    throw VaultError.invalidPath
                }
                #expect(!oversized)
                #expect(preview.image.width == 640 && preview.image.height == 320)
            } catch {
                #expect(oversized)
                // The response must be rejected by the transfer cap, before image decoding.
                #expect(error is URLError || error is VaultError, "Unexpected transfer error: \(type(of: error)) \(error)")
            }
        }
    }
    @Test func cacheIdentityIncludesLibraryNoteAttachmentAndRefreshGeneration() async throws {
        let pipeline = ImagePreviewPipeline()
        let first = ImageResourceContext(library: "one", notePath: "a.md", generation: "0")
        let data = try imageFixture(width: 64, height: 32)
        let meter = ImageLoadMeter()
        for context in [first, first,
            ImageResourceContext(library: "two", notePath: "a.md", generation: "0"),
            ImageResourceContext(library: "one", notePath: "b.md", generation: "0"),
            ImageResourceContext(library: "one", notePath: "a.md", generation: "1")] {
            let preview = try await pipeline.preview(source: "attachments/image.png", context: context) { _ in try await meter.load(data) }
            #expect(preview.image.width == 64 && preview.image.height == 32)
        }
        #expect(await meter.count == 4)
        _ = try await pipeline.preview(source: "attachments/other.png", context: first) { _ in try await meter.load(data) }
        #expect(await meter.count == 5)
    }
    @Test func concurrentLoadsAreBoundedAndOversizedOrInvalidInputsAreRejected() async throws {
        let pipeline = ImagePreviewPipeline(concurrency: 2, cacheBudget: 0)
        let context = ImageResourceContext(library: "one", notePath: "images.md", generation: "0")
        let data = try imageFixture(width: 1600, height: 800)
        let meter = ImageLoadMeter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let preview = try await pipeline.preview(source: "\(index).png", context: context, maxPixelSize: 640) { _ in try await meter.load(data) }
                    #expect(preview.image.width == 640 && preview.image.height == 320)
                }
            }
            try await group.waitForAll()
        }
        #expect(await meter.peak == 2)
        #expect(await meter.active == 0)
        await #expect(throws: VaultError.self) {
            _ = try await pipeline.preview(source: "big.png", context: context) { _ in Data(repeating: 0, count: 32 * 1024 * 1024 + 1) }
        }
        await #expect(throws: SyncFailure.self) {
            _ = try await pipeline.preview(source: "bad.png", context: context) { _ in Data("not an image".utf8) }
        }
        let excessiveWidth = try imageFixture(width: 20_001, height: 1)
        await #expect(throws: SyncFailure.self) {
            _ = try await pipeline.preview(source: "wide.png", context: context) { _ in excessiveWidth }
        }
        let cancelled = Task { try await pipeline.preview(source: "cancel.png", context: context) { _ in try await meter.load(data) } }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled image request completed") } catch is CancellationError {}
        let next = try await pipeline.preview(source: "next.png", context: context, maxPixelSize: 320) { _ in data }
        #expect(next.image.width == 320)
    }
}
