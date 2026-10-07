import SwiftUI
import InkstoneCore

struct EditorView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @State private var current: Note
    @State private var text: String
    @State private var reading = true
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
    private var dirty: Bool { text != current.text }
    init(note: Note) {
        _current = State(initialValue: note); _text = State(initialValue: note.text)
        _reading = State(initialValue: note.text != "# \(note.title)\n\n")
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Picker("编辑模式", selection: $reading) { Text("阅读").tag(true); Text("源码").tag(false) }.pickerStyle(.segmented).frame(maxWidth: 230)
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(.secondary).accessibilityLabel("保存状态：" + status)
                }.padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                if reading {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text(current.folder.isEmpty ? "我的笔记" : current.folder)
                                Spacer()
                                Text("\(text.count) 字符")
                            }.font(.caption).foregroundStyle(.secondary)
                            MarkdownReader(text: text, openLink: openLink, toggleTask: toggleTask)
                            let backlinks = NoteIndex.backlinks(to: current.path, notes: store.notes)
                            if !backlinks.isEmpty {
                                Divider().padding(.top, 28)
                                Label("提到这篇笔记", systemImage: "link").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(backlinks) { note in Button(note.title) { navigate(to: note) } }
                            }
                        }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
                    }.textSelection(.enabled)
                } else {
                    TextEditor(text: $text).font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 14).accessibilityLabel("Markdown 正文")
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
                    Button("完成") { if dirty { closePrompt = true } else { dismiss() } }.disabled(saving)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { _ = await save() } } label: { Image(systemName: "checkmark") }.disabled(!dirty || saving).accessibilityLabel("保存笔记").keyboardShortcut("s")
                    Menu {
                        Button { store.toggleFavorite(current.path) } label: { Label(store.favorites.contains(current.path) ? "取消收藏" : "收藏", systemImage: "bookmark") }
                        Button { info = true } label: { Label("大纲与链接", systemImage: "list.bullet.indent") }
                        Button { history = true } label: { Label("历史与草稿", systemImage: "clock.arrow.circlepath") }
                        Button { exporting = true } label: { Label("导出 Markdown", systemImage: "square.and.arrow.up") }
                        Button { Task { await saveCopy() } } label: { Label("另存副本", systemImage: "doc.on.doc") }
                        Divider()
                        Button(role: .destructive) { deletePrompt = true } label: { Label("删除笔记", systemImage: "trash") }.disabled(dirty)
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("笔记操作").disabled(saving)
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(dirty || saving)
            .onChange(of: text) { _, _ in scheduleDraft() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { flushDraft() } }
            .onDisappear { flushDraft() }
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
            .fileExporter(isPresented: $exporting, document: MarkdownFile(text: text), contentType: MarkdownFile.contentType, defaultFilename: current.title + ".md") { result in
                if case .failure(let error) = result { issue = error.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 600)
        #endif
    }
    private var outline: some View {
        NavigationStack {
            List {
                Section("大纲") {
                    if MarkdownMetadata(text).headings.isEmpty { Text("暂无标题").foregroundStyle(.secondary) }
                    ForEach(MarkdownMetadata(text).headings) { heading in
                        Text(String(repeating: "  ", count: heading.level - 1) + heading.title)
                    }
                }
                Section("双向链接") {
                    ForEach(Array(MarkdownMetadata(text).links.enumerated()), id: \.offset) { _, link in
                        Button(link.label) { info = false; openLink(link.target) }
                    }
                }
            }.navigationTitle("大纲与链接").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { info = false } } }
        }
    }
    private func switchNote(_ note: Note) { draftTask?.cancel(); current = note; text = note.text; status = "已保存"; pendingLink = nil }
    private func navigate(to note: Note) { if dirty { pendingLink = note; linkPrompt = true } else { switchNote(note) } }
    private func openLink(_ target: String) {
        switch NoteIndex.resolve(target, from: current.path, notes: store.notes) {
        case .found(let path): if let note = store.notes.first(where: { $0.path == path }) { navigate(to: note) }
        case .missing: issue = "尚未找到「\(target)」。可返回笔记列表创建对应笔记。"
        case .ambiguous: issue = "有多篇同名笔记，请在链接中补充文件夹路径。"
        }
    }
    private func toggleTask(_ line: Int) {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        if let range = lines[line].range(of: #"\[[ xX]\]"#, options: .regularExpression) {
            let done = lines[line][range].lowercased() == "[x]"
            lines[line].replaceSubrange(range, with: done ? "[ ]" : "[x]")
            text = lines.joined(separator: "\n")
        }
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
        guard let vault = store.vault else { return }
        saving = true; defer { saving = false }
        do { try await vault.trash(path: current.path, expected: current.text); await store.refresh(); dismiss() }
        catch { issue = error.localizedDescription }
    }
}
