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
    public var callout: MarkdownCallout?
}

public struct MarkdownCallout: Sendable {
    public let type: String
    public let title: String
    /// nil is not collapsible; true/false is the initial expanded state.
    public let expanded: Bool?
}

public indirect enum MarkdownInline: Sendable {
    case text(String), code(String), emphasis([Self]), strong([Self]), strike([Self])
    case link(String, [Self]), image(String, String), wiki(String, String), math(String, Bool)

    public var plainText: String {
        switch self {
        case .text(let s), .code(let s), .math(let s, _): return s
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
        let protected = MathProtection(lines.joined(separator: "\n"))
        let document = Document(parsing: protected.source)
        blocks = document.children.enumerated().map {
            protected.restore(Self.block($0.element, id: "\($0.offset)", sourceLines: lines))
        }
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
        if let quote = markup as? BlockQuote, let paragraph = quote.child(at: 0) as? Paragraph,
           let line = paragraph.range?.lowerBound.line, sourceLines.indices.contains(line - 1) {
            let header = sourceLines[line - 1].replacingOccurrences(of: #"^[ \t]*(?:>[ \t]*)+"#, with: "", options: .regularExpression)
            let regex = try! NSRegularExpression(pattern: #"^\[!([\w-]+)\]([+-])?(?:[ \t]+(.*))?$"#)
            if let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) {
                func capture(_ index: Int) -> String { Range(match.range(at: index), in: header).map { String(header[$0]) } ?? "" }
                let type = capture(1), fold = capture(2), title = capture(3)
                result.callout = MarkdownCallout(type: type.lowercased(), title: title.isEmpty ? type.uppercased() : title,
                                                expanded: fold.isEmpty ? nil : fold == "+")
                let remaining = paragraph.children.drop(while: { !($0 is SoftBreak) && !($0 is LineBreak) }).dropFirst()
                result.children[0].inline = remaining.flatMap { inline($0) }
                if result.children[0].inline.isEmpty { result.children.removeFirst() }
            }
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

    private static let wikiRegex = try! NSRegularExpression(pattern: #"!?\[\[([^\]\n]+)\]\]"#)
    private static func wikiText(_ text: String) -> [MarkdownInline] {
        guard text.contains("[[") else { return [.text(text)] }
        var result: [MarkdownInline] = [], position = text.startIndex
        for match in wikiRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let capture = Range(match.range(at: 1), in: text) else { continue }
            result.append(.text(String(text[position..<range.lowerBound])))
            let parts = text[capture].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if text[range].hasPrefix("!") {
                if let image = ObsidianImageReference(String(text[capture])) { result.append(.image(image.source, image.target)) }
                else { result.append(.text(String(text[range]))) }
            } else if parts[0].isEmpty { result.append(.text(String(text[range]))) }
            else { result.append(.wiki(parts[0], parts.count > 1 ? parts[1] : parts[0])) }
            position = range.upperBound
        }
        result.append(.text(String(text[position...])))
        return result
    }
}

/// Protect TeX before CommonMark consumes backslashes, underscores, or asterisks.
/// Placeholders exist only in the presentation tree and preserve source line numbers.
private struct MathProtection {
    var source: String
    var formulas: [String: MarkdownInline] = [:]
    private let prefix = "INKSTONEMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    init(_ original: String) {
        source = original
        guard original.contains("$") else { return }
        let lines = original.components(separatedBy: "\n")
        var offsets = [0]
        for line in lines.dropLast() { offsets.append(offsets.last! + line.utf8.count + 1) }
        func offset(_ location: SourceLocation) -> Int { offsets[min(location.line - 1, offsets.count - 1)] + location.column - 1 }
        var excluded: [Range<Int>] = []
        func visit(_ node: Markup) {
            if node is CodeBlock || node is InlineCode || node is HTMLBlock || node is InlineHTML || node is Markdown.Image || node is Markdown.Link,
               let range = node.range {
                excluded.append(offset(range.lowerBound)..<offset(range.upperBound)); return
            }
            node.children.forEach(visit)
        }
        visit(Document(parsing: original))
        // Wiki destinations and reference definitions are addresses, not TeX.
        let addresses = try! NSRegularExpression(pattern: #"!?\[\[[^\]\n]+\]\]|(?m)^[ \t]{0,3}\[[^\]\n]+\]:[^\n]*"#)
        for match in addresses.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
            if let range = Range(match.range, in: original) {
                let start = original[..<range.lowerBound].utf8.count
                excluded.append(start..<(start + original[range].utf8.count))
            }
        }
        // Same delimiter rules as the editor: no whitespace inside a single-dollar
        // boundary, no newlines in inline math, and no closing dollar before a digit.
        let regex = try! NSRegularExpression(pattern: #"\$\$([\s\S]+?)\$\$|(?<!\$)\$(?!\$)((?:\\[^\n]|[^$\n\\])+?)\$(?![\d$])"#)
        let matches = regex.matches(in: original, range: NSRange(original.startIndex..., in: original))
        for (index, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range, in: original) else { continue }
            let start = original[..<range.lowerBound].utf8.count
            let end = start + original[range].utf8.count
            if excluded.contains(where: { $0.overlaps(start..<end) }) { continue }
            var escapes = 0
            for character in original[..<range.lowerBound].reversed() { if character != "\\" { break }; escapes += 1 }
            if escapes % 2 == 1 { continue }
            let display = match.range(at: 1).location != NSNotFound
            guard let content = Range(match.range(at: display ? 1 : 2), in: original) else { continue }
            let token = prefix + String(index) + "END"
            var value = String(original[content])
            if !display && (value.first?.isWhitespace == true || value.last?.isWhitespace == true) { continue }
            let linePrefix = original[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            if linePrefix.contains(">") {
                value = value.replacingOccurrences(of: #"(?m)^[ \t]*(?:>[ \t]*)+"#, with: "", options: .regularExpression)
            }
            formulas[token] = .math(value.trimmingCharacters(in: .whitespacesAndNewlines), display)
            // Keep quote prefixes on continuation lines so nested containers survive.
            let continuations = original[range].components(separatedBy: "\n").dropFirst().map { line -> String in
                let prefix = line.prefix(while: { $0 == " " || $0 == "\t" || $0 == ">" })
                return "\n" + prefix
            }.joined()
            // Reversed replacement means the original UTF-16 offsets remain valid.
            let replacementRange = Range(match.range, in: source)!
            source.replaceSubrange(replacementRange, with: token + continuations)
        }
    }
    func restore(_ block: MarkdownBlock) -> MarkdownBlock {
        var result = block
        result.inline = block.inline.flatMap(restoreInline)
        result.children = block.children.map(restore)
        return result
    }
    private func restoreInline(_ node: MarkdownInline) -> [MarkdownInline] {
        switch node {
        case .text(let text):
            guard text.contains(prefix) else { return [node] }
            let regex = try! NSRegularExpression(pattern: prefix + #"[0-9]+END"#)
            var result: [MarkdownInline] = [], cursor = text.startIndex
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let formula = formulas[String(text[range])] else { continue }
                if cursor < range.lowerBound { result.append(.text(String(text[cursor..<range.lowerBound]))) }
                result.append(formula); cursor = range.upperBound
            }
            if cursor < text.endIndex { result.append(.text(String(text[cursor...]))) }
            return result
        case .strong(let nodes): return [.strong(nodes.flatMap(restoreInline))]
        case .emphasis(let nodes): return [.emphasis(nodes.flatMap(restoreInline))]
        case .strike(let nodes): return [.strike(nodes.flatMap(restoreInline))]
        case .link(let target, let nodes): return [.link(target, nodes.flatMap(restoreInline))]
        default: return [node]
        }
    }
}
