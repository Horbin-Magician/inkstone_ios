import Foundation

public struct WebDAVSettings: Codable, Equatable, Sendable {
    public var url = ""
    public var username = ""
    public var allowInsecureHTTP = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case url, username, allowInsecureHTTP }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(String.self, forKey: .url)
        username = try values.decode(String.self, forKey: .username)
        allowInsecureHTTP = try values.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
    }
    public func endpoint() throws -> URL {
        let endpoint = try normalizedEndpoint()
        guard endpoint.scheme?.lowercased() != "http" || allowInsecureHTTP else {
            throw SyncFailure("此地址使用未加密的 HTTP。请改用 HTTPS，或在连接配置中明确开启 HTTP 兼容选项。")
        }
        return endpoint
    }
    /// Reading an existing Keychain identity must not opt a legacy HTTP server
    /// into network access or change its previously stored password key.
    public func credentialIdentity() throws -> String {
        try normalizedEndpoint().absoluteString + "\n" + username
    }
    private func normalizedEndpoint() throws -> URL {
        let input = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.hasPrefix("/") else { throw VaultError.invalidPath }
        let address = input.contains("://") ? input : "https://" + input
        guard var parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw SyncFailure("请输入有效的 WebDAV 目录地址，默认使用 HTTPS；账号填写在用户名栏。")
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if !parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath += "/" }
        guard let result = parts.url else { throw VaultError.invalidPath }
        return result
    }
}
protocol SyncRemote: Sendable {
    var identity: String { get }
    func prepare() async throws
    func manifest() async throws -> (SyncManifest, String?)
    func download(_ hash: String, to file: URL) async throws
    func upload(_ hash: String, from file: URL) async throws
    func publish(_ manifest: SyncManifest, revision: String?) async throws
}
private final class BoundedResponse: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let bodyFile: URL?
    private let lock = NSLock()
    private var _exceeded = false
    var exceeded: Bool { lock.withLock { _exceeded } }
    init(limit: Int, bodyFile: URL? = nil) { self.limit = Int64(limit); self.bodyFile = bodyFile }
    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(bodyFile.flatMap { InputStream(url: $0) })
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            lock.withLock { _exceeded = true }
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class WebDAV: SyncRemote, @unchecked Sendable {
    private let root: URL
    private let authorization: String
    private let session: URLSession
    public let identity: String
    public convenience init(settings: WebDAVSettings, password: String) throws {
        try self.init(settings: settings, password: password, requestTimeout: 60, resourceTimeout: 300)
    }
    // Internal injection keeps timeout recovery testable without minute-long waits.
    init(settings: WebDAVSettings, password: String, requestTimeout: TimeInterval, resourceTimeout: TimeInterval) throws {
        root = try settings.endpoint()
        guard !settings.username.contains(where: { $0 == ":" || $0 == "\n" || $0 == "\r" }) else {
            throw SyncFailure("用户名不能包含冒号或换行符。")
        }
        identity = root.absoluteString + "\n" + settings.username
        authorization = "Basic " + Data((settings.username + ":" + password).utf8).base64EncodedString()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }
    private static let retryableStatusCodes: Set<Int> = [429, 502, 503, 504]
    private static func retryDelay(response: HTTPURLResponse?, attempt: Int) -> TimeInterval {
        if let raw = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), seconds > 0 {
            return min(seconds, 5.0)
        }
        return attempt == 0 ? 0.5 : 1.5
    }
    // Download tasks keep network response bodies off the heap until the size is checked.
    private func request(_ method: String, _ path: String, body: Data? = nil, bodyFile: URL? = nil, headers: [String: String] = [:], limit: Int = 8 * 1024 * 1024, retryable: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let attempts = retryable ? 3 : 1
        for attempt in 0..<attempts {
            var request = URLRequest(url: root.appendingPathComponent(path))
            request.httpMethod = method; request.httpBody = body
            if let bodyFile {
                guard let stream = InputStream(url: bodyFile) else { throw CocoaError(.fileReadUnknown) }
                request.httpBodyStream = stream
                request.setValue(String(try SyncFile.size(bodyFile)), forHTTPHeaderField: "Content-Length")
            }
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let delegate = BoundedResponse(limit: limit, bodyFile: bodyFile)
            let file: URL, response: URLResponse
            do {
                (file, response) = try await session.download(for: request, delegate: delegate)
            } catch let error as URLError where error.code == .cancelled && delegate.exceeded {
                throw SyncFailure("WebDAV 响应超过大小限制。")
            }
            defer { try? FileManager.default.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse else { throw SyncFailure("无效的 WebDAV 响应。") }
            if retryable && attempt + 1 < attempts && Self.retryableStatusCodes.contains(http.statusCode) {
                try await Task.sleep(for: .seconds(Self.retryDelay(response: http, attempt: attempt)))
                continue
            }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard !delegate.exceeded && size <= limit else { throw SyncFailure("WebDAV 响应超过大小限制。") }
            return (try Data(contentsOf: file), http)
        }
        throw SyncFailure("无效的 WebDAV 响应。")
    }
    private func check(_ response: HTTPURLResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 412 { throw SyncFailure("其他设备已更新云端，请重新同步。", definitePublishRejection: true) }
            if [401, 403].contains(response.statusCode) { throw SyncFailure("WebDAV 认证失败或无访问权限。", definitePublishRejection: true) }
            if [301, 302, 307, 308].contains(response.statusCode) { throw SyncFailure("WebDAV 地址发生重定向（HTTP \(response.statusCode)），请更新为最终目录地址。", definitePublishRejection: true) }
            let definite = [400, 404, 405, 409, 413, 415, 422].contains(response.statusCode)
            throw SyncFailure("WebDAV 返回 HTTP \(response.statusCode)。", definitePublishRejection: definite)
        }
    }
    public func testConnection() async throws {
        let (_, response) = try await request("PROPFIND", "", body: Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8), headers: ["Depth": "0", "Content-Type": "application/xml"], retryable: true)
        try check(response)
        guard response.statusCode == 207 else { throw SyncFailure("服务器未返回 WebDAV 目录响应。") }
    }
    private func checkLegacy() async throws {
        let (_, response) = try await request("GET", "inkstone-v1/manifest.json", retryable: true)
        guard response.statusCode == 404 else {
            try check(response)
            throw SyncFailure("检测到 inkstone-v1 旧目录。请按桌面端指引完成迁移后重试。")
        }
    }
    func prepare() async throws {
        try await testConnection()
        try await checkLegacy()
        for path in ["inkstone/", "inkstone/objects/"] {
            let (_, response) = try await request("MKCOL", path, retryable: true)
            if response.statusCode != 405 { try check(response) }
        }
    }
    func manifest() async throws -> (SyncManifest, String?) {
        let (data, response) = try await request("GET", "inkstone/manifest.json", retryable: true)
        if response.statusCode == 404 {
            try await checkLegacy()
            return (SyncManifest(), nil)
        }
        try check(response)
        guard let tag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespaces), Self.strongETag(tag) else {
            throw SyncFailure("服务器未提供有效强 ETag，无法安全同步。")
        }
        return (try SyncManifest.decode(data), tag)
    }
    static func strongETag(_ value: String) -> Bool {
        let bytes = Array(value.trimmingCharacters(in: .whitespaces).utf8)
        return bytes.count > 2 && bytes.first == 34 && bytes.last == 34 && bytes.dropFirst().dropLast().allSatisfy { $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80 }
    }
    func download(_ hash: String, to destination: URL) async throws {
        guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SyncFailure("无效的远端对象摘要。")
        }
        for attempt in 0..<3 {
            var request = URLRequest(url: root.appendingPathComponent("inkstone/objects/" + hash))
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let delegate = BoundedResponse(limit: SyncTransfer.fileLimit)
            let temporary: URL, response: URLResponse
            do {
                (temporary, response) = try await session.download(for: request, delegate: delegate)
            } catch let error as URLError where error.code == .cancelled && delegate.exceeded {
                throw SyncFailure("WebDAV 响应超过大小限制。")
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse else { throw SyncFailure("无效的 WebDAV 响应。") }
            if attempt + 1 < 3 && Self.retryableStatusCodes.contains(http.statusCode) {
                try await Task.sleep(for: .seconds(Self.retryDelay(response: http, attempt: attempt)))
                continue
            }
            guard !delegate.exceeded else { throw SyncFailure("WebDAV 响应超过大小限制。") }
            try check(http)
            try SyncFile.copy(temporary, to: destination, hash: hash, replaceCache: true)
            return
        }
    }
    func upload(_ hash: String, from file: URL) async throws {
        guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SyncFailure("无效的上传对象摘要。")
        }
        guard try SyncFile.hash(file) == hash else { throw SyncFailure("上传文件内容校验失败。") }
        // File-backed request streams keep the object off the heap; the response
        // still uses a bounded download task, including oversized error responses.
        let (_, response) = try await request("PUT", "inkstone/objects/" + hash, bodyFile: file,
            headers: ["If-None-Match": "*", "Content-Type": "application/octet-stream"], retryable: true)
        if response.statusCode == 412 {
            let verification = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: verification) }
            try await download(hash, to: verification)
        } else { try check(response) }
    }
    func publish(_ manifest: SyncManifest, revision: String?) async throws {
        try manifest.validate()
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= 8 * 1024 * 1024 else { throw SyncFailure("同步清单超过大小限制。") }
        let condition = revision.map { ["If-Match": $0] } ?? ["If-None-Match": "*"]
        let (_, response) = try await request("PUT", "inkstone/manifest.json", body: data, headers: condition.merging(["Content-Type": "application/json"]) { a, _ in a })
        try check(response)
        guard [200, 201, 204].contains(response.statusCode) else { throw SyncFailure("服务器未确认清单发布。") }
    }
}
