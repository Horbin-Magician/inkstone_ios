import Foundation
import Darwin
import CoreGraphics
import ImageIO
import Testing
@testable import InkstoneCore

struct ImagePreviewBenchmarks {
    private var file: URL { get throws { URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["INKSTONE_IMAGE_FIXTURE_PATH"])) } }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_IMAGE_BENCHMARK"] == "1"))
    func prepareLargeImageFixture() throws {
        try imageFixture(width: 6000, height: 4000).write(to: file)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_IMAGE_BENCHMARK"] == "1"))
    func imageDecodeBaseline() throws {
        let data = try Data(contentsOf: file)
        let clock = ContinuousClock(), start = ContinuousClock.now
        let images = try (0..<6).map { _ in
            try autoreleasepool {
                let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                return try #require(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("IMAGE_BENCH original six24MP duration=\(start.duration(to: clock.now)) peakRSSBytes=\(usage.ru_maxrss) decodedBytes=\(images.reduce(0) { $0 + $1.bytesPerRow * $1.height })")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKSTONE_IMAGE_BENCHMARK"] == "1"))
    func imageDecodeThumbnails() async throws {
        let data = try Data(contentsOf: file)
        let clock = ContinuousClock(), start = ContinuousClock.now
        let pipeline = ImagePreviewPipeline()
        let context = ImageResourceContext(library: "benchmark", notePath: "images.md", generation: "0")
        let previews = try await withThrowingTaskGroup(of: ImagePreview.self) { group in
            for i in 0..<6 { group.addTask { try await pipeline.preview(source: "\(i).png", context: context) { _ in data } } }
            var previews: [ImagePreview] = []
            for try await preview in group { previews.append(preview) }
            return previews
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        #expect(previews.allSatisfy { max($0.image.width, $0.image.height) <= 1920 })
        print("IMAGE_BENCH preview six24MP duration=\(start.duration(to: clock.now)) peakRSSBytes=\(usage.ru_maxrss) decodedBytes=\(previews.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height })")
    }
}
