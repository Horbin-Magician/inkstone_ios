import SwiftUI
import InkstoneCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var recovery: Bool
    @State private var folderPicker = false
    @State private var backup: ArchiveFile?
    @State private var exporting = false
    @State private var preparing = false
    @State private var prune = false
    @AppStorage("recoveryDays") private var recoveryDays = 90
    @State private var importPicker = false
    @AppStorage("readingSize") private var readingSize = 17.0
    @AppStorage("readingSpacing") private var readingSpacing = 5.0
    var body: some View {
        Form {
            Section {
                LabeledContent("当前笔记库", value: store.vaultName)
                LabeledContent("存储方式", value: store.external ? "文件提供商" : "此设备")
                Button { folderPicker = true } label: { Label("打开笔记文件夹", systemImage: "folder") }.disabled(store.loading || store.syncing)
                Button { importPicker = true } label: { Label("导入 Markdown", systemImage: "square.and.arrow.down") }.disabled(store.loading || store.syncing)
                if store.external { Button("返回本地笔记库") { Task { await store.openLocal() } }.disabled(store.loading || store.syncing) }
            } header: { Text("笔记库") } footer: {
                Text("iCloud 等文件提供商负责传输，下拉笔记列表可刷新。")
            }
            Section {
                TextField("WebDAV 目录地址（默认 HTTPS）", text: $store.webDAV.url)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("用户名", text: $store.webDAV.username).autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("密码或应用专用密码", text: $store.webDAVPassword)
                Toggle("允许未加密 HTTP（兼容旧服务器）", isOn: $store.webDAV.allowInsecureHTTP)
                if store.webDAV.allowInsecureHTTP {
                    Text("HTTP 会以未加密方式传输账号凭据、笔记和附件。仅在确认需要兼容时开启，并使用明确的 http:// 地址。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("自动同步", isOn: Binding(
                    get: { store.automaticSync },
                    set: { store.setAutomaticSync($0) }
                ))
                Button("测试连接") { Task { await store.sync(testOnly: true) } }
            } header: { Text("WebDAV 连接配置") } footer: {
                if let error = store.syncSettingsSaveError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("配置更改后自动保存，密码保存在此设备钥匙串中。")
                }
            }
            .disabled(store.syncing || store.loading)
            Section {
                Text(store.syncSummary)
                if let date = store.lastSync { LabeledContent("上次成功", value: date.formatted(date: .abbreviated, time: .shortened)) }
                Button("立即同步") { Task { await store.sync() } }
                HStack(spacing: 6) {
                    if store.syncing { ProgressView().controlSize(.small).tint(.secondary) }
                    Text(store.syncStatus).font(.footnote).foregroundStyle(.secondary)
                }
                if let issue = store.syncIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                DisclosureGroup("同步说明") {
                    Text("两端使用同一个已存在的 WebDAV 目录，默认使用 HTTPS；HTTP 需明确开启兼容选项。自动或手动同步笔记与附件；空文件夹、书签及恢复记录不上传。双端修改会保留冲突副本。密码保存在此设备钥匙串中。服务器须支持强 ETag 和条件写入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("同步状态") } footer: {
                Text("开启后，回到前台和本地修改后自动同步，空闲时每 2 分钟检查一次。打开笔记或设置期间暂缓，关闭后补同步；退到后台不再发起同步。失败会延迟重试，冲突保留副本。")
            }.disabled(store.syncing || store.loading)
            Section("编辑") {
                Text("新笔记和已有笔记均在停止输入后自动保存到 Markdown 文件，返回或切换笔记时立即保存。输入法组词期间暂缓保存；外部文件冲突时请核对或另存副本。").font(.caption)
            }
            Section("阅读") {
                Slider(value: $readingSize, in: 14...28, step: 1) { Text("字体大小") }
                LabeledContent("字体大小", value: "\(Int(readingSize)) pt")
                Slider(value: $readingSpacing, in: 0...16, step: 1) { Text("行距") }
                LabeledContent("附加行距", value: "\(Int(readingSpacing)) pt")
            }
            Section("备份与保留") {
                NavigationLink("本机恢复空间（历史、附件与文件夹）") { RecoveryStorageView().environmentObject(store) }
                LabeledContent("笔记数量", value: "\(store.notes.count)")
                LabeledContent("正文占用", value: ByteCountFormatter.string(fromByteCount: Int64(store.notes.reduce(0) { $0 + $1.text.utf8.count }), countStyle: .file))
                Button(preparing ? "正在准备备份…" : "导出整库 ZIP（含附件）") { Task {
                    preparing = true; defer { preparing = false }
                    do { if let data = try await store.vault?.exportArchive() { backup = ArchiveFile(data: data); exporting = true } }
                    catch { store.error = error.localizedDescription }
                } }.disabled(preparing || store.syncing)
                Picker("恢复记录保留时间", selection: $recoveryDays) {
                    Text("30 天").tag(30); Text("90 天").tag(90); Text("365 天").tag(365)
                }
                Button("清理过期历史与已删除记录", role: .destructive) { prune = true }
                Text("清理仅在确认后执行。整库导出包含 Markdown 和附件，不含历史和密码；当前支持总计 128 MB 以内的文件。").font(.caption)
            }
            Section {
                Button { recovery = true } label: { Label("历史与已删除笔记", systemImage: "clock.arrow.circlepath") }
            } header: { Text("恢复") } footer: {
                Text("恢复会创建副本。记录仅存于此设备，卸载会丢失。")
            }
            if !store.warnings.isEmpty {
                Section("读取问题") { ForEach(store.warnings, id: \.self) { Text($0).font(.footnote) } }
            }
            Section { Text("Inkstone Mobile  ·  0.1.0").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("设置")
        .fileExporter(isPresented: $exporting, document: backup, contentType: .zip, defaultFilename: "墨砚备份.zip") { result in
            backup = nil
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
        .confirmationDialog("清理 \(recoveryDays) 天前的历史和已删除记录？", isPresented: $prune, titleVisibility: .visible) {
            Button("永久清理", role: .destructive) { Task {
                do { _ = try await store.vault?.pruneRecovery(before: Date().addingTimeInterval(-Double(recoveryDays) * 86400)) }
                catch { store.error = error.localizedDescription }
            } }
        } message: { Text("此操作不可撤销；笔记文件不受影响。") }
        .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
            Task {
                do { try await store.open(result.get(), external: true) }
                catch { store.error = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $importPicker, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await store.importFiles(urls) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
    }
}

struct RecoveryView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    let path: String?
    @State private var preview: RecoveryRecord?
    @State private var restored = false
    @State private var restoredNote: Note?
    @State private var openRestored = false
    @State private var working = false
    @State private var kind = RecoveryKind.history
    var body: some View {
        NavigationStack {
            List {
                Picker("记录类型", selection: $kind) {
                    Text("历史版本").tag(RecoveryKind.history)
                    Text("已删除").tag(RecoveryKind.deleted)
                    Text("草稿").tag(RecoveryKind.draft)
                }.pickerStyle(.segmented)
                if store.records.filter({ kind == .history ? $0.kind.isHistory : $0.kind == kind }).isEmpty { ContentUnavailableView("暂无恢复记录", systemImage: "clock.arrow.circlepath", description: Text("保存前的版本和已删除笔记会显示在这里。")) }
                ForEach(store.records.filter { kind == .history ? $0.kind.isHistory : $0.kind == kind }) { record in
                    Button { Task {
                        do { preview = try await store.vault?.recoveryRecord(record) }
                        catch { store.error = error.localizedDescription }
                    } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.path).font(.headline).foregroundStyle(.primary)
                            HStack { Text(record.kind.rawValue); Text(record.date, style: .date); Text(record.date, style: .time) }.font(.caption).foregroundStyle(.secondary)
                            Text(record.excerpt).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
            }.navigationTitle("文件恢复")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await store.loadRecovery(path: path) }
                .sheet(item: $preview) { record in
                    NavigationStack {
                        ScrollView { Text(record.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) }
                            .navigationTitle(record.kind.rawValue)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("返回") { preview = nil }.disabled(working) }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("恢复为副本") { Task {
                                        working = true
                                        restoredNote = await store.restore(record)
                                        working = false
                                        if restoredNote != nil { preview = nil; restored = true }
                                    } }.disabled(working)
                                }
                            }
                            .alert("恢复失败", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
                    }.interactiveDismissDisabled(working)
                }
                .alert("已恢复为副本", isPresented: $restored) {
                    Button("打开恢复结果") { openRestored = true }
                    Button("完成", role: .cancel) {}
                } message: { Text("原文件未更改。") }
                .sheet(isPresented: $openRestored) {
                    if let note = restoredNote { EditorView(note: note).environmentObject(store) }
                }
        }
    }
}

struct SyncStatusView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var conflictNote: Note?
    var body: some View {
        NavigationStack {
            Form {
                Section("当前状态") {
                    Text(store.syncSummary)
                    Text(store.syncStatus).font(.footnote).foregroundStyle(.secondary)
                    if let date = store.lastSync { LabeledContent("上次成功", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Text("修改会自动保存到文件，关闭笔记后可进行同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if store.selected != nil { Text("正在查看或编辑笔记，为保护文件一致性，已暂停同步。") }
                    if let issue = store.syncIssue {
                        Text(issue).foregroundStyle(.red)
                        Text("请检查网络、WebDAV 目录地址和账号权限，再重试；认证失败时请在设置中更新密码。")
                    }
                    Button(store.syncIssue == nil ? "立即同步" : "重试同步") { Task { await store.sync() } }
                        .disabled(store.syncing || store.loading || store.selected != nil || store.webDAV.url.isEmpty)
                }
                if !store.syncConflicts.isEmpty {
                    Section("冲突副本 · 请核对") {
                        ForEach(store.syncConflicts, id: \.self) { path in
                            VStack(alignment: .leading) {
                                Text(path).font(.headline)
                                ForEach(store.notes.filter { $0.path == path || $0.path.hasPrefix((path as NSString).deletingPathExtension + " (云端冲突 ") }) { note in
                                    Button(note.path == path ? "核对本机版本" : "核对云端冲突副本") { conflictNote = note }
                                }
                            }
                        }
                        Text("分别核对版本，保存需要的内容。附件冲突可在文件提供商或桌面端检查。")
                    }
                }
            }.sheet(item: $conflictNote) { note in EditorView(note: note).environmentObject(store) }
            .navigationTitle("保存与同步")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ArchiveFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
