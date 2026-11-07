import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import InkstoneCore

@MainActor
final class LibraryStore: ObservableObject {
    @Published var folders: [String] = []
    @Published var currentFolder = ""
    @Published var webDAV = WebDAVSettings()
    @Published var webDAVPassword = ""
    @Published var syncStatus = "尚未同步"
    @Published var syncing = false
    @Published var automaticSync = true
    @Published var syncIssue: String?
    var autoSyncPaused = false
    private var autoSyncSchedule = AutoSyncSchedule()
    private var savedSyncSettings: WebDAVSettings?
    private var savedSyncPassword = ""
    private var mutationsInProgress = 0
    @Published var notes: [Note] = []
    private(set) var noteIndex = NoteIndex(notes: [])
    private(set) var notesRevision = 0
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
        guard !syncing else { return }
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
        guard !syncing else { throw VaultError.busy }
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
            root = url; vault = next; apply(snapshot); currentFolder = ""
            vaultName = external ? url.lastPathComponent : "我的墨砚"
            self.external = external
            favorites = Set(defaults.stringArray(forKey: favoriteKey) ?? [])
            webDAV = defaults.data(forKey: syncKey).flatMap { try? JSONDecoder().decode(WebDAVSettings.self, from: $0) } ?? WebDAVSettings()
            automaticSync = defaults.object(forKey: syncKey + ".automatic") as? Bool ?? true
            savedSyncSettings = nil; savedSyncPassword = ""; syncIssue = nil
            autoSyncSchedule = AutoSyncSchedule()
            webDAVPassword = ""; syncStatus = defaults.string(forKey: syncKey + ".status") ?? "尚未同步"
            if !webDAV.url.isEmpty {
                do {
                    webDAVPassword = try WebDAVCredentials.read(credentialKey())
                    savedSyncSettings = webDAV; savedSyncPassword = webDAVPassword
                }
                catch { self.error = "无法读取钥匙串中的 WebDAV 密码：" + error.localizedDescription }
            }
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    func refresh(reportErrors: Bool = true) async {
        guard let vault, !loading else { return }
        loading = true; defer { loading = false }
        do { let result = try await vault.scan(); apply(result)
            if !currentFolder.isEmpty && !folders.contains(currentFolder) { currentFolder = "" } }
        catch {
            if reportErrors { self.error = error.localizedDescription }
            else { syncIssue = error.localizedDescription }
        }
    }
    private func apply(_ snapshot: VaultSnapshot) {
        noteIndex = snapshot.index
        if notes != snapshot.notes {
            notesRevision &+= 1
            notes = snapshot.notes
            if !syncing { autoSyncSchedule.requestChange() }
        }
        if warnings != snapshot.warnings { warnings = snapshot.warnings }
        if folders != snapshot.folders { folders = snapshot.folders }
    }
    private var syncKey: String { "webdav." + favoriteKey }
    private func credentialKey() throws -> String {
        let identity = syncKey + "\n" + (try webDAV.endpoint().absoluteString) + "\n" + webDAV.username
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func saveSyncSettings() throws {
        _ = try webDAV.endpoint()
        try WebDAVCredentials.save(webDAVPassword, account: credentialKey())
        defaults.set(try JSONEncoder().encode(webDAV), forKey: syncKey)
        savedSyncSettings = webDAV; savedSyncPassword = webDAVPassword
        syncIssue = nil
        autoSyncSchedule = AutoSyncSchedule()
    }
    func setAutomaticSync(_ enabled: Bool) {
        automaticSync = enabled
        defaults.set(enabled, forKey: syncKey + ".automatic")
        if enabled { autoSyncSchedule.requestForeground() }
    }
    func requestForegroundSync() { autoSyncSchedule.requestForeground() }

    func autoSyncIfNeeded() async {
        guard !Task.isCancelled, automaticSync, !autoSyncPaused,
              !loading, !syncing, mutationsInProgress == 0, selected == nil,
              let savedSyncSettings, savedSyncSettings == webDAV,
              savedSyncPassword == webDAVPassword,
              autoSyncSchedule.isDue() else { return }
        await sync(automatically: true)
    }

    func sync(testOnly: Bool = false, automatically: Bool = false) async {
        guard let vault, !loading, !syncing, mutationsInProgress == 0, selected == nil else { return }
        syncing = true; syncIssue = nil; syncStatus = testOnly ? "正在测试连接…" : "正在同步笔记与附件…"
        defer { syncing = false }
        do {
            if !automatically { try saveSyncSettings() }
            if !testOnly { autoSyncSchedule.started() }
            if testOnly {
                try await WebDAV(settings: webDAV, password: webDAVPassword).testConnection()
                syncStatus = "连接成功"
            } else {
                let report = try await vault.synchronize(settings: webDAV, password: webDAVPassword)
                syncStatus = "同步完成：上传 \(report.uploaded)，下载 \(report.downloaded)，删除 \(report.deleted)"
                if !report.conflicts.isEmpty { syncStatus += "；保留 \(report.conflicts.count) 处冲突，请核对笔记" }
                syncStatus += " · " + Date().formatted(date: .abbreviated, time: .shortened)
                defaults.set(syncStatus, forKey: syncKey + ".status")
                autoSyncSchedule.completed(success: true)
            }
        } catch {
            if !testOnly { autoSyncSchedule.completed(success: false) }
            syncStatus = automatically ? "自动同步未完成，稍后重试" : "同步未完成"
            syncIssue = error.localizedDescription
            if !automatically { self.error = error.localizedDescription }
        }
        if !testOnly { await refresh(reportErrors: !automatically) }
    }
    func createFolder(_ name: String) async {
        guard !syncing else { error = VaultError.busy.localizedDescription; return }
        mutationsInProgress += 1; defer { mutationsInProgress -= 1 }
        do {
            try await vault?.createFolder(path: currentFolder.isEmpty ? name : currentFolder + "/" + name)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func move(_ path: String, to destination: String) async {
        guard !syncing else { error = VaultError.busy.localizedDescription; return }
        mutationsInProgress += 1; defer { mutationsInProgress -= 1 }
        do {
            try await vault?.move(path: path, to: destination)
            favorites = Set(favorites.map { value in
                value == path ? destination : (value.hasPrefix(path + "/") ? destination + value.dropFirst(path.count) : value)
            })
            defaults.set(Array(favorites), forKey: favoriteKey)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func deleteNote(_ note: Note) async throws {
        guard !syncing, let vault else { throw VaultError.busy }
        mutationsInProgress += 1; defer { mutationsInProgress -= 1 }
        try await vault.trash(path: note.path, expected: note.text)
        favorites.remove(note.path)
        defaults.set(Array(favorites), forKey: favoriteKey)
        await refresh()
    }
    func toggleFavorite(_ path: String) {
        if favorites.contains(path) { favorites.remove(path) } else { favorites.insert(path) }
        defaults.set(Array(favorites), forKey: favoriteKey)
    }
    func create(_ title: String, body: String? = nil) async {
        guard !syncing else { error = VaultError.busy.localizedDescription; return }
        mutationsInProgress += 1; defer { mutationsInProgress -= 1 }
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
        guard !syncing else { error = VaultError.busy.localizedDescription; return }
        mutationsInProgress += 1; defer { mutationsInProgress -= 1 }
        do { _ = try await vault?.restoreCopy(record); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) async {
        guard let vault, !loading, !syncing else { return }
        loading = true
        for url in urls {
            do {
                _ = try await vault.importFile(url)
            } catch { self.error = error.localizedDescription }
        }
        loading = false
        await refresh()
    }
    static let welcome = """
    # 留一方天地，安放想法

    欢迎使用 **墨砚**。这里的每一篇笔记，都是属于你的 Markdown 文件。

    ## 从一笔开始

    - 轻点右上角，写下新的想法
    - 在「源码」中编辑，在「阅读」中专注
    - 用文件夹整理，用 [[欢迎使用墨砚|双向链接]] 连接思考

    ## 与桌面相伴

    在设置的「WebDAV 云同步」中填写与 PC 端相同的目录和账号，点击「立即同步」。笔记、附件与文件夹路径会在两端同步。

    > 想法不必完整，先把它写下来。

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
