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
                HStack(spacing: 14) {
                    Image(systemName: "circle.lefthalf.filled").font(.largeTitle).foregroundStyle(InkTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("墨砚").font(.title2.weight(.semibold))
                        Text("一方天地，随身携带").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
            }
            Section {
                LabeledContent("当前笔记库", value: store.vaultName)
                LabeledContent("存储方式", value: store.external ? "文件提供商" : "此设备")
                Button { folderPicker = true } label: { Label("打开笔记文件夹", systemImage: "folder") }.disabled(store.loading)
                Button { importPicker = true } label: { Label("导入 Markdown", systemImage: "square.and.arrow.down") }.disabled(store.loading)
                if store.external { Button("返回本地笔记库") { Task { await store.openLocal() } }.disabled(store.loading) }
            } header: { Text("笔记库") } footer: {
                Text("通过「文件」选择桌面端使用的 Markdown 文件夹。iCloud Drive 等提供商负责设备间传输；下拉刷新可重新读取文件。")
            }
            Section {
                Button { recovery = true } label: { Label("历史、草稿与已删除笔记", systemImage: "clock.arrow.circlepath") }
            } header: { Text("恢复") } footer: {
                Text("编辑时保存独立草稿，点击勾号才写入原文。恢复始终创建副本。本机恢复记录不会同步，卸载应用会丢失，请另做备份。")
            }
            if !store.warnings.isEmpty {
                Section("读取问题") { ForEach(store.warnings, id: \.self) { Text($0).font(.footnote) } }
            }
            Section("移动端支持") {
                Label("Markdown 文件、标签与 Wiki 双链", systemImage: "checkmark.circle")
                Label("源码编辑、基础阅读与任务勾选", systemImage: "checkmark.circle")
                Text("桌面 WebDAV 协议尚未接入；公式、表格、图片及嵌入内容请使用源码查看。移动端恢复记录与桌面历史相互独立。")
                    .font(.footnote).foregroundStyle(.secondary)
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
                Section { Text("恢复为一篇新笔记，保留当前文件。记录仅保存在此设备。").font(.subheadline).foregroundStyle(.secondary) }
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
