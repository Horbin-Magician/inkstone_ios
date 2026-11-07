import SwiftUI
import InkstoneCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var recovery: Bool
    @State private var folderPicker = false
    @State private var importPicker = false
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
                TextField("WebDAV 目录地址（与 PC 端相同）", text: $store.webDAV.url)
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
                Toggle("自动同步", isOn: Binding(
                    get: { store.automaticSync },
                    set: { store.setAutomaticSync($0) }
                ))
                Button("保存配置") {
                    do { try store.saveSyncSettings(); store.syncStatus = "配置已保存" }
                    catch { store.error = error.localizedDescription }
                }
                Button("测试连接") { Task { await store.sync(testOnly: true) } }
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
                    Text("两端使用同一个已存在的 WebDAV 目录，建议使用 HTTPS。自动或手动同步笔记与附件；空文件夹、书签及恢复记录不上传。双端修改会保留冲突副本。密码保存在此设备钥匙串中。服务器须支持强 ETag 和条件写入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("WebDAV 云同步") } footer: {
                Text("开启后，回到前台和本地修改后自动同步，空闲时每 2 分钟检查一次。打开笔记或设置期间暂缓，关闭后补同步；退到后台不再发起同步。失败会延迟重试，冲突保留副本。")
            }.disabled(store.syncing || store.loading)
            Section {
                Button { recovery = true } label: { Label("历史、草稿与已删除笔记", systemImage: "clock.arrow.circlepath") }
            } header: { Text("恢复") } footer: {
                Text("恢复会创建副本。记录仅存于此设备，卸载会丢失。")
            }
            if !store.warnings.isEmpty {
                Section("读取问题") { ForEach(store.warnings, id: \.self) { Text($0).font(.footnote) } }
            }
            Section { Text("Inkstone Mobile  ·  0.1.0").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("设置")
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
    @State private var working = false
    var body: some View {
        NavigationStack {
            List {
                if store.records.isEmpty { ContentUnavailableView("暂无恢复记录", systemImage: "clock.arrow.circlepath", description: Text("编辑草稿、保存前的版本和已删除笔记会显示在这里。")) }
                ForEach(store.records) { record in
                    Button { preview = record } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.path).font(.headline).foregroundStyle(.primary)
                            HStack { Text(record.kind); Text(record.date, style: .date); Text(record.date, style: .time) }.font(.caption).foregroundStyle(.secondary)
                            Text(record.text.prefix(100)).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
            }.navigationTitle("文件恢复")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await store.loadRecovery(path: path) }
                .sheet(item: $preview) { record in
                    NavigationStack {
                        ScrollView { Text(record.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) }
                            .navigationTitle(record.kind)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("返回") { preview = nil }.disabled(working) }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("恢复为副本") { Task {
                                        working = true
                                        await store.restore(record)
                                        working = false
                                        if store.error == nil { preview = nil; restored = true }
                                    } }.disabled(working)
                                }
                            }
                            .alert("恢复失败", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
                    }.interactiveDismissDisabled(working)
                }
                .alert("已恢复为副本", isPresented: $restored) { Button("好") {} } message: { Text("可返回笔记列表查看，原文件未更改。") }
        }
    }
}
