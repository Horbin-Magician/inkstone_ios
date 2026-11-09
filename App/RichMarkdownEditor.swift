import SwiftUI
import WebKit
import UniformTypeIdentifiers
import InkstoneCore

/// Flush the WebKit editing transaction before saving or replacing an editor.
@MainActor final class RichEditorBridge: ObservableObject {
    weak var webView: WKWebView?
    @Published var session = EditorSession()
    var receive: (([String: Any]) -> Bool)?
    private var pendingFlush: (documentID: UUID, token: UUID, frozen: Bool, task: Task<Bool, Never>)?

    func beginTransition() -> Bool {
        guard !session.transitioning, !session.composing else { return false }
        session.transitioning = true
        return true
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
    private var palette: [String: String] {
        let colors: [String: Color] = ["accent": InkTheme.accent, "background": InkTheme.documentBackground,
            "text": .primary, "muted": .secondary, "line": .secondary.opacity(0.18), "panel": InkTheme.background, "inline-code": .secondary.opacity(0.12)]
        return colors.mapValues { color in
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
    }
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var composing: Bool
    let active: Bool
    let documentID: UUID
    let imageContext: ImageResourceContext
    let fontSize: Double
    let lineSpacing: Double
    let titles: [String]
    let bridge: RichEditorBridge
    let loadAttachment: @Sendable (String) async throws -> Data
    let pasteImage: (Data, String) async -> String?
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, coordinator: context.coordinator, enabled: context.environment.isEnabled) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.dismantle(view) }
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
        let attachments: RichAttachmentHandler
        var ready = false
        var enabled = true
        var lastSource: String?
        var lastID: UUID?
        var lastImageContext: String?
        var revision = -1
        var lastActive: Bool?
        var lastFocus: Bool?
        var lastEnabled: Bool?
        var appearance: [Double] = []
        var lastPalette: [String: String] = [:]
        var lastTitles: [String] = []
        init(_ parent: RichMarkdownEditor) {
            self.parent = parent
            attachments = RichAttachmentHandler(loader: parent.loadAttachment, context: parent.imageContext)
        }
        func call(_ function: String, _ arguments: [Any] = []) {
            guard let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else { return }
            view?.evaluateJavaScript("window.inkstone.\(function)(...\(json))", completionHandler: { [weak self] _, error in
                if let error { self?.parent.onError("富文本编辑出错：" + error.localizedDescription) }
            })
        }
        func synchronize() {
            guard ready else { return }
            var updates: [[Any]] = []
            func enqueue(_ name: String, _ arguments: [Any] = []) { updates.append([name, arguments]) }
            if parent.active && lastID != parent.documentID {
                lastID = parent.documentID; revision = -1; lastSource = parent.text; lastFocus = nil; lastEnabled = nil
                lastImageContext = parent.imageContext.token
                enqueue("load", [parent.text, parent.documentID.uuidString, parent.bridge.session.editingVersion, parent.imageContext.token])
            } else if parent.active && lastSource != parent.text {
                lastSource = parent.text; lastEnabled = nil
                enqueue("setSource", [parent.text, parent.documentID.uuidString])
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
            if lastPalette != parent.palette {
                lastPalette = parent.palette; enqueue("setPalette", [lastPalette])
            }
            if appearance != [parent.fontSize, parent.lineSpacing] {
                appearance = [parent.fontSize, parent.lineSpacing]; enqueue("setAppearance", appearance)
            }
            if parent.active && lastTitles != parent.titles { lastTitles = parent.titles; enqueue("setTitles", [lastTitles]) }
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
            guard parent.active else { return }
            switch type {
            case "change":
                guard let version = body["revision"] as? Int, let composing = body["composing"] as? Bool else { return }
                parent.bridge.session.changed(version: version, composing: composing)
            case "composition": parent.composing = body["composing"] as? Bool ?? false
            case "focus":
                let focused = body["focused"] as? Bool ?? false
                lastFocus = focused; parent.focused = focused
            case "error": parent.onError("无法打开富文本编辑，请切换到源码模式。" + (body["message"] as? String ?? ""))
            case "image":
                guard let encoded = body["data"] as? String, let comma = encoded.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])), data.count <= 32 * 1024 * 1024 else { call("insertImage", [NSNull()]); return }
                let mime = body["mime"] as? String ?? "image/png"
                let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "png"
                let token = parent.documentID
                Task { [weak self] in
                    guard let self else { return }
                    let path = await parent.pasteImage(data, ext)
                    guard token == parent.documentID else { return }
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
            ready = false; lastID = nil; lastActive = nil; appearance = []; lastTitles = []
            parent.composing = false
            parent.bridge.session.snapshotFailure = "富文本编辑进程中断，无法确认最新修改。可以保留最近取得的快照并转到源码编辑。"
            parent.onError(parent.bridge.session.snapshotFailure!)
            if let page = RichEditorResources.pageURL { webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        }
        func dismantle(_ view: WKWebView) {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "richEditor")
            attachments.cancelAll()
            if parent.bridge.webView === view { parent.bridge.webView = nil; parent.bridge.receive = nil }
        }
    }
}

/// Local images use the vault's existing coordinated, scoped attachment reader.
/// No filesystem URL or note-provided HTML is exposed to the web document.
@MainActor final class RichAttachmentHandler: NSObject, WKURLSchemeHandler {
    var loader: @Sendable (String) async throws -> Data
    var context: ImageResourceContext { didSet { if oldValue != context { cancelAll() } } }
    private var jobs: [ObjectIdentifier: Task<Void, Never>] = [:]
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
        jobs[key] = Task { [weak self] in
            defer { self?.jobs[key] = nil }
            do {
                let preview = try await ImagePreviewPipeline.shared.preview(source: source, context: context, loader: load)
                try Task.checkCancellation()
                let data = preview.data, mime = preview.mimeType
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        jobs.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    func cancelAll() { for job in jobs.values { job.cancel() }; jobs.removeAll() }
}
