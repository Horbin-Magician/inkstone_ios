import SwiftUI
import InkstoneCore

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.scenePhase) var scenePhase
    private enum Scope: String, CaseIterable { case folders = "文件夹", favorites = "书签" }
    @State private var scope: Scope = .folders
    @State private var settings = false
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var newNote = false
    @State private var title = ""
    @State private var recovery = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var moving: String?
    @State private var destination = ""
    @State private var deleting: Note?
    @State private var deleteInProgress = false
    private struct SearchRequest: Equatable {
        let query: String
        let revision: Int
    }
    @State private var completedSearch: SearchRequest?
    @State private var searchResults: [Note] = []
    private var searchRequest: SearchRequest { SearchRequest(query: query, revision: store.notesRevision) }
    private var searching: Bool { !query.isEmpty && completedSearch != searchRequest }
    private var libraryInteractionActive: Bool {
        settings || recovery || newNote || newFolder || moving != nil || deleting != nil || deleteInProgress
    }
    var body: some View {
        NavigationStack { library }.disabled(deleteInProgress)
        #if os(iOS)
        .fullScreenCover(item: $store.selected, onDismiss: { Task { await store.refresh() } }) { note in
            EditorView(note: note).environmentObject(store)
        }
        #else
        .sheet(item: $store.selected, onDismiss: { Task { await store.refresh() } }) { note in
            EditorView(note: note).environmentObject(store)
        }
        #endif
        .sheet(isPresented: $settings) {
            NavigationStack {
                SettingsView(recovery: $recovery)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
            }
            .sheet(isPresented: $recovery) { RecoveryView(path: nil).environmentObject(store) }
            .alert("提示", isPresented: Binding(get: { settings && store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("好") { store.error = nil }
            } message: { Text(store.error ?? "") }
        }
        .alert("新建笔记", isPresented: $newNote) {
            TextField("笔记名称", text: $title)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await store.create(scope != .folders || store.currentFolder.isEmpty ? title : store.currentFolder + "/" + title) } }
        } message: { Text("使用 / 创建子文件夹，例如：读书/随想") }
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await store.createFolder(folderName) } }
        }
        .alert("移动或重命名", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            TextField("相对于笔记库的完整路径", text: $destination)
            Button("取消", role: .cancel) { moving = nil }
            Button("移动") { if let path = moving { Task { await store.move(path, to: destination) } }; moving = nil }
        } message: { Text("填写完整目标路径，例如：读书/文学/随想.md。文件夹会连同内容一起移动；已有 Wiki 链接不会自动改写。") }
        .confirmationDialog("删除笔记？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { note in
            Button("删除笔记", role: .destructive) {
                deleteInProgress = true
                Task {
                    defer { deleteInProgress = false }
                    do { try await store.deleteNote(note) }
                    catch { store.error = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { note in
            Text("将删除「\(note.title)」。删除前会保留本机恢复记录；共享文件夹中的删除可能同步到其他设备。")
        }
        .alert("提示", isPresented: Binding(get: { !settings && store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refresh() } } }
        .onChange(of: libraryInteractionActive) { _, active in store.autoSyncPaused = active }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            store.requestForegroundSync()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await store.autoSyncIfNeeded()
            }
        }
        .task(id: searchRequest) {
            let request = searchRequest
            guard !request.query.isEmpty else { searchResults = []; completedSearch = nil; return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let notes = store.notes
            let worker = Task.detached(priority: .userInitiated) {
                NoteIndex.search(notes, query: request.query)
            }
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            searchResults = results; completedSearch = request
        }
    }
    private var visibleNotes: [Note] {
        if !query.isEmpty { return searchResults }
        switch scope {
        case .favorites: return store.notes.filter { store.favorites.contains($0.path) }
        case .folders: return store.notes.filter { $0.folder == store.currentFolder }
        }
    }
    private var childFolders: [String] {
        store.folders.filter { ($0 as NSString).deletingLastPathComponent == store.currentFolder }
    }
    private var library: some View {
        List {
            if scope == .folders && query.isEmpty {
                if !store.currentFolder.isEmpty {
                    Button { store.currentFolder = (store.currentFolder as NSString).deletingLastPathComponent } label: {
                        Label("上一级 · " + store.currentFolder, systemImage: "arrow.turn.up.left")
                            .font(.subheadline).lineLimit(1)
                    }.frame(minHeight: 36)
                }
                ForEach(childFolders, id: \.self) { folder in
                    Button { store.currentFolder = folder } label: {
                        HStack {
                            Image(systemName: "folder").foregroundStyle(InkTheme.accent)
                            Text((folder as NSString).lastPathComponent).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.frame(minHeight: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu { Button("移动或重命名") { moving = folder; destination = folder } }
                }
            }
            if !searching {
                ForEach(visibleNotes) { note in
                    noteButton(note)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Trailing actions are laid out from the outer edge inward.
                            deleteButton(note).tint(.red)
                            Button { store.toggleFavorite(note.path) } label: {
                                Label(store.favorites.contains(note.path) ? "移除书签" : "书签", systemImage: "bookmark")
                            }.tint(InkTheme.accent)
                            Button { moving = note.path; destination = note.path } label: {
                                Label("移动", systemImage: "folder")
                            }
                        }
                }
            }
            if !store.warnings.isEmpty {
                Button { settings = true } label: {
                    Label("\(store.warnings.count) 个文件未能读取", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if visibleNotes.isEmpty && !store.loading && !store.syncing && !searching && (scope != .folders || !query.isEmpty || childFolders.isEmpty) {
                ContentUnavailableView(query.isEmpty ? (scope == .favorites ? "暂无书签" : "开始一篇笔记") : "没有找到笔记",
                    systemImage: query.isEmpty ? "doc.text" : "doc.text.magnifyingglass",
                    description: Text(query.isEmpty ? (scope == .favorites ? "在笔记菜单中添加书签，即可在这里快速找到。" : "右上角新建，随时记下想法。") : "搜索范围为整个笔记库，试试其他关键词。"))
                    .allowsHitTesting(false)
            }
        }
        .disabled(store.syncing)
        .navigationTitle(query.isEmpty ? scope.rawValue : "搜索笔记")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            if showSearch {
                HStack(spacing: 10) {
                    ZStack {
                        Image(systemName: "magnifyingglass").opacity(searching ? 0 : 1)
                        if searching {
                            ProgressView().controlSize(.small).scaleEffect(0.75)
                                .accessibilityLabel("正在搜索")
                        }
                    }.frame(width: 20, height: 20).foregroundStyle(.secondary)
                    TextField("搜索整个笔记库", text: $query)
                        .focused($searchFocused).submitLabel(.search)
                        .autocorrectionDisabled()
                    Button {
                        query = ""; searchFocused = false; showSearch = false
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭搜索")
                }.padding(.leading, 16).padding(.trailing, 4).background(.bar)
            }
        }
        .onChange(of: showSearch) { _, shown in searchFocused = shown }
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    Section(store.vaultName) {
                        Picker("浏览范围", selection: $scope) {
                            ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Button { scope = .folders; folderName = ""; newFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    Divider()
                    Button { settings = true } label: { Label("设置与同步", systemImage: "gearshape") }
                } label: {
                    ZStack {
                        Image(systemName: "sidebar.left")
                            .opacity(store.loading || store.syncing ? 0 : 1)
                        if store.loading || store.syncing {
                            ProgressView().controlSize(.small).scaleEffect(0.75)
                                .tint(.secondary).accessibilityHidden(true)
                        }
                    }.frame(width: 24, height: 24)
                }
                .accessibilityLabel("笔记库、文件夹与设置")
                .accessibilityValue(store.syncing ? "正在同步" : (store.loading ? "正在刷新" : ""))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索笔记")
                Menu {
                    Button { title = ""; newNote = true } label: { Label("新建笔记", systemImage: "square.and.pencil") }
                    Button { Task { await store.dailyNote() } } label: { Label("今日笔记", systemImage: "calendar") }
                } label: { Image(systemName: "square.and.pencil") } primaryAction: {
                    title = ""; newNote = true
                }
                .accessibilityLabel("新建笔记，长按打开更多操作").disabled(store.loading || store.syncing)
            }
        }
    }
    private func noteButton(_ note: Note) -> some View {
        Button { if !store.syncing { store.selected = note } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(note.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if store.favorites.contains(note.path) { Image(systemName: "bookmark.fill").foregroundStyle(InkTheme.accent).font(.caption2) }
                    Spacer(minLength: 0)
                    Text(note.modified, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.tertiary)
                }
                if !note.excerpt.isEmpty {
                    Text(note.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if !note.folder.isEmpty && (scope != .folders || !query.isEmpty) {
                    Text(note.folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 3).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu {
            Button { moving = note.path; destination = note.path } label: {
                Label("移动或重命名", systemImage: "folder")
            }
            Button { store.toggleFavorite(note.path) } label: { Label(store.favorites.contains(note.path) ? "移除书签" : "书签", systemImage: "bookmark") }
            deleteButton(note)
        }
    }
    private func deleteButton(_ note: Note) -> some View {
        Button(role: .destructive) { deleting = note } label: {
            Label("删除", systemImage: "trash")
        }
    }

}
