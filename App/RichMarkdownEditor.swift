import SwiftUI
import Combine
import WebKit
import UniformTypeIdentifiers
import InkstoneCore

/// Flush the WebKit editing transaction before saving or replacing an editor.
@MainActor final class RichEditorBridge: ObservableObject {
    weak var webView: WKWebView?
    var session: EditorSession {
        didSet { syncPublishedState() }
    }
    @Published private(set) var documentID: UUID
    @Published private(set) var hasPendingSnapshot: Bool
    @Published private(set) var composing: Bool
    @Published private(set) var isSaving: Bool
    @Published private(set) var snapshotFailure: String?
    let editEvents = PassthroughSubject<Void, Never>()
    var saveTask: Task<Void, Never>?
    var activeSaveTask: Task<Bool, Never>?
    var receive: (([String: Any]) -> Bool)?
    private var pendingFlush: (documentID: UUID, token: UUID, frozen: Bool, task: Task<Bool, Never>)?

    init() {
        let initial = EditorSession()
        self.session = initial
        self.documentID = initial.documentID
        self.hasPendingSnapshot = initial.hasPendingSnapshot
        self.composing = initial.composing
        self.isSaving = initial.isSaving
        self.snapshotFailure = initial.snapshotFailure
    }

    private func syncPublishedState() {
        if documentID != session.documentID { documentID = session.documentID }
        let pending = session.hasPendingSnapshot
        if hasPendingSnapshot != pending { hasPendingSnapshot = pending }
        if composing != session.composing { composing = session.composing }
        let saving = session.isSaving
        if isSaving != saving { isSaving = saving }
        if snapshotFailure != session.snapshotFailure { snapshotFailure = session.snapshotFailure }
    }

    func notifyChanged(version: Int, composing: Bool) {
        let previousVersion = session.editingVersion
        session.changed(version: version, composing: composing)
        if session.editingVersion != previousVersion { editEvents.send() }
    }
    func resetSession() { session = EditorSession() }
    func useLastSnapshot() { session.useLastSnapshot() }
    func setComposing(_ value: Bool) { if session.composing != value { session.composing = value } }
    func setSavePhase(_ phase: EditorSession.SavePhase) { if session.savePhase != phase { session.savePhase = phase } }

    func beginTransition() -> Bool {
        guard !session.transitioning, !session.composing else { return false }
        session.transitioning = true
        return true
    }
    func command(_ title: String) {
        guard let webView else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript("return window.inkstone?.command(title) ?? false", arguments: ["title": title], in: nil, contentWorld: .page)
        }
    }
    func endTransition(resume: Bool) {
        session.transitioning = false
        if resume { webView?.evaluateJavaScript("window.inkstone?.releaseSnapshot()") }
    }
    func flush(freeze: Bool = false) async -> Bool {
        let documentID = session.documentID
        if let pendingFlush, pendingFlush.documentID == documentID {
            if pendingFlush.frozen || !freeze { return await pendingFlush.task.value }
            _ = await pendingFlush.task.value
        }
        let token = UUID()
        let task = Task { await readSnapshot(documentID: documentID, freeze: freeze) }
        pendingFlush = (documentID, token, freeze, task)
        defer { if pendingFlush?.token == token { pendingFlush = nil } }
        return await task.value
    }
    private func readSnapshot(documentID: UUID, freeze: Bool) async -> Bool {
        guard documentID == session.documentID, session.snapshotFailure == nil else { return false }
        do {
            guard let webView else { throw SyncFailureForEditor.missingSnapshot }
            let result = try await webView.evaluateJavaScript("window.inkstone?.flush(\(freeze ? "true" : "false"))")
            guard self.webView === webView, documentID == session.documentID,
                  let snapshot = result as? [String: Any], receive?(snapshot) == true else {
                throw SyncFailureForEditor.missingSnapshot
            }
            return true
        } catch {
            if documentID == session.documentID {
                session.snapshotFailure = "无法取得最新编辑内容，尚未保存：" + error.localizedDescription
            }
            return false
        }
    }
    private enum SyncFailureForEditor: LocalizedError {
        case missingSnapshot
        var errorDescription: String? { "富文本快照不可用或已过期。" }
    }
}

#if os(iOS)
typealias RichEditorRepresentable = UIViewRepresentable
#else
typealias RichEditorRepresentable = NSViewRepresentable
#endif

struct RichMarkdownEditor: RichEditorRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    private static func makePalette(for colorScheme: ColorScheme) -> [String: Any] {
        let colors: [String: Color] = ["accent": InkTheme.accent, "background": InkTheme.documentBackground,
            "text": .primary, "muted": .secondary, "line": .secondary.opacity(0.18), "panel": InkTheme.background, "inline-code": .secondary.opacity(0.12)]
        var result: [String: Any] = colors.mapValues { color in
            #if os(iOS)
            let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            #else
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                NSColor(color).usingColorSpace(.deviceRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            }
            #endif
            return "rgba(\(red * 255), \(green * 255), \(blue * 255), \(alpha))"
        }
        result["dark"] = (colorScheme == .dark)
        return result
    }
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var composing: Bool
    let active: Bool
    let documentID: UUID
    let textRevision: Int
    let imageContext: ImageResourceContext
    let fontSize: Double
    let lineSpacing: Double
    let titles: [String]
    let titlesRevision: Int
    let bridge: RichEditorBridge
    let loadAttachment: @Sendable (String) async throws -> Data
    let pasteImage: (Data, String) async -> String?
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    #if os(iOS)
    func makeUIView(context: Context) -> RichEditorContainerView {
        let webView = makeWebView(context.coordinator)
        let container = RichEditorContainerView(webView: webView) { [weak coordinator = context.coordinator] title in
            coordinator?.runCommand(title)
        }
        context.coordinator.container = container
        return container
    }
    func updateUIView(_ view: RichEditorContainerView, context: Context) {
        update(view.webView, coordinator: context.coordinator, enabled: context.environment.isEnabled)
        view.setToolbarVisible(active && focused && context.environment.isEnabled)
    }
    static func dismantleUIView(_ view: RichEditorContainerView, coordinator: Coordinator) {
        coordinator.dismantle(view.webView)
    }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator, enabled: context.environment.isEnabled) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.dismantle(view) }
    #endif

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "richEditor")
        configuration.setURLSchemeHandler(coordinator.attachments, forURLScheme: "inkstone-attachment")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.keyboardDismissMode = .interactive
        #endif
        coordinator.view = view
        bridge.webView = view
        bridge.receive = { [weak coordinator] in coordinator?.accept($0) ?? false }
        if let page = RichEditorResources.pageURL {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else { DispatchQueue.main.async { onError("富文本编辑资源缺失，请切换到源码编辑。") } }
        return view
    }
    private func update(_ view: WKWebView, coordinator: Coordinator, enabled: Bool) {
        coordinator.parent = self
        let loader = self.loadAttachment
        coordinator.attachments.loader = { source in try await loader(source) }
        coordinator.attachments.context = imageContext
        coordinator.enabled = enabled
        coordinator.synchronize()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: RichMarkdownEditor
        weak var view: WKWebView?
        #if os(iOS)
        weak var container: RichEditorContainerView?
        #endif
        let attachments: RichAttachmentHandler
        var ready = false
        var enabled = true
        var lastSource: String?
        var lastTextRevision = -1
        var lastID: UUID?
        var lastImageContext: String?
        var revision = -1
        var lastActive: Bool?
        var lastFocus: Bool?
        var lastEnabled: Bool?
        var appearance: [Double] = []
        var lastColorScheme: ColorScheme?
        var lastTitlesRevision = -1
        var pasteTask: Task<Void, Never>?
        init(_ parent: RichMarkdownEditor) {
            self.parent = parent
            attachments = RichAttachmentHandler(loader: parent.loadAttachment, context: parent.imageContext)
        }
        func call(_ function: String, _ arguments: [Any] = []) {
            guard let view else { return }
            Task { @MainActor [weak self, weak view] in
                do {
                    _ = try await view?.callAsyncJavaScript(
                        "window.inkstone?.[fn]?.(...args)",
                        arguments: ["fn": function, "args": arguments],
                        in: nil,
                        contentWorld: .page
                    )
                } catch {
                    self?.parent.onError("富文本编辑出错：" + error.localizedDescription)
                }
            }
        }
        func runCommand(_ title: String) {
            call("command", [title])
        }
        func synchronize() {
            guard ready else { return }
            var updates: [[Any]] = []
            func enqueue(_ name: String, _ arguments: [Any] = []) { updates.append([name, arguments]) }
            if parent.active && lastID != parent.documentID {
                lastID = parent.documentID; revision = -1; lastSource = parent.text; lastTextRevision = parent.textRevision
                lastFocus = nil; lastEnabled = nil
                lastImageContext = parent.imageContext.token
                enqueue("load", [parent.text, parent.documentID.uuidString, parent.bridge.session.editingVersion, parent.imageContext.token])
            } else if parent.active && lastTextRevision != parent.textRevision {
                lastTextRevision = parent.textRevision
                if lastSource != parent.text {
                    lastSource = parent.text; lastEnabled = nil
                    enqueue("setSource", [parent.text, parent.documentID.uuidString])
                }
            }
            if lastImageContext != parent.imageContext.token {
                lastImageContext = parent.imageContext.token
                enqueue("setImageContext", [parent.imageContext.token])
            }
            if lastActive != parent.active {
                lastActive = parent.active
                if parent.active { enqueue("releaseSnapshot") }
            }
            let editable = enabled && parent.active
            if lastEnabled != editable {
                lastEnabled = editable; enqueue("setEnabled", [editable])
            }
            if lastColorScheme != parent.colorScheme {
                lastColorScheme = parent.colorScheme
                enqueue("setPalette", [RichMarkdownEditor.makePalette(for: parent.colorScheme)])
            }
            if appearance != [parent.fontSize, parent.lineSpacing] {
                appearance = [parent.fontSize, parent.lineSpacing]; enqueue("setAppearance", appearance)
            }
            if parent.active && lastTitlesRevision != parent.titlesRevision {
                lastTitlesRevision = parent.titlesRevision; enqueue("setTitles", [parent.titles])
            }
            let focused = parent.active && parent.focused
            if lastFocus != focused {
                lastFocus = focused; enqueue("focus", [focused])
            }
            if !updates.isEmpty { call("applyUpdates", [updates]) }
        }
        @discardableResult func accept(_ body: [String: Any]) -> Bool {
            guard body["session"] as? String == parent.documentID.uuidString,
                  parent.documentID == parent.bridge.session.documentID,
                  let text = body["text"] as? String, let version = body["revision"] as? Int,
                  let composing = body["composing"] as? Bool, version >= revision,
                  parent.bridge.session.acceptSnapshot(version: version, composing: composing) else { return false }
            revision = version; lastSource = text
            if parent.text != text { parent.text = text }
            return true
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" { ready = true; synchronize(); return }
            guard body["session"] as? String == parent.documentID.uuidString,
                  parent.documentID == parent.bridge.session.documentID else { return }
            if type == "image" && !parent.active {
                call("insertImage", [NSNull()])
                return
            }
            guard parent.active else { return }
            switch type {
            case "change":
                guard let version = body["revision"] as? Int, let composing = body["composing"] as? Bool else { return }
                parent.bridge.notifyChanged(version: version, composing: composing)
            case "composition": parent.composing = body["composing"] as? Bool ?? false
            case "focus":
                let focused = body["focused"] as? Bool ?? false
                lastFocus = focused; parent.focused = focused
                #if os(iOS)
                container?.setToolbarVisible(parent.active && focused && enabled)
                #endif
            case "toolbar":
                #if os(iOS)
                let enabledMap = body["enabled"] as? [String: Bool] ?? [:]
                let activeMap = body["active"] as? [String: Bool] ?? [:]
                container?.updateToolbarState(enabled: enabledMap, active: activeMap)
                #endif
            case "error": parent.onError("无法打开富文本编辑，请切换到源码模式。" + (body["message"] as? String ?? ""))
            case "image":
                guard let encoded = body["data"] as? String, let comma = encoded.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])), data.count <= 32 * 1024 * 1024 else { call("insertImage", [NSNull()]); return }
                let mime = body["mime"] as? String ?? "image/png"
                let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "png"
                let token = parent.documentID
                pasteTask?.cancel()
                pasteTask = Task { [weak self] in
                    guard let self else { return }
                    let path = await parent.pasteImage(data, ext)
                    guard !Task.isCancelled, token == parent.documentID else { return }
                    call("insertImage", [path as Any? ?? NSNull()])
                }
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the bundled editor can be a document. Note links never navigate this WebView.
            decisionHandler(navigationAction.request.url == RichEditorResources.pageURL ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard parent.documentID == parent.bridge.session.documentID else { return }
            ready = false; lastID = nil; lastTextRevision = -1; lastActive = nil; appearance = []; lastColorScheme = nil; lastTitlesRevision = -1
            parent.composing = false
            parent.bridge.session.snapshotFailure = "富文本编辑进程中断，无法确认最新修改。可以保留最近取得的快照并转到源码编辑。"
            parent.onError(parent.bridge.session.snapshotFailure!)
            if let page = RichEditorResources.pageURL { webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        }
        func dismantle(_ view: WKWebView) {
            pasteTask?.cancel()
            pasteTask = nil
            view.stopLoading()
            view.navigationDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: "richEditor")
            attachments.cancelAll()
            if parent.bridge.webView === view { parent.bridge.webView = nil; parent.bridge.receive = nil }
        }
    }
}

#if os(iOS)
/// Native horizontal scrolling keyboard toolbar docked cleanly above the iOS keyboard
/// via `keyboardLayoutGuide` without swizzling private WKWebView internals.
@MainActor final class RichEditorContainerView: UIView {
    struct ToolbarAction {
        let command: String
        let title: String?
        let symbol: String?
        let accessibilityLabel: String
        let contextual: Bool
    }

    let webView: WKWebView
    private let onCommand: (String) -> Void
    private let toolbarView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let separator = UIView()
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let dismissButton = UIButton(type: .system)
    private var toolbarHeightConstraint: NSLayoutConstraint!
    private var buttons: [String: UIButton] = [:]
    private var contextualCommands: Set<String> = []
    private var toolbarVisible = false

    private static let actions: [ToolbarAction] = [
        ToolbarAction(command: "撤销", title: nil, symbol: "arrow.uturn.backward", accessibilityLabel: "撤销", contextual: false),
        ToolbarAction(command: "重做", title: nil, symbol: "arrow.uturn.forward", accessibilityLabel: "重做", contextual: false),
        ToolbarAction(command: "1 级标题", title: "H1", symbol: nil, accessibilityLabel: "1 级标题", contextual: false),
        ToolbarAction(command: "2 级标题", title: "H2", symbol: nil, accessibilityLabel: "2 级标题", contextual: false),
        ToolbarAction(command: "3 级标题", title: "H3", symbol: nil, accessibilityLabel: "3 级标题", contextual: false),
        ToolbarAction(command: "正文", title: "正文", symbol: nil, accessibilityLabel: "正文", contextual: false),
        ToolbarAction(command: "加粗", title: nil, symbol: "bold", accessibilityLabel: "加粗", contextual: false),
        ToolbarAction(command: "斜体", title: nil, symbol: "italic", accessibilityLabel: "斜体", contextual: false),
        ToolbarAction(command: "删除线", title: nil, symbol: "strikethrough", accessibilityLabel: "删除线", contextual: false),
        ToolbarAction(command: "行内代码", title: nil, symbol: "chevron.left.forwardslash.chevron.right", accessibilityLabel: "行内代码", contextual: false),
        ToolbarAction(command: "无序列表", title: nil, symbol: "list.bullet", accessibilityLabel: "无序列表", contextual: false),
        ToolbarAction(command: "有序列表", title: nil, symbol: "list.number", accessibilityLabel: "有序列表", contextual: false),
        ToolbarAction(command: "待办列表", title: nil, symbol: "checklist", accessibilityLabel: "待办列表", contextual: false),
        ToolbarAction(command: "增加列表缩进", title: nil, symbol: "increase.indent", accessibilityLabel: "增加列表缩进", contextual: true),
        ToolbarAction(command: "减少列表缩进", title: nil, symbol: "decrease.indent", accessibilityLabel: "减少列表缩进", contextual: true),
        ToolbarAction(command: "引用", title: nil, symbol: "text.quote", accessibilityLabel: "引用", contextual: false),
        ToolbarAction(command: "代码块", title: nil, symbol: "curlybraces.square", accessibilityLabel: "代码块", contextual: false),
        ToolbarAction(command: "插入或修改链接", title: nil, symbol: "link", accessibilityLabel: "插入或修改链接", contextual: false),
        ToolbarAction(command: "取消链接", title: "取消链", symbol: nil, accessibilityLabel: "取消链接", contextual: true),
        ToolbarAction(command: "插入表格", title: nil, symbol: "tablecells", accessibilityLabel: "插入表格", contextual: false),
        ToolbarAction(command: "表格添加行", title: "+行", symbol: nil, accessibilityLabel: "表格添加行", contextual: true),
        ToolbarAction(command: "表格添加列", title: "+列", symbol: nil, accessibilityLabel: "表格添加列", contextual: true),
        ToolbarAction(command: "表格删除行", title: "删行", symbol: nil, accessibilityLabel: "表格删除行", contextual: true),
        ToolbarAction(command: "表格删除列", title: "删列", symbol: nil, accessibilityLabel: "表格删除列", contextual: true),
        ToolbarAction(command: "删除表格", title: "删表", symbol: nil, accessibilityLabel: "删除表格", contextual: true)
    ]

    init(webView: WKWebView, onCommand: @escaping (String) -> Void) {
        self.webView = webView
        self.onCommand = onCommand
        super.init(frame: .zero)
        keyboardLayoutGuide.followsUndockedKeyboard = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(webView)
        addSubview(toolbarView)

        separator.backgroundColor = .separator
        toolbarView.contentView.addSubview(separator)
        toolbarView.contentView.addSubview(scrollView)
        toolbarView.contentView.addSubview(dismissButton)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        scrollView.addSubview(stackView)

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6

        for action in Self.actions {
            let button = makeToolbarButton(action)
            buttons[action.command] = button
            if action.contextual {
                contextualCommands.insert(action.command)
                button.isHidden = true
            }
            stackView.addArrangedSubview(button)
        }

        var dismissConfig = UIButton.Configuration.plain()
        dismissConfig.image = UIImage(systemName: "keyboard.chevron.compact.down")
        dismissConfig.baseForegroundColor = .label
        dismissConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        dismissButton.configuration = dismissConfig
        dismissButton.accessibilityLabel = "收起键盘"
        dismissButton.addAction(UIAction { [weak self] _ in
            self?.onCommand("收起键盘")
        }, for: .touchUpInside)

        toolbarHeightConstraint = toolbarView.heightAnchor.constraint(equalToConstant: 0)
        toolbarView.isHidden = true

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbarView.topAnchor),

            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            toolbarHeightConstraint,

            separator.topAnchor.constraint(equalTo: toolbarView.contentView.topAnchor),
            separator.leadingAnchor.constraint(equalTo: toolbarView.contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: toolbarView.contentView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / max(1, UIScreen.main.scale)),

            dismissButton.trailingAnchor.constraint(equalTo: toolbarView.contentView.trailingAnchor, constant: -4),
            dismissButton.centerYAnchor.constraint(equalTo: toolbarView.contentView.centerYAnchor),
            dismissButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            dismissButton.heightAnchor.constraint(equalToConstant: 36),

            scrollView.topAnchor.constraint(equalTo: toolbarView.contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: toolbarView.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -2),
            scrollView.bottomAnchor.constraint(equalTo: toolbarView.contentView.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private func makeToolbarButton(_ action: ToolbarAction) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        if let symbol = action.symbol {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        } else if let title = action.title {
            var attributed = AttributedString(title)
            attributed.font = .systemFont(ofSize: 13, weight: .semibold)
            config.attributedTitle = attributed
        }
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        config.cornerStyle = .medium
        button.configuration = config
        button.accessibilityLabel = action.accessibilityLabel
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.onCommand(action.command)
        }, for: .touchUpInside)
        return button
    }

    func setToolbarVisible(_ visible: Bool) {
        guard toolbarVisible != visible else { return }
        toolbarVisible = visible
        toolbarView.isHidden = !visible
        toolbarHeightConstraint.constant = visible ? 44 : 0
        UIView.animate(withDuration: 0.18) { self.layoutIfNeeded() }
    }

    func updateToolbarState(enabled: [String: Bool], active: [String: Bool]) {
        let accent = UIColor(InkTheme.accent)
        for (command, button) in buttons {
            let isEnabled = enabled[command] ?? true
            let isActive = active[command] ?? false
            button.isEnabled = isEnabled
            if contextualCommands.contains(command) {
                button.isHidden = !isEnabled
            }
            var config = button.configuration ?? .plain()
            config.baseForegroundColor = isActive ? accent : .label
            config.background.backgroundColor = isActive ? accent.withAlphaComponent(0.16) : .clear
            button.configuration = config
            if isActive {
                button.accessibilityTraits.insert(.selected)
            } else {
                button.accessibilityTraits.remove(.selected)
            }
        }
    }
}
#endif

/// Local images use the vault's existing coordinated, scoped attachment reader.
/// No filesystem URL or note-provided HTML is exposed to the web document.
@MainActor final class RichAttachmentHandler: NSObject, WKURLSchemeHandler {
    var loader: @Sendable (String) async throws -> Data
    var context: ImageResourceContext { didSet { if oldValue != context { cancelAll() } } }
    private var jobs: [ObjectIdentifier: (task: Task<Void, Never>, schemeTask: WKURLSchemeTask)] = [:]
    init(loader: @escaping @Sendable (String) async throws -> Data, context: ImageResourceContext) { self.loader = loader; self.context = context }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "source" })?.value else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "context" })?.value == context.token else {
            urlSchemeTask.didFailWithError(URLError(.cancelled)); return
        }
        let load = loader, context = context
        let task = Task { [weak self] in
            do {
                let preview = try await ImagePreviewPipeline.shared.preview(source: source, context: context, loader: load)
                try Task.checkCancellation()
                guard self?.jobs.removeValue(forKey: key) != nil else { return }
                let data = preview.data, mime = preview.mimeType
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch {
                guard self?.jobs.removeValue(forKey: key) != nil else { return }
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
        jobs[key] = (task, urlSchemeTask)
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        jobs.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.task.cancel()
    }
    func cancelAll() {
        let active = jobs
        jobs.removeAll()
        for entry in active.values {
            entry.task.cancel()
            entry.schemeTask.didFailWithError(URLError(.cancelled))
        }
    }
}
