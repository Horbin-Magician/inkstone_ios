import Foundation
import Markdown

/// A presentation-independent tree. Source lines are zero-based and refer to the original file.
public struct MarkdownBlock: Identifiable, Sendable {
    public enum Kind: Sendable { case paragraph, heading(Int), quote, list, item(String, Bool?), code(String?), table, row, cell(String?), divider, html }
    public let id: String
    public let line: Int
    public let kind: Kind
    public var text: String = ""
    public var inline: [MarkdownInline] = []
    public var children: [MarkdownBlock] = []
}

public indirect enum MarkdownInline: Sendable {
    case text(String), code(String), emphasis([Self]), strong([Self]), strike([Self])
    case link(String, [Self]), image(String, String), wiki(String, String)

    public var plainText: String {
        switch self {
        case .text(let s), .code(let s): return s
        case .emphasis(let nodes), .strong(let nodes), .strike(let nodes), .link(_, let nodes): return nodes.map(\.plainText).joined()
        case .image(_, let alt), .wiki(_, let alt): return alt
        }
    }
}

public struct MarkdownDocument: Sendable {
    public let blocks: [MarkdownBlock]
    private let source: String
    public init(_ source: String) {
        self.source = source
        // Blank frontmatter instead of removing it so task callbacks retain original line numbers.
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
            for i in 0...end { lines[i] = "" }
        }
        let document = Document(parsing: lines.joined(separator: "\n"))
        blocks = document.children.enumerated().map { Self.block($0.element, id: "\($0.offset)", sourceLines: lines) }
    }

    /// Toggle only a parsed task marker, preserving every other byte, including CRLFs.
    public static func togglingTask(in source: String, at line: Int) -> String {
        MarkdownDocument(source).togglingTask(at: line)
    }
    public func togglingTask(at line: Int) -> String {
        func hasTask(_ blocks: [MarkdownBlock]) -> Bool {
            blocks.contains { block in
                if case .item(_, .some) = block.kind, block.line == line { return true }
                return hasTask(block.children)
            }
        }
        guard hasTask(blocks) else { return source }
        var replacementRange: Range<String.Index>?
        var index = 0
        source.enumerateSubstrings(in: source.startIndex..., options: .byLines) { _, range, _, stop in
            defer { index += 1 }
            guard index == line else { return }
            replacementRange = source.range(of: #"\[[ xX]\]"#, options: .regularExpression, range: range)
            stop = true
        }
        guard let range = replacementRange else { return source }
        var result = source
        result.replaceSubrange(range, with: source[range].lowercased() == "[x]" ? "[ ]" : "[x]")
        return result
    }

    public var previewText: String {
        func collect(_ blocks: [MarkdownBlock]) -> [String] {
            blocks.flatMap { block -> [String] in
                switch block.kind {
                case .heading, .code, .html, .divider: return []
                default:
                    let text = block.inline.map(\.plainText).joined()
                    return (text.isEmpty ? [] : [text]) + collect(block.children)
                }
            }
        }
        return collect(blocks).joined(separator: " ")
    }

    public var headings: [Heading] {
        var result: [Heading] = []
        func visit(_ block: MarkdownBlock) {
            if case .heading(let level) = block.kind {
                result.append(Heading(line: block.line, level: level, title: block.inline.map(\.plainText).joined()))
            }
            block.children.forEach(visit)
        }
        blocks.forEach(visit)
        return result
    }

    public var links: [WikiLink] {
        var result: [WikiLink] = []
        func inline(_ node: MarkdownInline) {
            switch node {
            case .wiki(let target, let label): result.append(WikiLink(target: target, label: label))
            case .emphasis(let nodes), .strong(let nodes), .strike(let nodes): nodes.forEach(inline)
            default: break
            }
        }
        func visit(_ block: MarkdownBlock) { block.inline.forEach(inline); block.children.forEach(visit) }
        blocks.forEach(visit)
        return result
    }

    private static func block(_ markup: Markup, id: String, marker: String = "•", sourceLines: [String]) -> MarkdownBlock {
        let kind: MarkdownBlock.Kind
        var fallbackTask: Bool?
        if let item = markup as? ListItem, item.checkbox == nil, let location = item.range?.lowerBound,
           sourceLines.indices.contains(location.line - 1) {
            let bytes = sourceLines[location.line - 1].utf8.dropFirst(max(0, location.column - 1))
            let source = String(decoding: bytes, as: UTF8.self)
            if let marker = source.range(of: #"^(?:[-+*]|[0-9]+[.)])[ \t]+\[[ xX]\](?=[ \t]|$)"#, options: .regularExpression) {
                fallbackTask = source[marker].lowercased().hasSuffix("[x]")
            }
        }
        switch markup {
        case let node as Markdown.Heading: kind = .heading(node.level)
        case is BlockQuote: kind = .quote
        case is OrderedList, is UnorderedList: kind = .list
        case let node as ListItem: kind = .item(marker, node.checkbox.map { $0 == .checked } ?? fallbackTask)
        case let node as CodeBlock: kind = .code(node.language)
        case is Table: kind = .table
        case is Table.Head, is Table.Row: kind = .row
        case is Table.Cell: kind = .cell(nil)
        case is ThematicBreak: kind = .divider
        case is HTMLBlock: kind = .html
        default: kind = .paragraph
        }
        var result = MarkdownBlock(id: id, line: max(0, (markup.range?.lowerBound.line ?? 1) - 1), kind: kind)
        if let code = markup as? CodeBlock { result.text = code.code; return result }
        if let html = markup as? HTMLBlock { result.text = html.rawHTML; return result }
        if markup is Paragraph || markup is Markdown.Heading || markup is Table.Cell {
            result.inline = markup.children.flatMap { inline($0) }
        } else if let table = markup as? Table {
            let rows: [Markup] = [table.head] + Array(table.body.children)
            result.children = rows.enumerated().map { index, row in
                var converted = MarkdownBlock(id: "\(id).\(index)", line: max(0, (row.range?.lowerBound.line ?? 1) - 1), kind: .row)
                converted.children = row.children.enumerated().map { column, cell in
                    var convertedCell = block(cell, id: "\(id).\(index).\(column)", sourceLines: sourceLines)
                    let alignment = column < table.columnAlignments.count ? table.columnAlignments[column] : nil
                    convertedCell = MarkdownBlock(id: convertedCell.id, line: convertedCell.line, kind: .cell(alignment.map { String(describing: $0) }), inline: convertedCell.inline)
                    return convertedCell
                }
                return converted
            }
        } else {
            result.children = markup.children.enumerated().map { offset, child in
                let label = (markup as? OrderedList).map { "\($0.startIndex + UInt(offset))." } ?? "•"
                return block(child, id: "\(id).\(offset)", marker: label, sourceLines: sourceLines)
            }
        }
        // Some cmark versions leave tasks inside quotes as literal paragraph text.
        // Recover only when the original list marker contains an unescaped checkbox.
        if fallbackTask != nil, !result.children.isEmpty,
           case .paragraph = result.children[0].kind,
           let first = result.children[0].inline.first, case .text(let text) = first,
           text.range(of: #"^\[[ xX]\](?:[ \t]+|$)"#, options: .regularExpression) != nil {
            let stripped = text.replacingOccurrences(of: #"^\[[ xX]\][ \t]*"#, with: "", options: .regularExpression)
            result.children[0].inline[0] = .text(stripped)
        }
        return result
    }

    private static func inline(_ markup: Markup, allowWiki: Bool = true) -> [MarkdownInline] {
        let children = { markup.children.flatMap { inline($0, allowWiki: allowWiki) } }
        switch markup {
        case let node as Markdown.Text: return allowWiki ? wikiText(node.string) : [.text(node.string)]
        case let node as InlineCode: return [.code(node.code)]
        case is Emphasis: return [.emphasis(children())]
        case is Strong: return [.strong(children())]
        case is Strikethrough: return [.strike(children())]
        case let node as Markdown.Link: return [.link(node.destination ?? "", node.children.flatMap { inline($0, allowWiki: false) })]
        case let node as Markdown.Image: return [.image(node.source ?? "", node.plainText)]
        case is SoftBreak: return [.text(" ")]
        case is LineBreak: return [.text("\n")]
        case let node as InlineHTML: return [.text(node.rawHTML)]
        default: return children()
        }
    }

    private static let wikiRegex = try! NSRegularExpression(pattern: #"(?<!!)\[\[([^\]\n]+)\]\]"#)
    private static func wikiText(_ text: String) -> [MarkdownInline] {
        guard text.contains("[[") else { return [.text(text)] }
        var result: [MarkdownInline] = [], position = text.startIndex
        for match in wikiRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let capture = Range(match.range(at: 1), in: text) else { continue }
            result.append(.text(String(text[position..<range.lowerBound])))
            let parts = text[capture].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts[0].isEmpty { result.append(.text(String(text[range]))) }
            else { result.append(.wiki(parts[0], parts.count > 1 ? parts[1] : parts[0])) }
            position = range.upperBound
        }
        result.append(.text(String(text[position...])))
        return result
    }
}
