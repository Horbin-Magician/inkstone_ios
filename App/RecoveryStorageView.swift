import SwiftUI
import InkstoneCore

struct RecoveryStorageView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var items: [RecoveryStorageItem] = []
    @State private var removing: RecoveryStorageItem?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                LabeledContent("恢复文件总大小", value: size(items.reduce(0) { $0 + $1.bytes }))
                Text("这些文件仅在本机保存。恢复会创建新文件夹或副本；清理不会删除当前笔记。同步事务正在使用的备份和暂存文件受保护。").font(.caption)
            }
            ForEach(RecoveryStorageCategory.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    let entries = items.filter { $0.category == category }
                    LabeledContent("\(entries.count) 项", value: size(entries.reduce(0) { $0 + $1.bytes }))
                    if category == .history {
                        NavigationLink("查看并恢复正文版本") { RecoveryView(path: nil).environmentObject(store) }
                    }
                    ForEach(entries) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.path).lineLimit(2)
                            Text(size(item.bytes) + " · " + item.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            if item.protected { Label("恢复流程使用中，禁止清理", systemImage: "lock").font(.caption) }
                            HStack {
                                if item.canRestore {
                                    Button("恢复为新文件夹") { Task { await restore(item) } }.buttonStyle(.borderless)
                                }
                                Spacer()
                                Button("清理", role: .destructive) { removing = item }
                                    .buttonStyle(.borderless).disabled(item.protected)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("本机恢复空间")
        .disabled(working || store.syncing)
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog("永久清理这份恢复文件？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("永久清理", role: .destructive) {
                guard let item = removing else { return }
                removing = nil
                Task {
                    working = true; defer { working = false }
                    do { try await store.vault?.removeRecoveryStorage(item.id); await refresh() }
                    catch { message = error.localizedDescription }
                }
            }
        } message: { Text((removing?.path ?? "") + "\n仅删除这一项本机恢复文件，无法撤销。") }
        .alert("恢复空间", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func refresh() async {
        do { items = try await store.vault?.recoveryStorage() ?? [] }
        catch { message = error.localizedDescription }
    }
    private func restore(_ item: RecoveryStorageItem) async {
        working = true; defer { working = false }
        do {
            if let path = try await store.vault?.restoreRecoveryStorage(item.id) {
                await store.refresh(); message = "已恢复到：" + path
            }
        } catch { message = error.localizedDescription }
    }
}
