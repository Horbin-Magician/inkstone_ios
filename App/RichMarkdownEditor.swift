import SwiftUI
import WebKit
import UniformTypeIdentifiers
import InkstoneCore

/// Flush the WebKit editing transaction before saving or replacing an editor.
@MainActor final class RichEditorBridge: ObservableObject {
    weak var webView: WKWebView?
    var receive: (([String: Any]) -> Void)?

    func flush() async {
        guard let webView,
              let result = try? await webView.evaluateJavaScript("window.inkstone?.flush()"),
              let snapshot = result as? [String: Any] else { return }
        receive?(snapshot)
    }
}

#if os(iOS)
typealias RichEditorRepresentable = UIViewRepresentable
#else
typealias RichEditorRepresentable = NSViewRepresentable
#endif

struct RichMarkdownEditor: RichEditorRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var composing: Bool
    let documentID: UUID
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
        bridge.receive = { [weak coordinator] in coordinator?.accept($0) }
        if let page = RichEditorResources.pageURL {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else { DispatchQueue.main.async { onError("富文本编辑资源缺失，请切换到源码编辑。") } }
        return view
    }
    private func update(_ view: WKWebView, coordinator: Coordinator, enabled: Bool) {
        coordinator.parent = self
        let loader = self.loadAttachment
        coordinator.attachments.loader = { source in try await loader(source) }
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
        var revision = -1
        var lastFocus: Bool?
        var appearance: [Double] = []
        var lastTitles: [String] = []
        init(_ parent: RichMarkdownEditor) {
            self.parent = parent
            attachments = RichAttachmentHandler(loader: parent.loadAttachment)
        }
        func call(_ function: String, _ arguments: [Any] = []) {
            guard let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else { return }
            view?.evaluateJavaScript("window.inkstone.\(function)(...\(json))", completionHandler: { [weak self] _, error in
                if let error { self?.parent.onError("富文本编辑出错：" + error.localizedDescription) }
            })
        }
        func synchronize() {
            guard ready else { return }
            if lastID != parent.documentID {
                lastID = parent.documentID; revision = -1; lastSource = parent.text; lastFocus = nil
                call("load", [parent.text, parent.documentID.uuidString])
            } else if lastSource != parent.text {
                lastSource = parent.text
                call("setSource", [parent.text, parent.documentID.uuidString])
            }
            call("setEnabled", [enabled])
            if appearance != [parent.fontSize, parent.lineSpacing] {
                appearance = [parent.fontSize, parent.lineSpacing]; call("setAppearance", appearance)
            }
            if lastTitles != parent.titles { lastTitles = parent.titles; call("setTitles", [lastTitles]) }
            if lastFocus != parent.focused {
                lastFocus = parent.focused; call("focus", [parent.focused])
            }
        }
        func accept(_ body: [String: Any]) {
            guard body["session"] as? String == parent.documentID.uuidString,
                  let text = body["text"] as? String, let version = body["revision"] as? Int, version >= revision else { return }
            revision = version; lastSource = text
            // Keep the existing save barrier active for marked Chinese/Japanese text.
            parent.composing = body["composing"] as? Bool ?? false
            if parent.text != text { parent.text = text }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" { ready = true; synchronize(); return }
            guard body["session"] as? String == parent.documentID.uuidString else { return }
            switch type {
            case "change": accept(body)
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
            ready = false; lastID = nil; appearance = []; lastTitles = []
            parent.composing = false
            parent.onError("富文本编辑进程已重启，正在恢复最近同步的正文。")
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
    private var jobs: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(loader: @escaping @Sendable (String) async throws -> Data) { self.loader = loader }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "source" })?.value else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        let load = loader
        jobs[key] = Task { [weak self] in
            defer { self?.jobs[key] = nil }
            do {
                let original = try await load(source)
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else { return nil as Data? }
                    return AttachmentThumbnail.webPreview(data: original)
                }
                let preview = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                let data = preview ?? original
                let ext = (URLComponents(string: source)?.path as NSString?)?.pathExtension ?? ""
                let mime = preview != nil ? "image/png" : (UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
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
