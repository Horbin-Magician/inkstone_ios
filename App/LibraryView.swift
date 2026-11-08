import SwiftUI
import InkstoneCore
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.scenePhase) var scenePhase
    private enum Scope: String, CaseIterable { case recent = "最近", folders = "文件夹", favorites = "书签" }
    @AppStorage("libraryScope") private var scope: Scope = .recent
    @State private var importing = false
    @State private var syncDetails = false
    @State private var snapshotNote: Note?
    @State private var renaming = false
    @State private var settings = false
    @State private var wideLayout = false
    @State private var availableWidth: CGFloat = 0
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var recovery = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var moving: String?
    @State private var deleting: Note?
    @State private var selecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var batchDelete = false
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
        selecting || settings || recovery || importing || syncDetails || newFolder || moving != nil || deleting != nil || deleteInProgress
    }
    var body: some View {
        GeometryReader { proxy in
            Group {
                if wideLayout {
                    NavigationSplitView {
                        List {
                            Button("最近") { scope = .recent }
                            Button("书签") { scope = .favorites }
                            Button("根目录") { scope = .folders; store.currentFolder = "" }
                            ForEach(store.folders, id: \.self) { folder in
                                Button { scope = .folders; store.currentFolder = folder } label: { Label(folder, systemImage: "folder") }
                            }
                        }.navigationTitle("笔记库")
                    } content: { library } detail: {
                        if let note = store.selected {
                            EditorView(note: note, onClose: { store.selected = nil; Task { await store.refresh() } })
                        } else { ContentUnavailableView("选择一篇笔记", systemImage: "doc.text") }
                    }
                } else { NavigationStack { library } }
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                availableWidth = width
                if store.selected == nil { wideLayout = width >= 1000 }
            }
        }.disabled(deleteInProgress)
        .onChange(of: store.selected?.id) { _, selected in if selected == nil { wideLayout = availableWidth >= 1000 } }
        #if os(iOS)
        .fullScreenCover(item: compactSelection, onDismiss: { Task { await store.refresh() } }) { note in
            EditorView(note: note).environmentObject(store)
        }
        #else
        .sheet(item: compactSelection, onDismiss: { Task { await store.refresh() } }) { note in
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
        .sheet(item: $snapshotNote) { SnapshotReaderView(note: $0) }
        .sheet(isPresented: $syncDetails) { SyncStatusView().environmentObject(store) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [MarkdownFile.contentType, .plainText], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await store.importFiles(urls) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await store.createFolder(folderName) } }
        }
        .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil; selectedPaths.formIntersection(store.browsableNotes.map(\.path)) } })) {
            if let path = moving { FileLocationView(path: path, rename: renaming, movePaths: path == "__batch__" ? selectedPaths.sorted() : []).environmentObject(store) }
        }
        .confirmationDialog("删除选中的 \(selectedPaths.count) 篇笔记？", isPresented: $batchDelete, titleVisibility: .visible) {
            Button("删除并保留恢复记录", role: .destructive) { Task {
                deleteInProgress = true; defer { deleteInProgress = false }
                let targets = store.browsableNotes.filter { selectedPaths.contains($0.path) }
                for note in targets {
                    do { try await store.deleteNote(note); selectedPaths.remove(note.path) }
                    catch { store.error = "部分笔记未删除：" + error.localizedDescription; return }
                }
                selecting = false
            } }
        }
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
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refresh(); await store.importSharedInbox() } } }
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
            let notes = store.browsableNotes
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
    private var compactSelection: Binding<Note?> {
        Binding(get: { wideLayout ? nil : store.selected }, set: { if !wideLayout { store.selected = $0 } })
    }
    private var visibleNotes: [Note] {
        if !query.isEmpty { return searchResults }
        switch scope {
        case .recent: return store.browsableNotes
        case .favorites: return store.browsableNotes.filter { store.favorites.contains($0.path) }
        case .folders: return store.browsableNotes.filter { $0.folder == store.currentFolder }
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
                    .contextMenu {
                        Button("移动到") { renaming = false; moving = folder }
                        Button("重命名") { renaming = true; moving = folder }
                    }
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
                            Button { renaming = false; moving = note.path } label: {
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
                ContentUnavailableView {
                    Label(query.isEmpty ? "开始记录" : "没有找到笔记", systemImage: "doc.text")
                } description: {
                    Text(query.isEmpty ? "随时记下想法，或导入已有 Markdown 笔记。" : "搜索范围为整个笔记库，试试其他关键词。")
                } actions: {
                    if query.isEmpty {
                        Button("创建笔记") { store.beginNote() }.buttonStyle(.borderedProminent)
                        Button("导入笔记") { importing = true }.buttonStyle(.bordered)
                    }
                }

            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Button("取消选择") { selecting = false; selectedPaths = [] }
                    Spacer()
                    Button("移动（\(selectedPaths.count)）") { renaming = false; moving = "__batch__" }.disabled(selectedPaths.isEmpty)
                    Button("删除", role: .destructive) { batchDelete = true }.disabled(selectedPaths.isEmpty)
                }.padding().background(.bar)
            }
        }
        .navigationTitle(query.isEmpty ? scope.rawValue : "搜索笔记")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Picker("浏览范围", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 6)
                Button { syncDetails = true } label: {
                    Label(store.syncSummary, systemImage: store.syncIssue == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                        .font(.caption).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.padding(.horizontal)
            }
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
                    Button("选择笔记") { selecting = true; selectedPaths = [] }.disabled(store.selected != nil)
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
                Button { Task { await store.dailyNote() } } label: { Image(systemName: "calendar") }
                    .accessibilityLabel("今日笔记").disabled(store.loading || store.syncing)
                Button { store.beginNote() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("新建笔记").keyboardShortcut("n").disabled(store.loading || store.syncing)
            }
        }
    }
    private func noteButton(_ note: Note) -> some View {
        Button {
            if selecting {
                if selectedPaths.contains(note.path) { selectedPaths.remove(note.path) } else { selectedPaths.insert(note.path) }
            } else if store.syncing { snapshotNote = note }
            else { store.searchTerm = query; store.openNote(note) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if selecting { Image(systemName: selectedPaths.contains(note.path) ? "checkmark.circle.fill" : "circle").foregroundStyle(InkTheme.accent) }
                    Text(note.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if store.favorites.contains(note.path) { Image(systemName: "bookmark.fill").foregroundStyle(InkTheme.accent).font(.caption2) }
                    Spacer(minLength: 0)
                    Text(note.modified, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.tertiary)
                }
                if !snippet(note).isEmpty {
                    Text(highlighted(snippet(note))).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
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
            Button { renaming = false; moving = note.path } label: {
                Label("移动到", systemImage: "folder")
            }
            Button("重命名") { renaming = true; moving = note.path }
            Button { store.toggleFavorite(note.path) } label: { Label(store.favorites.contains(note.path) ? "移除书签" : "书签", systemImage: "bookmark") }
            deleteButton(note)
        }
    }
    private func snippet(_ note: Note) -> String {
        guard let term = query.split(whereSeparator: \.isWhitespace).first,
              let range = note.text.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) else { return note.excerpt }
        let start = note.text.index(range.lowerBound, offsetBy: -35, limitedBy: note.text.startIndex) ?? note.text.startIndex
        return (start == note.text.startIndex ? "" : "…") + String(note.text[start...].prefix(150)).replacingOccurrences(of: "\n", with: " ")
    }
    private func highlighted(_ value: String) -> AttributedString {
        var result = AttributedString(value)
        for term in query.split(whereSeparator: \.isWhitespace) {
            var search = result.startIndex..<result.endIndex
            while let range = result[search].range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) {
                result[range].backgroundColor = InkTheme.accent.opacity(0.18)
                result[range].font = .subheadline.bold()
                search = range.upperBound..<result.endIndex
            }
        }
        return result
    }
    private func deleteButton(_ note: Note) -> some View {
        Button(role: .destructive) { deleting = note } label: {
            Label("删除", systemImage: "trash")
        }.disabled(store.selected != nil)
    }

}

struct FileLocationView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let path: String
    let rename: Bool
    var movePaths: [String] = []
    @State private var folder = ""
    @State private var name = ""
    @State private var newFolder = ""
    @State private var working = false
    @State private var issue: String?
    private var affected: [Note] {
        store.notes.filter { note in note.metadata.links.contains { link in
            if case .found(let target) = store.noteIndex.resolve(link.target, from: note.path) {
                return (movePaths.isEmpty ? [path] : movePaths).contains { target == $0 || target.hasPrefix($0 + "/") }
            }
            return false
        } }
    }
    var body: some View {
        NavigationStack {
            Form {
                if rename { Section("名称") { TextField("名称", text: $name) } }
                else {
                    Section("目标文件夹") {
                        Text(folder.isEmpty ? "笔记库根目录" : folder).font(.caption)
                        if !folder.isEmpty { Button("上一级") { folder = (folder as NSString).deletingLastPathComponent } }
                        ForEach(store.folders.filter {
                            ($0 as NSString).deletingLastPathComponent == folder && $0 != path && !$0.hasPrefix(path + "/")
                        }, id: \.self) { child in
                            Button { folder = child } label: { Label((child as NSString).lastPathComponent, systemImage: "folder") }
                        }
                        HStack {
                            TextField("新文件夹名称", text: $newFolder)
                            Button("创建") { Task {
                                guard let vault = store.vault else { return }
                                working = true; defer { working = false }
                                do {
                                    guard validName(newFolder) else { throw VaultError.invalidPath }
                                    let target = folder.isEmpty ? newFolder : folder + "/" + newFolder
                                    try await vault.createFolder(path: target)
                                    await store.refresh(); folder = target; newFolder = ""
                                } catch { issue = error.localizedDescription }
                            } }.disabled(newFolder.isEmpty)
                        }
                    }
                }
                if !affected.isEmpty {
                    Section("受影响的引用 · \(affected.count) 篇笔记") {
                        Text("移动或重命名后这些链接可能失效。当前不会自动改写正文，请核对后再操作。")
                        ForEach(affected) { note in
                            DisclosureGroup(note.path) {
                                ForEach(Array(note.metadata.links.enumerated()), id: \.offset) { _, link in
                                    if let replacement = suggestedLink(link, from: note.path) {
                                        Text("[[" + link.target + "]] → [[" + replacement + "]]").font(.caption).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }
            .navigationTitle(rename ? "重命名" : "移动到")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(rename ? "保存" : "移到这里") { Task {
                        guard validName(name) else { issue = "名称不能包含路径分隔符或以点开头。"; return }
                        working = true; defer { working = false }
                        let finalName = rename && path.lowercased().hasSuffix(".md") ? name + ".md" : name
                        let target = folder.isEmpty ? finalName : folder + "/" + finalName
                        if target == path { dismiss(); return }
                        store.error = nil
                        if movePaths.isEmpty { await store.move(path, to: target) }
                        else {
                            for source in movePaths {
                                let destination = (folder.isEmpty ? "" : folder + "/") + (source as NSString).lastPathComponent
                                if source != destination { await store.move(source, to: destination) }
                                if store.error != nil { break }
                            }
                        }
                        if let error = store.error { issue = error; store.error = nil } else { dismiss() }
                    } }
                }
            }.disabled(working).interactiveDismissDisabled(working)
            .onAppear { folder = movePaths.isEmpty ? (path as NSString).deletingLastPathComponent : ""; name = rename && path.lowercased().hasSuffix(".md") ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : (path as NSString).lastPathComponent }
        }
    }
    private func suggestedLink(_ link: WikiLink, from source: String) -> String? {
        guard case .found(let target) = store.noteIndex.resolve(link.target, from: source),
              let moved = (movePaths.isEmpty ? [path] : movePaths).first(where: { target == $0 || target.hasPrefix($0 + "/") }) else { return nil }
        let finalName = movePaths.isEmpty ? (rename && path.lowercased().hasSuffix(".md") ? name + ".md" : name) : (moved as NSString).lastPathComponent
        let destination = (folder.isEmpty ? "" : folder + "/") + finalName + target.dropFirst(moved.count)
        let anchor = link.target.firstIndex(of: "#").map { String(link.target[$0...]) } ?? ""
        return "/" + (destination as NSString).deletingPathExtension + anchor + "|" + link.label
    }
    private func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.contains("/") && !value.contains("\\") && !value.hasPrefix(".")
    }
}

private struct SnapshotReaderView: View {
    let note: Note
    @Environment(\.dismiss) private var dismiss
    @State private var document: MarkdownDocument?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("同步期间的只读快照 · 同步结束后请关闭并重新打开，查看最新内容或编辑。附件、链接跳转和任务修改暂不可用。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let document { MarkdownReader(blocks: document.blocks, openLink: { _ in }, toggleTask: { _ in }).disabled(true) }
                    else { ProgressView() }
                }.padding()
            }.navigationTitle(note.title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { let source = note.text; document = await Task.detached { MarkdownDocument(source) }.value }
        }
    }
}

struct NoteFolderPicker: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var folder = ""
    @State private var name = ""
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                Text(folder.isEmpty ? "笔记库根目录" : folder).font(.caption)
                if !folder.isEmpty { Button("上一级") { folder = (folder as NSString).deletingLastPathComponent } }
                ForEach(store.folders.filter { ($0 as NSString).deletingLastPathComponent == folder }, id: \.self) { child in
                    Button { folder = child } label: { Label((child as NSString).lastPathComponent, systemImage: "folder") }
                }
                HStack {
                    TextField("新文件夹名称", text: $name)
                    Button("创建") { Task {
                        do {
                            guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix(".") else { throw VaultError.invalidPath }
                            let path = (folder.isEmpty ? "" : folder + "/") + name
                            try await store.vault?.createFolder(path: path)
                            await store.refresh(); folder = path; name = ""
                        } catch { issue = error.localizedDescription }
                    } }.disabled(name.isEmpty || store.syncing)
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }.navigationTitle("保存位置")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("选择此目录") { selection = folder; dismiss() } }
                }
                .onAppear { folder = selection }
        }
    }
}
