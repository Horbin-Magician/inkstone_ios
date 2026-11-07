import SwiftUI
import InkstoneCore

struct EditorView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @State private var current: Note
    @State private var text: String
    @State private var reading = true
    @FocusState private var editorFocused: Bool
    @State private var switcher = false
    @State private var switchQuery = ""
    @State private var switchSelection: Note?
    @State private var saving = false
    @State private var draftTask: Task<Void, Never>?
    @State private var status = "已保存"
    @State private var issue: String?
    @State private var closePrompt = false
    @State private var deletePrompt = false
    @State private var history = false
    @State private var info = false
    @State private var exporting = false
    @State private var pendingLink: Note?
    @State private var linkPrompt = false
    @State private var parsedSource: String?
    @State private var document: MarkdownDocument?
    @State private var characterCount = 0
    private struct ParseRequest: Equatable {
        let text: String
        let needed: Bool
    }
    private var parsedDocument: MarkdownDocument? { parsedSource == text ? document : nil }
    private var dirty: Bool { text != current.text }
    init(note: Note) {
        _current = State(initialValue: note); _text = State(initialValue: note.text)
        _reading = State(initialValue: note.text != "# \(note.title)\n\n")
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if reading {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let document = parsedDocument {
                                MarkdownReader(blocks: document.blocks, openLink: openLink, toggleTask: toggleTask)
                            } else { ProgressView("正在解析正文…") }
                            let backlinks = store.noteIndex.backlinks(to: current.path)
                            if !backlinks.isEmpty {
                                Divider().padding(.top, 28)
                                Label("提到这篇笔记", systemImage: "link").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(backlinks) { note in Button(note.title) { navigate(to: note) } }
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
                    }.textSelection(.enabled)
                } else {
                    TextEditor(text: $text).font(.system(.body, design: .monospaced))
                        .focused($editorFocused)
                        .padding(.horizontal, 10).accessibilityLabel("Markdown 正文")
                        #if os(iOS)
                        .textInputAutocapitalization(.sentences)
                        .scrollDismissesKeyboard(.interactively)
                        #endif
                }
            }
            .navigationTitle(current.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { if dirty { closePrompt = true } else { dismiss() } } label: {
                        Image(systemName: "chevron.left")
                    }.accessibilityLabel("返回笔记列表").disabled(saving)
                }
                ToolbarItem(placement: .principal) {
                    Button { editorFocused = false; switcher = true } label: {
                        VStack(spacing: 1) {
                            HStack(spacing: 4) {
                                Text(current.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                            Text(status).font(.caption2).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary)
                    }.buttonStyle(.plain).accessibilityLabel(current.title + "，" + status + "，切换笔记")
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Text("Markdown").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { editorFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("收起键盘")
                }
                #endif
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { reading.toggle(); editorFocused = !reading } label: {
                        Image(systemName: reading ? "pencil" : "book")
                    }.accessibilityLabel(reading ? "编辑 Markdown 源码" : "阅读笔记")
                    if dirty {
                        Button { Task { _ = await save() } } label: { Image(systemName: "checkmark") }
                            .disabled(saving).accessibilityLabel("保存笔记").keyboardShortcut("s")
                    }
                    Menu {
                        Button { store.toggleFavorite(current.path) } label: { Label(store.favorites.contains(current.path) ? "移除书签" : "书签", systemImage: "bookmark") }
                        Button { info = true } label: { Label("大纲与链接", systemImage: "list.bullet.indent") }
                        Button { history = true } label: { Label("历史与草稿", systemImage: "clock.arrow.circlepath") }
                        Button { exporting = true } label: { Label("导出 Markdown", systemImage: "square.and.arrow.up") }
                        Button { Task { await saveCopy() } } label: { Label("另存副本", systemImage: "doc.on.doc") }
                        Divider()
                        Button(role: .destructive) { deletePrompt = true } label: { Label("删除笔记", systemImage: "trash") }.disabled(dirty)
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("笔记操作").disabled(saving)
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(dirty || saving)
            .onAppear { editorFocused = !reading }
            .onChange(of: text) { _, _ in scheduleDraft() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { flushDraft() } }
            .onDisappear { flushDraft() }
            .task(id: ParseRequest(text: text, needed: reading || info)) {
                guard reading || info, parsedDocument == nil else { return }
                let source = text
                let worker = Task.detached(priority: .userInitiated) { () -> (MarkdownDocument, Int)? in
                    guard !Task.isCancelled else { return nil }
                    let document = MarkdownDocument(source)
                    guard !Task.isCancelled else { return nil }
                    return (document, source.count)
                }
                let result = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let result else { return }
                document = result.0; characterCount = result.1; parsedSource = source
            }
            .confirmationDialog("保存本次修改？", isPresented: $closePrompt, titleVisibility: .visible) {
                Button("保存并关闭") { Task { if await save() { dismiss() } } }
                Button("保留恢复草稿并关闭") { Task { if await persistDraft() { dismiss() } } }
                Button("继续编辑", role: .cancel) {}
            } message: { Text("保留草稿不会修改 Markdown 原文件，可在历史与草稿中恢复。") }
            .confirmationDialog("打开链接前保存修改？", isPresented: $linkPrompt, titleVisibility: .visible) {
                Button("保存并打开") { Task { if await save(), let note = pendingLink { switchNote(note) } } }
                Button("继续编辑", role: .cancel) { pendingLink = nil }
            }
            .confirmationDialog("删除这篇笔记？", isPresented: $deletePrompt, titleVisibility: .visible) {
                Button("删除笔记", role: .destructive) { Task { await delete() } }
            } message: { Text("会先保存一份本机恢复记录。共享文件夹中的删除可能同步到其他设备。") }
            .alert("提示", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("好") { issue = nil }
            } message: { Text(issue ?? "") }
            .sheet(isPresented: $history) { RecoveryView(path: current.path).environmentObject(store) }
            .sheet(isPresented: $info) { outline }
            .sheet(isPresented: $switcher, onDismiss: {
                switchQuery = ""
                if let note = switchSelection { switchSelection = nil; navigate(to: note) }
            }) { noteSwitcher }
            .fileExporter(isPresented: $exporting, document: MarkdownFile(text: text), contentType: MarkdownFile.contentType, defaultFilename: current.title + ".md") { result in
                if case .failure(let error) = result { issue = error.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 600)
        #endif
    }
    private var noteSwitcher: some View {
        NavigationStack {
            List {
                let notes = store.notes.filter {
                    switchQuery.isEmpty || $0.title.localizedStandardContains(switchQuery) || $0.path.localizedStandardContains(switchQuery)
                }
                if notes.isEmpty { Text("没有找到笔记").foregroundStyle(.secondary) }
                ForEach(notes) { note in
                    Button {
                        if note.path != current.path { switchSelection = note }
                        switcher = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.title).foregroundStyle(.primary).lineLimit(1)
                                if !note.folder.isEmpty { Text(note.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            if note.path == current.path { Image(systemName: "checkmark").accessibilityLabel("当前笔记") }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.listStyle(.plain)
            .navigationTitle("切换笔记")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $switchQuery, prompt: "查找标题或路径")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { switcher = false } } }
        }
    }
    private var outline: some View {
        NavigationStack {
            List {
                Section("笔记信息") {
                    LabeledContent("位置", value: current.folder.isEmpty ? store.vaultName : current.folder)
                    if parsedDocument != nil { LabeledContent("字符数", value: "\(characterCount)") }
                }
                if let document = parsedDocument {
                    let headings = document.headings
                    Section("大纲") {
                        if headings.isEmpty { Text("暂无标题").foregroundStyle(.secondary) }
                        ForEach(headings) { heading in
                            Text(String(repeating: "  ", count: heading.level - 1) + heading.title)
                        }
                    }
                    if !document.links.isEmpty {
                        Section("双向链接") {
                            ForEach(Array(document.links.enumerated()), id: \.offset) { _, link in
                                Button(link.label) { info = false; openLink(link.target) }
                            }
                        }
                    }
                } else { ProgressView("正在解析正文…") }
            }.navigationTitle("大纲与链接").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { info = false } } }
        }
    }
    private func switchNote(_ note: Note) { draftTask?.cancel(); current = note; text = note.text; status = "已保存"; pendingLink = nil }
    private func navigate(to note: Note) { if dirty { pendingLink = note; linkPrompt = true } else { switchNote(note) } }
    private func openLink(_ target: String) {
        switch store.noteIndex.resolve(target, from: current.path) {
        case .found(let path): if let note = store.notes.first(where: { $0.path == path }) { navigate(to: note) }
        case .missing: issue = "尚未找到「\(target)」。可返回笔记列表创建对应笔记。"
        case .ambiguous: issue = "有多篇同名笔记，请在链接中补充文件夹路径。"
        }
    }
    private func toggleTask(_ line: Int) {
        guard let document = parsedDocument else { return }
        text = document.togglingTask(at: line)
    }

    private func scheduleDraft() {
        draftTask?.cancel()
        guard dirty else { status = "已保存"; return }
        status = "未保存"
        let path = current.path, content = text, vault = store.vault
        draftTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation()
                try await vault?.writeDraft(path: path, text: content)
                if !Task.isCancelled { status = "草稿已保护" }
            } catch is CancellationError {} catch { issue = "草稿保存失败：" + error.localizedDescription }
        }
    }
    private func persistDraft() async -> Bool {
        draftTask?.cancel()
        guard dirty else { return true }
        do { try await store.vault?.writeDraft(path: current.path, text: text); return true }
        catch { issue = error.localizedDescription; return false }
    }
    private func flushDraft() {
        draftTask?.cancel()
        guard dirty else { return }
        let path = current.path, content = text, vault = store.vault
        Task { do { try await vault?.writeDraft(path: path, text: content) } catch { store.error = error.localizedDescription } }
    }
    private func save() async -> Bool {
        guard let vault = store.vault else { return false }
        saving = true; draftTask?.cancel(); defer { saving = false }
        do {
            let saved = try await vault.save(path: current.path, text: text, expected: current.text)
            current = saved; status = "已保存"; await store.refresh(); return true
        } catch { issue = error.localizedDescription; return false }
    }
    private func saveCopy() async {
        guard let vault = store.vault else { return }
        saving = true; draftTask?.cancel(); defer { saving = false }
        do {
            let path = (current.path as NSString).deletingPathExtension + "-副本-" + UUID().uuidString.prefix(6) + ".md"
            let copy = try await vault.create(path: path, text: text)
            current = copy; status = "已保存"; await store.refresh()
        } catch { issue = error.localizedDescription }
    }
    private func delete() async {
        saving = true; defer { saving = false }
        do { try await store.deleteNote(current); dismiss() }
        catch { issue = error.localizedDescription }
    }
}
