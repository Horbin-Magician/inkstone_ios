import SwiftUI
import InkstoneCore

private struct AttachmentLoaderKey: EnvironmentKey {
    static let defaultValue: (@Sendable (String) async throws -> Data)? = nil
}
extension EnvironmentValues {
    var attachmentLoader: (@Sendable (String) async throws -> Data)? {
        get { self[AttachmentLoaderKey.self] }
        set { self[AttachmentLoaderKey.self] = newValue }
    }
}

/// Native rendering of the shared Markdown tree. Parsing never rewrites the source.
struct MarkdownReader: View {
    let blocks: [MarkdownBlock]
    var openLink: (String) -> Void
    var toggleTask: (Int) -> Void
    var openAttachment: (String) -> Void = { _ in }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
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
    var spacing: CGFloat = 12
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in MarkdownBlockView(block: block, toggleTask: toggleTask).id(block.line) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var toggleTask: (Int) -> Void
    private var children: some View { MarkdownBlocks(blocks: block.children, toggleTask: toggleTask) }

    var body: some View {
        switch block.kind {
        case .paragraph:
            MarkdownInlineView(nodes: block.inline).lineSpacing(5)
        case .heading(let level):
            MarkdownInlineView(nodes: block.inline)
                .font(headingFont(level)).fontWeight(.semibold)
                .padding(.top, 8).accessibilityAddTraits(.isHeader)
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                children.foregroundStyle(.secondary)
            }.padding(.leading, 14).padding(.vertical, 6)
                .overlay(alignment: .leading) { Rectangle().fill(InkTheme.accent.opacity(0.55)).frame(width: 3) }
        case .list:
            MarkdownBlocks(blocks: block.children, toggleTask: toggleTask, spacing: 7)
        case .item(let marker, let checked):
            HStack(alignment: .top, spacing: 8) {
                if let checked {
                    Button { toggleTask(block.line) } label: {
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle").frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(InkTheme.accent)
                        .accessibilityLabel(checked ? "取消完成任务" : "完成任务")
                    children.strikethrough(checked).padding(.top, 5)
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
                ScrollView(.horizontal) {
                    Text(block.text.hasSuffix("\n") ? String(block.text.dropLast()) : block.text)
                        .font(.system(.callout, design: .monospaced)).fixedSize(horizontal: true, vertical: true)
                }
            }.padding(14).background(InkTheme.background, in: RoundedRectangle(cornerRadius: 10))
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(block.children.enumerated()), id: \.element.id) { index, row in
                        GridRow {
                            ForEach(row.children) { cell in
                                MarkdownInlineView(nodes: cell.inline)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .fontWeight(index == 0 ? .semibold : .regular)
                                    .frame(minWidth: 90, maxWidth: 280, alignment: cellAlignment(cell))
                                    .padding(10)
                                    .background(index == 0 ? InkTheme.accent.opacity(0.12) : Color.secondary.opacity(index.isMultiple(of: 2) ? 0.06 : 0.02))
                                    .overlay { Rectangle().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5) }
                            }
                        }
                    }
                }
            }
        case .divider: Divider().padding(.vertical, 6)
        case .html: Text(block.text).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        case .row, .cell: children
        }
    }
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title
        case 3: return .title2
        case 4: return .title3
        case 5: return .headline
        default: return .subheadline
        }
    }
    private func cellAlignment(_ cell: MarkdownBlock) -> Alignment {
        guard case .cell(let alignment) = cell.kind else { return .leading }
        switch alignment { case "center": return .center; case "right": return .trailing; default: return .leading }
    }
}

private struct MarkdownInlineView: View {
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
                    if let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFit().accessibilityLabel(alt.isEmpty ? "图片" : alt)
                            case .failure: Label(alt.isEmpty ? "图片加载失败" : alt, systemImage: "photo").foregroundStyle(.secondary)
                            default: ProgressView().accessibilityLabel("加载图片")
                            }
                        }.frame(maxWidth: 640)
                    } else {
                        LocalMarkdownImage(source: source, alt: alt)
                    }
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
                part = AttributedString(text); part.font = .system(.body, design: .monospaced)
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
            }
            result.append(part)
        }
    }
}

private struct LocalMarkdownImage: View {
    @Environment(\.attachmentLoader) private var loader
    let source: String
    let alt: String
    @State private var data: Data?
    @State private var failed = false
    var body: some View {
        Group {
            #if os(iOS)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(alt.isEmpty ? "图片" : alt)
            } else { placeholder }
            #else
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(alt.isEmpty ? "图片" : alt)
            } else { placeholder }
            #endif
        }.frame(maxWidth: 640)
        .task(id: source) {
            data = nil; failed = false
            do { data = try await loader?(source); failed = data == nil }
            catch { failed = true }
        }
    }
    private var placeholder: some View {
        Group {
            if failed { Label(alt.isEmpty ? "本地图片不可用：" + source : alt, systemImage: "photo").foregroundStyle(.secondary) }
            else { ProgressView("加载图片") }
        }
    }
}
