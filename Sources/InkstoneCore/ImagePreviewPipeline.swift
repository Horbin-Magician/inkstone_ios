import Foundation
import CoreGraphics
import ImageIO

public struct ImageResourceContext: Hashable, Sendable {
    public let library: String
    public let notePath: String
    public let generation: String
    public init(library: String, notePath: String, generation: String) {
        self.library = library; self.notePath = notePath; self.generation = generation
    }
    public var token: String { digest(Data((library + "\0" + notePath + "\0" + generation).utf8)) }
}

/// CGImage is immutable; the encoded preview and decoded thumbnail share one budget.
public struct ImagePreview: @unchecked Sendable {
    public let image: CGImage
    public let data: Data
    public let mimeType: String
    var cost: Int { image.bytesPerRow * image.height + data.count }
}

public actor ImagePreviewPipeline {
    public static let shared = ImagePreviewPipeline()
    private struct Key: Hashable { let context: ImageResourceContext; let source: String; let pixels: Int }
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private let concurrency: Int
    private let cacheBudget: Int
    private var active = 0
    private var waiters: [Waiter] = []
    private var cache: [Key: ImagePreview] = [:]
    private var order: [Key] = []
    private var cacheCost = 0
    public init(concurrency: Int = 3, cacheBudget: Int = 64 * 1024 * 1024) {
        self.concurrency = max(1, concurrency); self.cacheBudget = max(0, cacheBudget)
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if active < concurrency { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().continuation.resume() }
    }
    private func cached(_ key: Key) -> ImagePreview? {
        guard let result = cache[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return result
    }
    public func preview(source: String, context: ImageResourceContext, maxPixelSize: Int = 1920,
                        loader: @escaping @Sendable (String) async throws -> Data) async throws -> ImagePreview {
        let key = Key(context: context, source: source, pixels: max(1, min(1920, maxPixelSize)))
        try Task.checkCancellation()
        if let result = cached(key) { return result }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        if let result = cached(key) { return result }
        let data: Data
        if let url = URL(string: source), let scheme = url.scheme {
            guard ["http", "https"].contains(scheme.lowercased()), url.user == nil, url.password == nil else { throw VaultError.invalidPath }
            data = try await Self.download(url)
        } else { data = try await loader(source) }
        guard data.count <= 32 * 1024 * 1024 else { throw VaultError.attachmentTooLarge }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try autoreleasepool { try Self.decode(data, pixels: key.pixels) }
            try Task.checkCancellation()
            return result
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        if result.cost <= cacheBudget {
            if let old = cache.removeValue(forKey: key) { cacheCost -= old.cost; order.removeAll { $0 == key } }
            while !order.isEmpty && (cacheCost + result.cost > cacheBudget || order.count >= 128) {
                let oldKey = order.removeFirst()
                if let old = cache.removeValue(forKey: oldKey) { cacheCost -= old.cost }
            }
            cache[key] = result; order.append(key); cacheCost += result.cost
        }
        return result
    }
    private nonisolated static func decode(_ data: Data, pixels: Int) throws -> ImagePreview {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              Int64(width) * Int64(height) <= 100_000_000,
              let image = AttachmentThumbnail.make(data: data, maxPixelSize: pixels) else {
            throw SyncFailure("图片格式无效或像素尺寸超过预览限制。")
        }
        let frames = CGImageSourceGetCount(source)
        // Keep bounded small animations in WebKit; larger ones use a first-frame preview.
        if frames > 1, max(width, height) <= pixels,
           frames <= 100, Int64(width) * Int64(height) * Int64(frames) <= 20_000_000,
           let type = CGImageSourceGetType(source) as String?, type == "com.compuserve.gif" {
            return ImagePreview(image: image, data: data, mimeType: "image/gif")
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return ImagePreview(image: image, data: encoded as Data, mimeType: "image/png")
    }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()
    private nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let limiter = ImageDownloadLimit()
        let (file, response) = try await session.download(for: request, delegate: limiter)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard !limiter.exceeded, response.expectedContentLength <= 32 * 1024 * 1024, size <= 32 * 1024 * 1024 else { throw VaultError.attachmentTooLarge }
        guard response.expectedContentLength < 0 || size == response.expectedContentLength else { throw URLError(.networkConnectionLost) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return data
    }
}

private final class ImageDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didExceed = false
    var exceeded: Bool { lock.withLock { didExceed } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 32 * 1024 * 1024 || totalBytesExpectedToWrite > 32 * 1024 * 1024 {
            lock.withLock { didExceed = true }
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
