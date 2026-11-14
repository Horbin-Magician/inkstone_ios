import SwiftUI
import InkstoneCore
import QuickLook
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct EditorView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    var onClose: (() -> Void)?
    @State private var current: Note
    @State private var text: String
    @State private var reading = true
    @State private var richEditorPrepared = false
    @AppStorage("markdownSourceEditing") private var sourceEditing = false
    @StateObject private var richEditor = RichEditorBridge()
    private var richDocumentID: UUID { richEditor.documentID }
    @State private var syncDetails = false
    @State private var isNew = false
    @State private var filename = ""
    @State private var targetFolder = ""
    @State private var chooseFolder = false
    @State private var scrollLine: Int?
    @State private var searchQuery = ""
    private var composing: Bool {
        get { richEditor.composing }
        nonmutating set { richEditor.setComposing(newValue) }
    }
    @State private var attachmentPicker = false
    @State private var attachmentWorking = false
    @State private var previewURL: URL?
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif
    private var autoSaveBlocked: Bool {
        get { richEditor.session.saveBlocked }
        nonmutating set { richEditor.setSavePhase(newValue ? .failed(issue ?? "保存失败") : .idle) }
    }
    @ScaledMetric(relativeTo: .body) private var readingScale = 1.0
    @AppStorage("readingSize") private var readingSize = 17.0
    @AppStorage("readingSpacing") private var readingSpacing = 5.0
    @State private var editorFocused = false
    @FocusState private var macEditorFocused: Bool
    @State private var switcher = false
    @State private var switchQuery = ""
    @State private var switchSelection: Note?
    private var saving: Bool {
        get { richEditor.isSaving }
        nonmutating set {
            if newValue { richEditor.setSavePhase(.saving) }
            else if richEditor.isSaving { richEditor.setSavePhase(.idle) }
        }
    }
    private var historySession: UUID {
        get { richEditor.session.historyID }
        nonmutating set { richEditor.session.historyID = newValue }
    }
    @State private var status = "已保存到文件"
    @State private var issue: String?
    @State private var deletePrompt = false
    @State private var history = false
    @State private var info = false
    @State private var exporting = false
    @State private var missingLink: String?
    @State private var textRevision = 0
    @State private var savedTextRevision = 0
    @State private var textDirty = false
    @State private var parsedRevision: Int?
    @State private var document: MarkdownDocument?
    @State private var characterCount = 0
    private struct ParseRequest: Equatable {
        let revision: Int
        let needed: Bool
    }
    private var parsedDocument: MarkdownDocument? { parsedRevision == textRevision ? document : nil }
    private var imageContext: ImageResourceContext {
        ImageResourceContext(library: store.imageLibraryID, notePath: current.path,
            generation: richDocumentID.uuidString + ":" + String(store.imageRevision))
    }
    private var dirty: Bool { textDirty || richEditor.hasPendingSnapshot }
    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { applyTextChange($0) })
    }
    private static nonisolated func attachmentLoader(vault: Vault?, path: String) -> @Sendable (String) async throws -> Data {
        { source in
            guard let vault else { throw VaultError.invalidPath }
            return try await vault.attachment(source, from: path)
        }
    }
    init(note: Note, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        _current = State(initialValue: note); _text = State(initialValue: note.text)
        _reading = State(initialValue: !note.text.isEmpty && note.text != "# \(note.title)\n\n")
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(reading ? "阅读" : sourceEditing ? "源码编辑" : "富文本编辑").font(.caption.weight(.semibold))
                    if isNew {
                        Button { chooseFolder = true } label: { Label(targetFolder.isEmpty ? "根目录" : targetFolder, systemImage: "folder") }.font(.caption).lineLimit(1)
                    } else { Text(current.folder.isEmpty ? "根目录" : current.folder).font(.caption).lineLimit(1) }
                    Spacer()
                    Button { syncDetails = true } label: {
                        Text(store.syncSummary).font(.caption).lineLimit(2)
                    }
                }.padding(.horizontal).frame(minHeight: 44)
                if !searchQuery.isEmpty {
                    HStack {
                        Text("查找：" + searchQuery).font(.caption)
                        Spacer()
                        Button("定位") { locateSearch() }
                        Button("清除") { searchQuery = "" }
                    }.padding(.horizontal).frame(minHeight: 44)
                }
                if isNew {
                    TextField("标题（可稍后填写）", text: $filename).textFieldStyle(.roundedBorder).padding(.horizontal)
                }
                ZStack {
                if reading {
                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let document = parsedDocument {
                                MarkdownReader(blocks: document.blocks, openLink: openLink, toggleTask: toggleTask, openAttachment: previewAttachment)
                                    .environment(\.imageResourceContext, imageContext)
                                    .environment(\.attachmentLoader, Self.attachmentLoader(vault: store.vault, path: current.path))
                            } else { ProgressView("正在解析正文…") }
                            let backlinks = store.noteIndex.backlinks(to: current.path)
                            if !backlinks.isEmpty {
                                Divider().padding(.top, 28)
                                Label("提到这篇笔记", systemImage: "link").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(backlinks) { note in Button(note.title) { navigate(to: note) } }
                            }
                        }.padding(.horizontal, MarkdownAppearance.metric("horizontal-padding")).padding(.vertical, MarkdownAppearance.metric("vertical-padding")).frame(maxWidth: MarkdownAppearance.metric("content-width"), alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
                    }.textSelection(.enabled)
                        .background(InkTheme.documentBackground)
                        .font(.system(size: readingSize * readingScale)).lineSpacing(readingSpacing)
                        .environment(\.markdownBodySize, readingSize * readingScale)
                        .onChange(of: scrollLine) { _, line in
                            if let line { withAnimation { proxy.scrollTo(line, anchor: .top) } }
                        }
                    }
                }
                    if !sourceEditing && (richEditorPrepared || !reading) {
                        RichMarkdownEditor(text: textBinding, focused: $editorFocused, composing: Binding(get: { composing }, set: { composing = $0 }),
                            active: !reading, documentID: richDocumentID, textRevision: textRevision, imageContext: imageContext, fontSize: readingSize * readingScale, lineSpacing: readingSpacing,
                            titles: store.linkTitles, titlesRevision: store.linkTitlesRevision, bridge: richEditor,
                            loadAttachment: Self.attachmentLoader(vault: store.vault, path: current.path), pasteImage: { data, ext in
                                attachmentWorking = true; defer { attachmentWorking = false }
                                return await insertImage(data, extension: ext)
                            }, onError: { issue = $0 })
                            .opacity(reading ? 0 : 1)
                            .allowsHitTesting(!reading)
                            .accessibilityHidden(reading)
                    }
                    if !reading && sourceEditing {
                    #if os(iOS)
                    MarkdownTextEditor(text: textBinding, focused: Binding(get: { editorFocused }, set: { editorFocused = $0 }), composing: Binding(get: { composing }, set: { composing = $0 }), titles: store.linkTitles, pasteImage: { data in
                        attachmentWorking = true; defer { attachmentWorking = false }
                        return await insertImage(data, extension: "png")
                    })
                    #else
                    TextEditor(text: textBinding).font(.system(.body, design: .monospaced))
                        .focused($macEditorFocused).onChange(of: editorFocused) { _, value in macEditorFocused = value }.padding(.horizontal, 10).accessibilityLabel("Markdown 正文")
                    #endif
                    }
                }
            }
            .navigationTitle(current.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Task { await transition { guard await saveIfNeeded() else { return false }; closeEditor(); return true } } } label: {
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
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { await transition { guard await refreshRichSnapshot(), !composing else { return false }; reading.toggle(); editorFocused = !reading; return true } } } label: {
                        Image(systemName: reading ? "pencil" : "book")
                    }.accessibilityLabel(reading ? "编辑笔记" : "阅读笔记").disabled(composing)
                    Group {
                        Button { Task { _ = await save() } } label: { Image(systemName: "checkmark") }
                            .disabled(saving || composing || (!dirty && !isNew && (reading || sourceEditing))).accessibilityLabel("保存笔记").keyboardShortcut("s")
                    }
                    Menu {
                        Button {
                            Task { await transition {
                                guard await refreshRichSnapshot(), !composing else { return false }
                                sourceEditing.toggle(); reading = false; editorFocused = true
                                return true
                            } }
                        } label: { Label(sourceEditing ? "切换到富文本编辑" : "切换到 Markdown 源码", systemImage: sourceEditing ? "textformat" : "chevron.left.forwardslash.chevron.right") }
                            .disabled(composing)
                        Divider()
                        #if os(iOS)
                        PhotosPicker(selection: $photo, matching: .images) { Label("照片追加到末尾", systemImage: "photo") }
                        #endif
                        Button { attachmentPicker = true } label: { Label("附件追加到末尾", systemImage: "paperclip") }
                        Button { store.toggleFavorite(current.path) } label: { Label(store.favorites.contains(current.path) ? "移除书签" : "书签", systemImage: "bookmark") }
                        Button { Task { if await refreshRichSnapshot() { info = true } } } label: { Label("大纲与链接", systemImage: "list.bullet.indent") }
                        Button { history = true } label: { Label("历史版本", systemImage: "clock.arrow.circlepath") }
                        Button { Task { if await refreshRichSnapshot() { exporting = true } } } label: { Label("导出 Markdown", systemImage: "square.and.arrow.up") }
                        Button { Task { await saveCopy() } } label: { Label("另存副本", systemImage: "doc.on.doc") }
                        Divider()
                        Button(role: .destructive) { deletePrompt = true } label: { Label("删除笔记", systemImage: "trash") }.disabled(dirty || isNew)
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("笔记操作").disabled(saving || composing)
                }
            }
            .disabled(attachmentWorking)
            .interactiveDismissDisabled(needsSave || saving || attachmentWorking || (!reading && !sourceEditing))
            .task(id: current.path) {
                isNew = !store.notes.contains { $0.path == current.path }
                filename = isNew ? "" : current.title
                targetFolder = current.folder
                status = isNew ? "输入后自动保存" : "已保存到文件"
                if searchQuery.isEmpty { searchQuery = store.searchTerm }
                editorFocused = !reading
                locateSearch()
            }
            .sheet(isPresented: $chooseFolder) { NoteFolderPicker(selection: $targetFolder).environmentObject(store) }
            .sheet(isPresented: $syncDetails) { SyncStatusView().environmentObject(store) }
            .onChange(of: store.requestedNote) { _, note in
                if let note { store.requestedNote = nil; navigate(to: note) }
            }
            .onChange(of: text) { _, _ in scheduleSave() }
            .onReceive(richEditor.editEvents) { _ in scheduleSave() }
            .onChange(of: filename) { _, _ in if isNew { scheduleSave() } }
            .onChange(of: targetFolder) { _, _ in if isNew { scheduleSave() } }
            .onChange(of: reading) { _, value in
                if value { flushSave() } else { richEditorPrepared = true }
            }
            .task(id: parsedRevision) {
                // Warm the web shell after the reader has content; defer document
                // parsing until editing so opening a note does not parse it twice.
                guard reading, parsedDocument != nil, !sourceEditing, !richEditorPrepared else { return }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                richEditorPrepared = true
            }
            .onChange(of: editorFocused) { _, value in if !value { flushSave() } }
            .onChange(of: composing) { _, marked in if !marked { scheduleSave() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { flushSave() } }
            .onDisappear { flushSave() }
            .task(id: ParseRequest(revision: textRevision, needed: reading || info)) {
                guard reading || info, parsedDocument == nil else { return }
                let source = text
                let revision = textRevision
                let worker = Task.detached(priority: .userInitiated) { () -> (MarkdownDocument, Int)? in
                    guard !Task.isCancelled else { return nil }
                    let document = MarkdownDocument(source)
                    guard !Task.isCancelled else { return nil }
                    return (document, source.count)
                }
                let result = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let result, textRevision == revision else { return }
                document = result.0; characterCount = result.1; parsedRevision = revision
                locateSearch()
            }
            .confirmationDialog("删除这篇笔记？", isPresented: $deletePrompt, titleVisibility: .visible) {
                Button("删除笔记", role: .destructive) { Task { await delete() } }
            } message: { Text("会先保存一份本机恢复记录。共享文件夹中的删除可能同步到其他设备。") }
            .alert("创建链接指向的笔记？", isPresented: Binding(get: { missingLink != nil }, set: { if !$0 { missingLink = nil } })) {
                Button("创建并编辑") {
                    guard let target = missingLink else { return }
                    missingLink = nil
                    Task { await transition {
                        guard await saveIfNeeded(), let vault = store.vault else { return false }
                        do {
                            let path = try NoteIndex.creationPath(target, from: current.path)
                            let note = try await vault.create(path: path, text: "")
                            await store.refresh(); switchNote(note); reading = false; editorFocused = true
                            return true
                        } catch { issue = error.localizedDescription; return false }
                    } }
                }
                Button("取消", role: .cancel) { missingLink = nil }
            } message: { Text((missingLink ?? "") + "\n当前修改会先保存到文件。") }
            .alert("提示", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("好") { issue = nil }
                if richEditor.snapshotFailure != nil {
                    Button("使用最近快照转到源码") {
                        richEditor.useLastSnapshot()
                        sourceEditing = true; reading = false; editorFocused = true
                        issue = nil; status = "已使用最近取得的快照，请核对正文"
                    }
                }
            } message: { Text(issue ?? "") }
            .quickLookPreview($previewURL)
            .onChange(of: previewURL) { old, new in
                if let old, old != new { try? FileManager.default.removeItem(at: old) }
            }
            .fileImporter(isPresented: $attachmentPicker, allowedContentTypes: [.data]) { result in
                Task {
                    attachmentWorking = true; defer { attachmentWorking = false }
                    do {
                        let url = try result.get()
                        let notePath = try await attachmentNotePath()
                        if let path = try await store.vault?.importAttachment(url, from: notePath) {
                            applyTextChange(text + "\n[附件](" + path + ")\n")
                            reading = false
                        }
                    } catch { issue = error.localizedDescription }
                }
            }
            #if os(iOS)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    attachmentWorking = true; defer { attachmentWorking = false }
                    do {
                        if let data = try await item.loadTransferable(type: Data.self),
                           let path = await insertImage(data, extension: item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg") {
                            applyTextChange(text + "\n![图片](" + path + ")\n"); reading = false
                        }
                    } catch { issue = error.localizedDescription }
                    photo = nil
                }
            }
            #endif
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
    private func closeEditor() {
        richEditor.saveTask?.cancel()
        richEditor.saveTask = nil
        if let onClose { onClose() } else { dismiss() }
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
                            Button(String(repeating: "  ", count: heading.level - 1) + heading.title) {
                                reading = true; info = false
                                Task { try? await Task.sleep(for: .milliseconds(300)); scrollLine = heading.line }
                            }
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
    /// Inserting the first attachment commits the selected draft location. Later
    /// attachments and all readers use this persisted path, even before autosave.
    private func attachmentNotePath() async throws -> String {
        guard await refreshRichSnapshot(), !saving, !composing else { throw VaultError.busy }
        if isNew, !(await save(snapshotReady: true)) { throw VaultError.conflict }
        guard !isNew else { throw VaultError.conflict }
        return current.path
    }
    private func insertImage(_ data: Data, extension ext: String) async -> String? {
        do {
            let notePath = try await attachmentNotePath()
            return try await store.vault?.insertAttachment(data, extension: ext, from: notePath)
        }
        catch { issue = error.localizedDescription; return nil }
    }
    private func previewAttachment(_ source: String) {
        Task {
            do {
                guard let data = try await store.vault?.attachment(source, from: current.path) else { return }
                let name = URLComponents(string: source)?.path ?? "attachment"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + (name as NSString).lastPathComponent)
                try data.write(to: url, options: .atomic)
                previewURL = url
            } catch { issue = "附件无法打开：" + error.localizedDescription }
        }
    }
    private func locateSearch() {
        guard let term = searchQuery.split(whereSeparator: \.isWhitespace).first,
              let range = text.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]),
              let document = parsedDocument else { return }
        let line = text[..<range.lowerBound].filter { $0 == "\n" }.count
        let target = document.blocks.last(where: { $0.line <= line })?.line
        scrollLine = nil
        Task { await Task.yield(); scrollLine = target }
    }
    private func applyTextChange(_ newValue: String) {
        guard text != newValue else { return }
        text = newValue
        textRevision &+= 1
        updateTextDirty()
    }
    private func updateTextDirty() {
        textDirty = textRevision != savedTextRevision && text != current.text
    }
    private func switchNote(_ note: Note) {
        richEditor.saveTask?.cancel()
        richEditor.saveTask = nil
        richEditor.resetSession()
        isNew = !store.notes.contains { $0.path == note.path }
        current = note
        text = note.text
        textRevision &+= 1
        savedTextRevision = textRevision
        textDirty = false
        parsedRevision = nil
        document = nil
        reading = !note.text.isEmpty
        editorFocused = !reading
        status = "已保存到文件"
    }
    private func navigate(to note: Note) { Task { await transition { guard await saveIfNeeded() else { return false }; switchNote(note); return true } } }
    private func openLink(_ target: String) {
        switch store.noteIndex.resolve(target, from: current.path) {
        case .found(let path): if let note = store.notes.first(where: { $0.path == path }) { navigate(to: note) }
        case .missing: missingLink = target
        case .ambiguous: issue = "有多篇同名笔记，请在链接中补充文件夹路径。"
        }
    }
    private func toggleTask(_ line: Int) {
        guard let document = parsedDocument else { return }
        applyTextChange(document.togglingTask(at: line))
    }

    private var needsSave: Bool { dirty || (isNew && !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    private func setStatus(_ value: String) {
        if status != value { status = value }
    }
    private func scheduleSave() {
        richEditor.saveTask?.cancel()
        guard needsSave else { setStatus(isNew ? "输入后自动保存" : "已保存到文件"); return }
        guard !autoSaveBlocked else { return }
        setStatus("等待保存…")
        guard !composing else { return }
        richEditor.saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(450))
                try Task.checkCancellation()
                // The debounce task must not cancel the write it starts.
                richEditor.saveTask = nil
                _ = await saveIfNeeded()
            } catch is CancellationError {} catch { issue = error.localizedDescription }
        }
    }
    private func transition(_ operation: () async -> Bool) async {
        guard richEditor.beginTransition() else { return }
        let completed = await operation()
        // Successful navigation/mode changes leave the old document frozen until
        // dismantle or the next load. Failed saves resume the same live document.
        richEditor.endTransition(resume: !completed)
    }
    private func refreshRichSnapshot() async -> Bool {
        if let failure = richEditor.snapshotFailure { issue = failure; return false }
        guard !reading && !sourceEditing else { return true }
        guard await richEditor.flush(freeze: richEditor.session.transitioning) else {
            setStatus("保存失败 · 尚未取得最新内容")
            issue = richEditor.snapshotFailure
            return false
        }
        guard !richEditor.session.snapshotComposing, !richEditor.hasPendingSnapshot else {
            if !composing { scheduleSave() }
            return false
        }
        return true
    }
    private func saveIfNeeded() async -> Bool {
        guard await refreshRichSnapshot() else { return false }
        guard !saving, !composing else { return false }
        guard needsSave else { return richEditor.session.canNavigate(textIsDirty: false) }
        guard await save(snapshotReady: true) else { return false }
        return richEditor.session.canNavigate(textIsDirty: needsSave)
    }
    private func flushSave() {
        richEditor.saveTask?.cancel()
        richEditor.saveTask = nil
        guard !autoSaveBlocked else { return }
        Task { _ = await saveIfNeeded() }
    }
    private func save(snapshotReady: Bool = false) async -> Bool {
        if !snapshotReady, !(await refreshRichSnapshot()) { return false }
        guard !saving, !composing, let vault = store.vault else { return false }
        saving = true; richEditor.saveTask?.cancel(); richEditor.saveTask = nil; defer { saving = false; if needsSave && !autoSaveBlocked { scheduleSave() } }
        do {
            let savingRevision = textRevision
            let saved: Note
            if isNew {
                let path = try Note.draftPath(folder: targetFolder, filename: filename, fallback: current.path)
                saved = try await vault.create(path: path, text: text)
                isNew = false
            } else {
                saved = try await vault.save(path: current.path, text: text, expected: current.text, historySession: historySession)
            }
            await store.acceptSaved(saved)
            current = saved; savedTextRevision = savingRevision; updateTextDirty()
            autoSaveBlocked = false; setStatus("已保存到文件"); return true
        } catch { issue = error.localizedDescription; autoSaveBlocked = true; setStatus("保存失败 · 修改尚未写入文件"); return false }
    }
    private func saveCopy() async {
        guard await refreshRichSnapshot() else { return }
        guard !saving, !composing, let vault = store.vault else { return }
        saving = true; richEditor.saveTask?.cancel(); richEditor.saveTask = nil; defer { saving = false; if needsSave && !autoSaveBlocked { scheduleSave() } }
        do {
            let savingRevision = textRevision
            let path = (current.path as NSString).deletingPathExtension + "-副本-" + UUID().uuidString.prefix(6) + ".md"
            let copy = try await vault.create(path: path, text: text)
            await store.acceptSaved(copy); historySession = UUID()
            current = copy; savedTextRevision = savingRevision; updateTextDirty()
            isNew = false; autoSaveBlocked = false; setStatus("已保存到文件")
        } catch { issue = error.localizedDescription }
    }
    private func delete() async {
        guard await refreshRichSnapshot() else { return }
        guard !dirty else { issue = "请先保存最新修改再删除笔记。"; return }
        saving = true; defer { saving = false }
        do { try await store.deleteNote(current); closeEditor() }
        catch { issue = error.localizedDescription }
    }
}

#if os(iOS)
/// UITextView keeps selection, undo and marked text under the input system's control.
private struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var composing: Bool
    var titles: [String]
    var pasteImage: (Data) async -> String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = ImagePasteTextView()
        view.onImage = { [weak coordinator = context.coordinator] data in
            Task { @MainActor in
                guard let coordinator, let path = await coordinator.parent.pasteImage(data) else { return }
                coordinator.view?.insertText("![图片](" + path + ")")
            }
        }
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 20, right: 12)
        view.accessibilityLabel = "Markdown 正文"
        view.keyboardDismissMode = .interactive
        view.text = text
        context.coordinator.view = view
        let bar = UIToolbar()
        bar.sizeToFit()
        let actions: [(String, String)] = [("标题", "## "), ("列表", "- "), ("待办", "- [ ] "), ("链接", "[["), ("缩进", "    ")]
        var items = actions.map { label, insertion in
            UIBarButtonItem(title: label, primaryAction: UIAction { [weak view] _ in view?.insertText(insertion) })
        }
        let completions = UIBarButtonItem(title: "补全", menu: UIMenu(children: []))
        completions.isEnabled = false
        context.coordinator.completions = completions
        items.append(completions)
        items.append(UIBarButtonItem(title: "撤销", primaryAction: UIAction { [weak view] _ in view?.undoManager?.undo() }))
        items.append(UIBarButtonItem(systemItem: .flexibleSpace))
        items.append(UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak view] _ in view?.resignFirstResponder() }))
        bar.items = items
        view.inputAccessoryView = bar
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = context.environment.isEnabled
        if view.markedTextRange == nil && view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        }
        (view as? ImagePasteTextView)?.wantsFocus = focused
        if focused && !view.isFirstResponder && view.window != nil { DispatchQueue.main.async { view.becomeFirstResponder() } }
        if !focused && view.isFirstResponder { view.resignFirstResponder() }
    }
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextEditor
        weak var view: UITextView?
        var completions: UIBarButtonItem?
        init(_ parent: MarkdownTextEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false; parent.composing = false }
        func textViewDidChange(_ textView: UITextView) {
            parent.composing = textView.markedTextRange != nil
            parent.text = textView.text
            updateCompletions(textView)
        }
        private func updateCompletions(_ textView: UITextView) {
            completions?.isEnabled = false
            guard textView.markedTextRange == nil else { return }
            let before = (textView.text as NSString).substring(to: textView.selectedRange.location)
            guard let opener = before.range(of: "[[", options: .backwards) else { return }
            let query = String(before[opener.upperBound...])
            guard !query.contains("]"), !query.contains("\n") else { return }
            let matches = parent.titles.filter { query.isEmpty || $0.localizedStandardContains(query) }.prefix(12)
            let replacement = NSRange(opener.lowerBound..<before.endIndex, in: before)
            completions?.menu = UIMenu(children: matches.map { target in
                UIAction(title: target) { [weak textView] _ in
                    guard let textView, (textView.text as NSString).length >= NSMaxRange(replacement) else { return }
                    textView.selectedRange = replacement
                    textView.insertText("[[" + target + "]]")
                }
            })
            completions?.isEnabled = !matches.isEmpty
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.composing = textView.markedTextRange != nil
            updateCompletions(textView)
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", textView.markedTextRange == nil, range.length == 0 else { return true }
            let before = (textView.text as NSString).substring(to: range.location)
            let line = before.components(separatedBy: "\n").last ?? ""
            guard let markerRange = line.range(of: #"^\s*(?:[-+*] (?:\[[ xX]\] )?|[0-9]+\. )"#, options: .regularExpression) else { return true }
            var marker = String(line[markerRange])
            if line[markerRange.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                textView.selectedRange = NSRange(location: range.location - (marker as NSString).length, length: (marker as NSString).length)
                textView.insertText("\n")
            } else {
                marker = marker.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
                if let digits = marker.range(of: #"[0-9]+"#, options: .regularExpression), let n = Int(marker[digits]), n < Int.max {
                    marker.replaceSubrange(digits, with: String(n + 1))
                }
                textView.insertText("\n" + marker)
            }
            return false
        }
    }
}
private final class ImagePasteTextView: UITextView {
    var wantsFocus = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && wantsFocus { DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() } }
    }
    var onImage: ((Data) -> Void)?
    override func paste(_ sender: Any?) {
        if let image = UIPasteboard.general.image, let data = image.pngData() { onImage?(data) }
        else { super.paste(sender) }
    }
}

#endif
