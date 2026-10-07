import SwiftUI
import InkstoneCore
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.scenePhase) var scenePhase
    @State private var tab = 0
    @State private var query = ""
    @State private var tag: String?
    @State private var newNote = false
    @State private var title = ""
    @State private var recovery = false
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { library }.tabItem { Label("笔记", systemImage: "books.vertical") }.tag(0)
            NavigationStack { tags }.tabItem { Label("标签", systemImage: "number") }.tag(1)
            NavigationStack { noteList(store.notes.filter { store.favorites.contains($0.path) }, empty: "收藏值得回看的想法", icon: "bookmark")
                .navigationTitle("收藏") }.tabItem { Label("收藏", systemImage: "bookmark") }.tag(2)
            NavigationStack { SettingsView(recovery: $recovery) }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .sheet(item: $store.selected, onDismiss: { Task { await store.refresh() } }) { note in
            EditorView(note: note).environmentObject(store)
        }
        .sheet(isPresented: $recovery) { RecoveryView(path: nil).environmentObject(store) }
        .alert("新建笔记", isPresented: $newNote) {
            TextField("笔记名称", text: $title)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await store.create(title) } }
        } message: { Text("使用 / 创建子文件夹，例如：读书/随想") }
        .alert("提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refresh() } } }
    }
    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if query.isEmpty && tag == nil {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("INKSTONE · 随身笔记", systemImage: "circle.lefthalf.filled")
                                .font(.caption.weight(.semibold)).tracking(2)
                            Spacer()
                            Text(Date(), format: .dateTime.month().day()).font(.caption)
                        }.foregroundStyle(InkTheme.accent)
                        Text("让想法，\n慢慢成形。").font(.system(size: 34, weight: .medium, design: .serif)).lineSpacing(5)
                        HStack {
                            Text("\(store.notes.count) 篇笔记  ·  \(store.tags.count) 个标签").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Button { Task { await store.dailyNote() } } label: {
                                Label("写今日", systemImage: "pencil.line").font(.subheadline.weight(.medium))
                            }.buttonStyle(.bordered).tint(InkTheme.accent)
                        }
                    }.padding(22).background(InkTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(tag.map { "#" + $0 } ?? (query.isEmpty ? "最近的笔记" : "搜索结果")).font(.headline)
                        Spacer()
                        if tag != nil { Button("全部") { tag = nil }.font(.subheadline) }
                        if store.loading { ProgressView() }
                    }
                    let results = NoteIndex.search(store.notes, query: query, tag: tag)
                    if results.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "从第一篇笔记开始" : "没有找到笔记", systemImage: "doc.text.magnifyingglass", description: Text("新建笔记，或在设置中打开已有笔记库。"))
                    } else {
                        LazyVStack(spacing: 10) { ForEach(results) { note in noteButton(note) } }
                    }
                }
                if !store.warnings.isEmpty {
                    Label("\(store.warnings.count) 个文件未能读取，详情见设置", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(InkTheme.background)
        .navigationTitle(store.vaultName)
        .searchable(text: $query, prompt: "搜索标题与正文")
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { title = ""; newNote = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建笔记").disabled(store.loading) }
        }
    }
    private var tags: some View {
        List {
            if store.tags.isEmpty { ContentUnavailableView("用标签整理想法", systemImage: "number", description: Text("在正文中写下 #标签，便能在这里找到它。")) }
            ForEach(store.tags, id: \.self) { value in
                NavigationLink {
                    noteList(store.notes.filter { $0.metadata.tags.contains(value) }, empty: "暂无笔记", icon: "number").navigationTitle("#" + value)
                } label: {
                    HStack {
                        Label(value, systemImage: "number").foregroundStyle(InkTheme.accent)
                        Spacer()
                        Text("\(store.notes.filter { $0.metadata.tags.contains(value) }.count)").foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
            }
        }.navigationTitle("标签")
    }
    private func noteList(_ notes: [Note], empty: String, icon: String) -> some View {
        ScrollView {
            if notes.isEmpty { ContentUnavailableView(empty, systemImage: icon) }
            LazyVStack(spacing: 10) { ForEach(notes) { noteButton($0) } }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.background(InkTheme.background)
    }
    private func noteButton(_ note: Note) -> some View {
        Button { store.selected = note } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(note.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    Spacer()
                    if store.favorites.contains(note.path) { Image(systemName: "bookmark.fill").foregroundStyle(InkTheme.accent).font(.caption) }
                }
                Text(note.excerpt.isEmpty ? "还没有正文" : note.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(note.modified, style: .date)
                    if !note.folder.isEmpty { Text("·"); Text(note.folder).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let tag = note.metadata.tags.first { Text("#" + tag).foregroundStyle(InkTheme.accent).lineLimit(1) }
                }.font(.caption)
                    .foregroundStyle(.tertiary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(InkTheme.surface, in: RoundedRectangle(cornerRadius: 17))
        }.buttonStyle(.plain)
        .contextMenu { Button { store.toggleFavorite(note.path) } label: { Label(store.favorites.contains(note.path) ? "取消收藏" : "收藏", systemImage: "bookmark") } }
    }
}
