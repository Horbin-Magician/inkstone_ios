import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import InkstoneCore

@MainActor
final class LibraryStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var warnings: [String] = []
    @Published var error: String?
    @Published var vaultName = "我的墨砚"
    @Published var loading = false
    @Published var favorites: Set<String> = []
    @Published var selected: Note?
    @Published var records: [RecoveryRecord] = []
    @Published var external = false
    private(set) var vault: Vault?
    private var scopedURL: URL?
    private var root: URL?
    private var started = false
    private static var previewRoot: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--preview-vault"), args.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }
    private let defaults = previewRoot == nil ? UserDefaults.standard : UserDefaults(suiteName: "InkstoneMobilePreview")!
    private var favoriteKey: String { "favorites." + (external ? (root?.standardizedFileURL.resolvingSymlinksInPath().path ?? "external") : "local") }
    private var appSupport: URL { if let preview = Self.previewRoot { return preview.appendingPathComponent(".preview-state") }; return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InkstoneMobile") }
    private var localRoot: URL { if let preview = Self.previewRoot { return preview }; return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("墨砚笔记") }
    var tags: [String] { Set(notes.flatMap { $0.metadata.tags }).sorted() }

    func start() async {
        guard !started else { return }; started = true
        if let data = defaults.data(forKey: "vaultBookmark") {
            do {
                var stale = false
                #if os(iOS)
                let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                #else
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                #endif
                try await open(url, external: true)
                return
            } catch { self.error = "上次的笔记库暂不可用，已打开本地库。\n" + error.localizedDescription }
        }
        await openLocal()
    }
    func openLocal() async {
        do {
            try await open(localRoot, external: false)
            defaults.removeObject(forKey: "vaultBookmark")
            if !defaults.bool(forKey: "welcomeCreated") {
                if !notes.contains(where: { $0.path == "欢迎使用墨砚.md" }) {
                    _ = try await vault?.create(path: "欢迎使用墨砚.md", text: Self.welcome)
                    await refresh()
                }
                defaults.set(true, forKey: "welcomeCreated")
            }
        } catch { self.error = error.localizedDescription }
    }
    func open(_ url: URL, external: Bool) async throws {
        loading = true; defer { loading = false }
        let access = external && url.startAccessingSecurityScopedResource()
        do {
            let identity = external ? url.standardizedFileURL.resolvingSymlinksInPath().path : "local"
            let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let next = try Vault(root: url, recovery: appSupport.appendingPathComponent("Recovery/" + key), createIfNeeded: !external)
            let snapshot = try await next.scan()
            if external {
                #if os(iOS)
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                #else
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                #endif
                defaults.set(bookmark, forKey: "vaultBookmark")
            }
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = access ? url : nil
            root = url; vault = next; notes = snapshot.notes; warnings = snapshot.warnings
            vaultName = external ? url.lastPathComponent : "我的墨砚"
            self.external = external
            favorites = Set(defaults.stringArray(forKey: favoriteKey) ?? [])
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    func refresh() async {
        guard let vault, !loading else { return }
        loading = true; defer { loading = false }
        do { let result = try await vault.scan(); notes = result.notes; warnings = result.warnings }
        catch { self.error = error.localizedDescription }
    }
    func toggleFavorite(_ path: String) {
        if favorites.contains(path) { favorites.remove(path) } else { favorites.insert(path) }
        defaults.set(Array(favorites), forKey: favoriteKey)
    }
    func create(_ title: String, body: String? = nil) async {
        guard let vault else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { error = "请输入笔记名称。"; return }
        do {
            let path = title.lowercased().hasSuffix(".md") ? title : title + ".md"
            let note = try await vault.create(path: path, text: body ?? "# \((path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))\n\n")
            await refresh(); selected = note
        } catch { self.error = error.localizedDescription }
    }
    func dailyNote() async {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = formatter.string(from: Date())
        if let note = notes.first(where: { $0.path == "日记/\(day).md" }) { selected = note }
        else { await create("日记/\(day)", body: "# \(day)\n\n## 此刻的想法\n\n\n## 今天想做\n\n- [ ] \n\n#日记\n") }
    }
    func loadRecovery(path: String? = nil) async {
        do { records = try await vault?.records(path: path) ?? [] }
        catch { self.error = error.localizedDescription }
    }
    func restore(_ record: RecoveryRecord) async {
        do { _ = try await vault?.restoreCopy(record); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                var coordinatorError: NSError?
                var result: Result<String, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { file in
                    result = Result {
                        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 8 * 1024 * 1024 else { throw VaultError.tooLarge }
                        return try String(contentsOf: file, encoding: .utf8)
                    }
                }
                if let coordinatorError { throw coordinatorError }
                guard let result else { throw CocoaError(.fileReadUnknown) }
                let text = try result.get()
                _ = try await vault?.create(path: url.deletingPathExtension().lastPathComponent + ".md", text: text)
            } catch { self.error = error.localizedDescription }
        }
        await refresh()
    }
    static let welcome = """
    # 留一方天地，安放想法

    欢迎使用 **墨砚**。这里的每一篇笔记，都是属于你的 Markdown 文件。

    ## 从一笔开始

    - 轻点右上角，写下新的想法
    - 在「源码」中编辑，在「阅读」中专注
    - 用 #标签 整理，用 [[欢迎使用墨砚|双向链接]] 连接思考

    ## 与桌面相伴

    在设置中打开「文件」里的笔记文件夹，或导入桌面端的 Markdown 文件。文件夹提供商决定文件何时在设备之间同步。

    > 想法不必完整，先把它写下来。

    #开始 #墨砚
    """
}

struct MarkdownFile: FileDocument {
    static let contentType = UTType(filenameExtension: "md") ?? .plainText
    static var readableContentTypes: [UTType] { [contentType, .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
