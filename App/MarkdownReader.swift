import SwiftUI
import WebKit
import InkstoneCore

private struct AttachmentLoaderKey: EnvironmentKey {
    static let defaultValue: (@Sendable (String) async throws -> Data)? = nil
}
private struct ImageResourceContextKey: EnvironmentKey {
    static let defaultValue = ImageResourceContext(library: "unscoped", notePath: "", generation: "")
}
extension EnvironmentValues {
    var imageResourceContext: ImageResourceContext {
        get { self[ImageResourceContextKey.self] }
        set { self[ImageResourceContextKey.self] = newValue }
    }
    var attachmentLoader: (@Sendable (String) async throws -> Data)? {
        get { self[AttachmentLoaderKey.self] }
        set { self[AttachmentLoaderKey.self] = newValue }
    }
}


private struct MarkdownBodySizeKey: EnvironmentKey { static let defaultValue = 17.0 }
extension EnvironmentValues {
    var markdownBodySize: Double {
        get { self[MarkdownBodySizeKey.self] }
        set { self[MarkdownBodySizeKey.self] = newValue }
    }
}

/// Native rendering of the shared Markdown tree. Parsing never rewrites the source.
struct MarkdownReader: View {
    let blocks: [MarkdownBlock]
    var openLink: (String) -> Void
    var toggleTask: (Int) -> Void
    var openAttachment: (String) -> Void = { _ in }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: MarkdownAppearance.metric("block-spacing")) {
            ForEach(blocks) { block in MarkdownBlockView(block: block, toggleTask: toggleTask).id(block.line) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "inkstone", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value {
                    openLink(target); return .handled
                }
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .systemAction }
                if url.scheme == nil, !url.path.isEmpty, url.path.lowercased().hasSuffix(".md") {
                    openLink(url.path); return .handled
                }
                if url.scheme == nil { openAttachment(url.relativeString); return .handled }
                return .discarded
            })
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    var toggleTask: (Int) -> Void
    var spacing: CGFloat = MarkdownAppearance.metric("block-spacing")
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in MarkdownBlockView(block: block, toggleTask: toggleTask).id(block.line) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    @Environment(\.markdownBodySize) private var bodySize
    let block: MarkdownBlock
    var toggleTask: (Int) -> Void
    private var children: some View { MarkdownBlocks(blocks: block.children, toggleTask: toggleTask) }

    var body: some View {
        switch block.kind {
        case .paragraph:
            MarkdownInlineView(nodes: block.inline)
        case .heading(let level):
            MarkdownInlineView(nodes: block.inline)
                .font(headingFont(level)).fontWeight(.semibold)
                .padding(.top, MarkdownAppearance.metric("heading-top")).accessibilityAddTraits(.isHeader)
        case .quote:
            if let callout = block.callout {
                MarkdownCalloutView(callout: callout) { children }
            } else {
                HStack(alignment: .top, spacing: MarkdownAppearance.metric("block-spacing")) {
                    children.foregroundStyle(.secondary)
                }.padding(.leading, 14).padding(.vertical, 6)
                    .overlay(alignment: .leading) { Rectangle().fill(InkTheme.accent.opacity(0.55)).frame(width: 3) }
            }
        case .list:
            MarkdownBlocks(blocks: block.children, toggleTask: toggleTask, spacing: MarkdownAppearance.metric("list-spacing"))
        case .item(let marker, let checked):
            HStack(alignment: checked == nil ? .firstTextBaseline : .top, spacing: MarkdownAppearance.metric("task-gap")) {
                if let checked {
                    Button { toggleTask(block.line) } label: {
                        ZStack {
                            Circle().strokeBorder(InkTheme.accent, lineWidth: MarkdownAppearance.metric("task-marker-stroke"))
                            if checked {
                                Circle().fill(InkTheme.accent)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10 * bodySize / 17, weight: .semibold))
                                    .foregroundStyle(InkTheme.surface)
                            }
                        }
                            .frame(width: MarkdownAppearance.metric("task-marker-size") * bodySize / 17,
                                   height: MarkdownAppearance.metric("task-marker-size") * bodySize / 17)
                            .frame(width: MarkdownAppearance.metric("task-hit-size"), height: MarkdownAppearance.metric("task-hit-size"))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(InkTheme.accent)
                        .accessibilityLabel(checked ? "取消完成任务" : "完成任务")
                    children.strikethrough(checked)
                        .padding(.vertical, max(0, (MarkdownAppearance.metric("task-hit-size") - bodySize * 1.2) / 2))
                } else {
                    Text(marker).monospacedDigit().foregroundStyle(InkTheme.accent).frame(minWidth: 22, alignment: .trailing)
                    children
                }
            }
        case .code(let language):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let language, !language.isEmpty { Text(language).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("复制") {
                        #if os(iOS)
                        UIPasteboard.general.string = block.text
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(block.text, forType: .string)
                        #endif
                    }.font(.caption).buttonStyle(.borderless).accessibilityLabel("复制代码")
                }
                MarkdownWebFragment(kind: "code", source: block.text, language: language ?? "",
                                    fontSize: MarkdownAppearance.metric("code-size") * bodySize / 17)
            }.padding(MarkdownAppearance.metric("code-padding")).background(InkTheme.background, in: RoundedRectangle(cornerRadius: MarkdownAppearance.metric("code-radius")))
        case .table:
            ScrollView(.horizontal) {
                MarkdownTableLayout(columnCount: block.children.map { $0.children.count }.max() ?? 0,
                                    fontScale: bodySize / 17) {
                    ForEach(Array(block.children.enumerated()), id: \.element.id) { index, row in
                        ForEach(row.children) { cell in
                            MarkdownInlineView(nodes: cell.inline)
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .multilineTextAlignment(cellTextAlignment(cell))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity,
                                       alignment: cellAlignment(cell))
                                .background(index == 0 ? InkTheme.accent.opacity(0.12) : Color.secondary.opacity(index.isMultiple(of: 2) ? 0.06 : 0.02))
                                .overlay { Rectangle().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5) }
                        }
                        // Keep column positions stable for incomplete rows.
                        ForEach(row.children.count..<(block.children.map { $0.children.count }.max() ?? 0), id: \.self) { _ in
                            Color.clear
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        case .divider: Divider().padding(.vertical, 6)
        case .html: Text(block.text).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        case .row, .cell: children
        }
    }
    private func headingFont(_ level: Int) -> Font {
        .system(size: MarkdownAppearance.metric("h\(min(6, max(1, level)))") * bodySize / 17)
    }
    private func cellAlignment(_ cell: MarkdownBlock) -> Alignment {
        guard case .cell(let alignment) = cell.kind else { return .leading }
        switch alignment { case "center": return .top; case "right": return .topTrailing; default: return .topLeading }
    }
    private func cellTextAlignment(_ cell: MarkdownBlock) -> TextAlignment {
        guard case .cell(let alignment) = cell.kind else { return .leading }
        switch alignment { case "center": return .center; case "right": return .trailing; default: return .leading }
    }
}

/// Measure wrapped content at its final column width before assigning row heights.
/// Horizontal scrolling keeps long tables from compressing into the reader's viewport.
private struct MarkdownTableLayout: Layout {
    let columnCount: Int
    let fontScale: CGFloat

    private struct Metrics {
        var widths: [CGFloat]
        var heights: [CGFloat]
        var size: CGSize {
            CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
        }
    }

    private func metrics(for subviews: Subviews) -> Metrics {
        guard columnCount > 0, !subviews.isEmpty else { return Metrics(widths: [], heights: []) }
        let minimumWidth = 110 * fontScale
        let maximumWidth = 300 * fontScale
        var widths = Array(repeating: minimumWidth, count: columnCount)
        for (index, cell) in subviews.enumerated() {
            let idealWidth = cell.sizeThatFits(.unspecified).width
            widths[index % columnCount] = max(widths[index % columnCount], min(maximumWidth, idealWidth))
        }
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columnCount - 1) / columnCount)
        for (index, cell) in subviews.enumerated() {
            let proposal = ProposedViewSize(width: widths[index % columnCount], height: nil)
            heights[index / columnCount] = max(heights[index / columnCount], cell.sizeThatFits(proposal).height)
        }
        return Metrics(widths: widths, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        metrics(for: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = metrics(for: subviews)
        guard !metrics.widths.isEmpty else { return }
        var x = bounds.minX
        var y = bounds.minY
        for (index, cell) in subviews.enumerated() {
            let column = index % columnCount
            let row = index / columnCount
            cell.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: metrics.widths[column], height: metrics.heights[row]))
            x += metrics.widths[column]
            if column == columnCount - 1 {
                x = bounds.minX
                y += metrics.heights[row]
            }
        }
    }
}

private struct MarkdownInlineView: View {
    @Environment(\.markdownBodySize) private var bodySize
    let nodes: [MarkdownInline]
    // Keep text in one attributed run; separate images to preserve native resizing and alt text.
    private var segments: [[MarkdownInline]] {
        var result: [[MarkdownInline]] = [], pending: [MarkdownInline] = []
        for node in nodes {
            if case .image = node {
                if !pending.isEmpty { result.append(pending); pending = [] }
                result.append([node])
            } else { pending.append(node) }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.count == 1, case .image(let source, let alt) = segment[0] {
                    MarkdownImage(source: source, alt: alt)
                } else if segment.contains(where: \.containsMath) {
                    MarkdownWebFragment(kind: "inline", source: segment.map(\.renderHTML).joined(), fontSize: bodySize)
                } else { Text(attributed(segment)) }
            }
        }
    }
    private func applying(_ intent: InlinePresentationIntent, to value: AttributedString) -> AttributedString {
        var result = value
        for run in value.runs {
            result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
        }
        return result
    }
    private func attributed(_ nodes: [MarkdownInline]) -> AttributedString {
        nodes.reduce(into: AttributedString()) { result, node in
            var part: AttributedString
            switch node {
            case .text(let text): part = AttributedString(text)
            case .code(let text):
                part = AttributedString(text); part.font = .system(size: bodySize, design: .monospaced)
                part.backgroundColor = .secondary.opacity(0.12)
            case .emphasis(let children): part = applying(.emphasized, to: attributed(children))
            case .strong(let children): part = applying(.stronglyEmphasized, to: attributed(children))
            case .strike(let children): part = attributed(children); part.strikethroughStyle = .single
            case .link(let destination, let children): part = attributed(children); part.link = URL(string: destination)
            case .wiki(let target, let label):
                part = AttributedString(label)
                var url = URLComponents(); url.scheme = "inkstone"; url.host = "note"
                url.queryItems = [URLQueryItem(name: "target", value: target)]; part.link = url.url
            case .image(_, let alt): part = AttributedString(alt)
            case .math(let source, _): part = AttributedString(source)
            }
            result.append(part)
        }
    }
}

private struct MarkdownImage: View {
    @Environment(\.attachmentLoader) private var loader
    @Environment(\.imageResourceContext) private var context
    let source: String
    let alt: String
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: CGImage?
    @State private var failed = false
    private struct Request: Equatable { let source: String; let scale: CGFloat; let context: ImageResourceContext }
    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: displayScale).resizable().scaledToFit()
                    .accessibilityLabel(alt.isEmpty ? "图片" : alt)
            } else { placeholder }
        }.frame(maxWidth: ObsidianImageReference(source: source)?.width.map(CGFloat.init) ?? MarkdownAppearance.metric("image-width"))
        .frame(maxHeight: ObsidianImageReference(source: source)?.height.map(CGFloat.init))
        .task(id: Request(source: source, scale: displayScale, context: context)) {
            thumbnail = nil; failed = false
            do {
                let load = loader
                let preview = try await ImagePreviewPipeline.shared.preview(source: source, context: context, maxPixelSize: Int(MarkdownAppearance.metric("image-width") * displayScale)) { source in
                    guard let load else { throw VaultError.invalidPath }
                    return try await load(source)
                }
                try Task.checkCancellation()
                thumbnail = preview.image
            } catch is CancellationError {} catch { failed = true }
        }
    }
    private var placeholder: some View {
        Group {
            if failed { Label(alt.isEmpty ? "图片不可用：" + source : alt, systemImage: "photo").foregroundStyle(.secondary) }
            else { ProgressView("加载图片") }
        }
    }
}

private struct MarkdownCalloutView<Content: View>: View {
    let callout: MarkdownCallout
    @ViewBuilder var content: () -> Content
    @State private var expanded: Bool?
    private var isExpanded: Bool { expanded ?? callout.expanded ?? true }
    private var color: Color {
        switch callout.type {
        case "warning", "caution", "attention", "question", "help", "faq": return .orange
        case "danger", "error", "bug", "failure", "fail", "missing": return .red
        case "success", "check", "done", "tip", "hint", "important": return .green
        case "quote", "cite": return .secondary
        default: return .blue
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if callout.expanded != nil {
                Button { expanded = !isExpanded } label: {
                    HStack { Image(systemName: isExpanded ? "chevron.down" : "chevron.right"); Text(callout.title); Spacer() }
                }.buttonStyle(.plain).foregroundStyle(color).fontWeight(.semibold)
                    .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            } else { Text(callout.title).fontWeight(.semibold).foregroundStyle(color) }
            if isExpanded { content() }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4) }
    }
}

private extension String {
    var markdownEscapedHTML: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
private extension MarkdownInline {
    var containsMath: Bool {
        switch self {
        case .math: return true
        case .strong(let nodes), .emphasis(let nodes), .strike(let nodes), .link(_, let nodes): return nodes.contains(where: \.containsMath)
        default: return false
        }
    }
    var renderHTML: String {
        switch self {
        case .text(let text): return text.markdownEscapedHTML.replacingOccurrences(of: "\n", with: "<br>")
        case .code(let text): return "<code>" + text.markdownEscapedHTML + "</code>"
        case .strong(let nodes): return "<strong>" + nodes.map(\.renderHTML).joined() + "</strong>"
        case .emphasis(let nodes): return "<em>" + nodes.map(\.renderHTML).joined() + "</em>"
        case .strike(let nodes): return "<s>" + nodes.map(\.renderHTML).joined() + "</s>"
        case .link(let target, let nodes): return "<a href=\"" + target.markdownEscapedHTML + "\">" + nodes.map(\.renderHTML).joined() + "</a>"
        case .wiki(let target, let label):
            var url = URLComponents(); url.scheme = "inkstone"; url.host = "note"
            url.queryItems = [URLQueryItem(name: "target", value: target)]
            return "<a href=\"" + (url.string ?? "").markdownEscapedHTML + "\">" + label.markdownEscapedHTML + "</a>"
        case .image(_, let alt): return alt.markdownEscapedHTML
        case .math(let source, let display):
            return "<span class=\"" + (display ? "display-math" : "inline-math") + "\" data-display=\"" + String(display) + "\" data-tex=\"" + source.markdownEscapedHTML + "\"></span>"
        }
    }
}

/// Small offline WebKit fragments keep tasks, links, images and outline navigation native.
private struct MarkdownWebFragment: View {
    let kind: String
    let source: String
    var language = ""
    var fontSize: Double
    @State private var height: CGFloat = 28
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    var body: some View {
        MarkdownFragmentWebView(kind: kind, source: source, language: language, fontSize: fontSize,
                                dark: colorScheme == .dark, height: $height, openLink: { openURL($0) })
            .frame(height: height)
    }
}

private struct MarkdownFragmentWebView: RichEditorRepresentable {
    let kind: String
    let source: String
    let language: String
    let fontSize: Double
    let dark: Bool
    @Binding var height: CGFloat
    var openLink: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "renderHeight")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        #if os(iOS)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        #else
        view.setValue(false, forKey: "drawsBackground")
        #endif
        if let url = RichEditorResources.readerURL { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        return view
    }
    private func update(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(view)
    }
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context: context) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName: "renderHeight") }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context: context) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName: "renderHeight") }
    #endif
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownFragmentWebView
        var ready = false
        var previous: Data?
        var revision = 0
        init(_ parent: MarkdownFragmentWebView) { self.parent = parent }
        func render(_ view: WKWebView) {
            guard ready else { return }
            var payload: [String: Any] = ["kind": parent.kind, "source": parent.source, "html": parent.source,
                                           "language": parent.language, "fontSize": parent.fontSize, "dark": parent.dark]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), data != previous else { return }
            previous = data; revision += 1; payload["revision"] = revision
            Task { @MainActor [weak view] in
                _ = try? await view?.callAsyncJavaScript("await window.renderFragment(payload)", arguments: ["payload": payload], in: nil, contentWorld: .page)
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let version = body["revision"] as? Int, version == revision else { return }
            if let href = body["href"] as? String, let url = URL(string: href) { parent.openLink(url); return }
            guard let value = body["height"] as? Double, value.isFinite, value > 0 else { return }
            let height = CGFloat(min(100_000, max(24, value)))
            if abs(parent.height - height) > 0.5 { parent.height = height }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.scheme == "file", let base = RichEditorResources.readerURL?.deletingLastPathComponent().path,
                   url.path.hasPrefix(base + "/") {
                    let relative = String(url.path.dropFirst(base.count + 1))
                    if let link = URL(string: relative) { parent.openLink(link) }
                } else { parent.openLink(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(action.request.url == RichEditorResources.readerURL ? .allow : .cancel) }
        }
    }
}
