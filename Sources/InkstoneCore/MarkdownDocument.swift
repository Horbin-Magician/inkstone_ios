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
    private static let yamlKeyRegex = try! NSRegularExpression(pattern: #"^[^\s#:][^:\n]*:(?:[ \t]|$)"#)
    private static let calloutRegex = try! NSRegularExpression(pattern: #"^\[!([\w-]+)\]([+-])?(?:[ \t]+(.*))?$"#)
    private static let taskAnchorRegex = try! NSRegularExpression(pattern: #"^[ \t>]*(?:[-+*]|[0-9]+[.)])[ \t]+(\[[ xX]\])(?=[ \t]|$)"#)

    private static func looksLikeFrontmatter(_ body: ArraySlice<String>) -> Bool {
        if body.isEmpty { return true }
        var sawKey = false
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if line.hasPrefix(" ") || line.hasPrefix("\t") || trimmed.hasPrefix("- ") || trimmed == "-" {
                if !sawKey { return false }
                continue
            }
            if yamlKeyRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                sawKey = true
                continue
            }
            return false
        }
        return sawKey
    }

    public init(_ source: String) {
        self.source = source
        // Blank frontmatter instead of removing it so task callbacks retain original line numbers.
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if let first = lines.first {
            let cleanFirst = first.hasPrefix("\u{FEFF}") ? String(first.dropFirst()) : first
            if cleanFirst.trimmingCharacters(in: .whitespaces) == "---",
               let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }),
               Self.looksLikeFrontmatter(lines[1..<end]) {
                for i in 0...end { lines[i] = "" }
            }
        }
        let protected = MathProtection(lines: lines)
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
        guard hasTask(blocks), line >= 0 else { return source }
        // Split strictly on \r\n, \r, \n via unicodeScalars (Swift Character merges \r\n into one grapheme)
        // to stay aligned with swift-markdown line numbers and ignore U+2028/U+2029/U+0085.
        let scalars = source.unicodeScalars
        var index = 0
        var cursor = scalars.startIndex
        var lineRange: Range<String.UnicodeScalarView.Index>?
        while cursor <= scalars.endIndex {
            var end = cursor
            while end < scalars.endIndex && scalars[end] != "\n" && scalars[end] != "\r" {
                end = scalars.index(after: end)
            }
            if index == line {
                lineRange = cursor..<end
                break
            }
            if end == scalars.endIndex { break }
            if scalars[end] == "\r" {
                let next = scalars.index(after: end)
                cursor = (next < scalars.endIndex && scalars[next] == "\n") ? scalars.index(after: next) : next
            } else {
                cursor = scalars.index(after: end)
            }
            index += 1
        }
        guard let targetLine = lineRange else { return source }
        let lineText = String(scalars[targetLine])
        let nsRange = NSRange(lineText.startIndex..., in: lineText)
        guard let match = Self.taskAnchorRegex.firstMatch(in: lineText, range: nsRange),
              let capture = Range(match.range(at: 1), in: lineText) else { return source }
        let offsetStart = lineText.unicodeScalars.distance(from: lineText.unicodeScalars.startIndex, to: capture.lowerBound)
        let offsetEnd = lineText.unicodeScalars.distance(from: lineText.unicodeScalars.startIndex, to: capture.upperBound)
        let startIdx = scalars.index(targetLine.lowerBound, offsetBy: offsetStart)
        let endIdx = scalars.index(targetLine.lowerBound, offsetBy: offsetEnd)
        let range = startIdx..<endIdx
        var result = source
        result.replaceSubrange(range, with: source[range].lowercased() == "[x]" ? "[ ]" : "[x]")
        return result
    }

    public var previewText: String { previewText(limit: nil) }
    func previewText(limit: Int?) -> String {
        var chunks: [String] = []
        var total = 0
        func collect(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                if let limit, total >= limit { return }
                switch block.kind {
                case .heading, .code, .html, .divider: continue
                default:
                    let text = block.inline.map(\.plainText).joined()
                    if !text.isEmpty {
                        chunks.append(text)
                        total += text.count + 1
                    }
                    collect(block.children)
                }
            }
        }
        collect(blocks)
        let joined = chunks.joined(separator: " ")
        if let limit { return String(joined.prefix(limit)) }
        return joined
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
            if let match = Self.calloutRegex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) {
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
    private var prefix = ""
    private var tokenPattern: NSRegularExpression?
    private static let addresses = try! NSRegularExpression(pattern: #"!?\[\[[^\]\n]+\]\]|(?m)^[ \t]{0,3}\[[^\]\n]+\]:[^\n]*"#)

    private struct Candidate {
        let range: Range<String.Index>
        let content: Range<String.Index>
        let display: Bool
    }

    private static func isEscaped(_ text: String, at index: String.Index) -> Bool {
        var escapes = 0
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            if text[cursor] != "\\" { break }
            escapes += 1
        }
        return escapes % 2 == 1
    }

    private static func scanCandidates(in text: String) -> [Candidate] {
        var candidates: [Candidate] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let open = text[cursor...].firstIndex(of: "$") else { break }
            if isEscaped(text, at: open) {
                cursor = text.index(after: open)
                continue
            }
            let afterOpen = text.index(after: open)
            if afterOpen < text.endIndex && text[afterOpen] == "$" {
                // Display math: $$...$$
                let contentStart = text.index(after: afterOpen)
                var search = contentStart
                var closeStart: String.Index?
                while search < text.endIndex {
                    guard let found = text[search...].range(of: "$$") else { break }
                    if found.lowerBound > contentStart && !isEscaped(text, at: found.lowerBound) {
                        closeStart = found.lowerBound
                        break
                    }
                    search = text.index(after: found.lowerBound)
                }
                if let closeStart {
                    let closeEnd = text.index(closeStart, offsetBy: 2)
                    candidates.append(Candidate(range: open..<closeEnd, content: contentStart..<closeStart, display: true))
                    cursor = closeEnd
                    continue
                }
                cursor = contentStart
                continue
            }
            // Inline math: $...$ (single line, no outer whitespace, no trailing digit or $)
            guard afterOpen < text.endIndex else { break }
            let firstChar = text[afterOpen]
            if firstChar == "\n" || firstChar.isWhitespace || firstChar == "$" {
                cursor = afterOpen
                continue
            }
            var scan = afterOpen
            var matched = false
            while scan < text.endIndex {
                let ch = text[scan]
                if ch == "\n" { break }
                if ch == "\\" {
                    let next = text.index(after: scan)
                    scan = (next < text.endIndex && text[next] != "\n") ? text.index(after: next) : next
                    continue
                }
                if ch == "$" {
                    let closeEnd = text.index(after: scan)
                    let prevChar = text[text.index(before: scan)]
                    let nextIsForbidden: Bool
                    if closeEnd < text.endIndex {
                        let nextCh = text[closeEnd]
                        nextIsForbidden = nextCh == "$" || (nextCh.isASCII && nextCh.isNumber)
                    } else {
                        nextIsForbidden = false
                    }
                    if scan > afterOpen && !prevChar.isWhitespace && !nextIsForbidden {
                        candidates.append(Candidate(range: open..<closeEnd, content: afterOpen..<scan, display: false))
                        cursor = closeEnd
                        matched = true
                    } else {
                        // Do not consume `scan` — it may open a valid formula like `Costs $5 and $x = 1$`.
                        cursor = scan
                        matched = true
                    }
                    break
                }
                scan = text.index(after: scan)
            }
            if !matched { cursor = afterOpen }
        }
        return candidates
    }

    init(lines: [String]) {
        let original = lines.joined(separator: "\n")
        source = original
        guard original.utf8.contains(0x24) else { return }
        let candidates = Self.scanCandidates(in: original)
        guard !candidates.isEmpty else { return }
        prefix = "INKSTONEMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var offsets = [0]
        offsets.reserveCapacity(lines.count)
        for line in lines.dropLast() { offsets.append(offsets.last! + line.utf8.count + 1) }
        func offset(_ location: SourceLocation) -> Int {
            let lineIndex = max(0, min(location.line - 1, offsets.count - 1))
            return offsets[lineIndex] + max(0, location.column - 1)
        }
        var excluded: [Range<Int>] = []
        func visit(_ node: Markup) {
            if node is CodeBlock || node is InlineCode || node is HTMLBlock || node is InlineHTML || node is Markdown.Image || node is Markdown.Link,
               let range = node.range {
                let lower = offset(range.lowerBound), upper = offset(range.upperBound)
                if lower < upper { excluded.append(lower..<upper) }
                return
            }
            node.children.forEach(visit)
        }
        visit(Document(parsing: original))
        // Wiki destinations and reference definitions are addresses, not TeX.
        for match in Self.addresses.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
            if let range = Range(match.range, in: original) {
                let start = original[..<range.lowerBound].utf8.count
                let end = start + original[range].utf8.count
                if start < end { excluded.append(start..<end) }
            }
        }
        // Merge sorted excluded ranges for O(log E) lookup.
        excluded.sort { $0.lowerBound < $1.lowerBound }
        var mergedExcluded: [Range<Int>] = []
        for range in excluded {
            if let last = mergedExcluded.last, range.lowerBound <= last.upperBound {
                mergedExcluded[mergedExcluded.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                mergedExcluded.append(range)
            }
        }
        func isExcluded(_ span: Range<Int>) -> Bool {
            var low = 0, high = mergedExcluded.count
            while low < high {
                let mid = (low + high) / 2
                if mergedExcluded[mid].upperBound <= span.lowerBound { low = mid + 1 }
                else { high = mid }
            }
            return low < mergedExcluded.count && mergedExcluded[low].lowerBound < span.upperBound
        }
        var rewritten = ""
        var cursor = original.startIndex
        var utf8Cursor = 0
        var lastIndex = original.startIndex
        for (index, candidate) in candidates.enumerated() {
            let range = candidate.range
            utf8Cursor += original[lastIndex..<range.lowerBound].utf8.count
            lastIndex = range.lowerBound
            let start = utf8Cursor
            let end = start + original[range].utf8.count
            if isExcluded(start..<end) { continue }
            let token = prefix + String(index) + "END"
            var value = String(original[candidate.content])
            let before = original[..<range.lowerBound]
            if value.contains(">"), before.reversed().lazy.prefix(while: { $0 != "\n" }).contains(">") {
                value = value.replacingOccurrences(of: #"(?m)^[ \t]*(?:>[ \t]*)+"#, with: "", options: .regularExpression)
            }
            formulas[token] = .math(value.trimmingCharacters(in: .whitespacesAndNewlines), candidate.display)
            // Keep quote prefixes on continuation lines so nested containers survive.
            let continuations = original[range].components(separatedBy: "\n").dropFirst().map { line -> String in
                let prefix = line.prefix(while: { $0 == " " || $0 == "\t" || $0 == ">" })
                return "\n" + prefix
            }.joined()
            rewritten += original[cursor..<range.lowerBound]
            rewritten += token + continuations
            cursor = range.upperBound
        }
        if !formulas.isEmpty {
            rewritten += original[cursor...]
            source = rewritten
            tokenPattern = try! NSRegularExpression(pattern: prefix + #"[0-9]+END"#)
        }
    }
    func restore(_ block: MarkdownBlock) -> MarkdownBlock {
        guard tokenPattern != nil else { return block }
        var result = block
        result.inline = block.inline.flatMap(restoreInline)
        result.children = block.children.map(restore)
        return result
    }
    private func restoreInline(_ node: MarkdownInline) -> [MarkdownInline] {
        switch node {
        case .text(let text):
            guard let regex = tokenPattern, text.contains(prefix) else { return [node] }
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
