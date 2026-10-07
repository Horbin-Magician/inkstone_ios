import Foundation

public struct Note: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let text: String
    public let modified: Date
    public init(path: String, text: String, modified: Date = Date()) {
        self.path = path; self.text = text; self.modified = modified
    }
    public var title: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var metadata: MarkdownMetadata { MarkdownMetadata(text) }
    public var excerpt: String {
        let lines = text.components(separatedBy: .newlines)
        return lines.filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3).joined(separator: " ").prefix(150).description
    }
}

public struct WikiLink: Hashable, Sendable {
    public let target: String
    public let label: String
}
public struct Heading: Identifiable, Hashable, Sendable {
    public var id: Int { line }
    public let line: Int
    public let level: Int
    public let title: String
}
public struct MarkdownMetadata: Sendable {
    public let tags: [String]
    public let links: [WikiLink]
    public let headings: [Heading]
    public init(_ source: String) {
        var headings: [Heading] = [], links: [WikiLink] = [], tags = Set<String>()
        var fence: Character?
        var frontmatter = false
        for (index, line) in source.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0 && trimmed == "---" { frontmatter = true; continue }
            if frontmatter {
                if trimmed == "---" { frontmatter = false }
                else if trimmed.hasPrefix("tags:") {
                    trimmed.dropFirst(5).components(separatedBy: CharacterSet(charactersIn: ",[] \"'"))
                        .filter { !$0.isEmpty }.forEach { tags.insert($0) }
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if fence == nil { fence = trimmed.first } else if fence == trimmed.first { fence = nil }
                continue
            }
            guard fence == nil else { continue }
            if let match = Self.matches(#"^(#{1,6})\s+(.+)$"#, in: line).first {
                headings.append(Heading(line: index, level: match[1].count, title: match[2]))
            }
            let prose = line.replacingOccurrences(of: #"`+[^`]*`+"#, with: "", options: .regularExpression)
            for match in Self.matches(#"(?<!!)\[\[([^\]]+)\]\]"#, in: prose) {
                let parts = match[1].split(separator: "|", maxSplits: 1).map(String.init)
                links.append(WikiLink(target: parts[0], label: parts.count > 1 ? parts[1] : parts[0]))
            }
            for match in Self.matches(#"(?:^|\s)#([\p{L}\p{N}_/-]+)"#, in: prose) { tags.insert(match[1]) }
        }
        self.headings = headings; self.links = links; self.tags = tags.sorted()
    }
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
        }
    }
}

public enum LinkResolution: Equatable { case found(String), missing, ambiguous }
public enum NoteIndex {
    public static func search(_ notes: [Note], query: String, tag: String? = nil) -> [Note] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return notes.filter { note in
            (tag == nil || note.metadata.tags.contains(tag!)) && terms.allSatisfy {
                note.path.localizedStandardContains($0) || note.text.localizedStandardContains($0)
            }
        }.sorted { $0.modified > $1.modified }
    }
    public static func resolve(_ target: String, from: String, notes: [Note]) -> LinkResolution {
        let raw = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if raw.isEmpty { return .found(from) }
        let name = raw.lowercased().hasSuffix(".md") ? raw : raw + ".md"
        let path = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let parent = (from as NSString).deletingLastPathComponent
        let relative = parent.isEmpty ? path : parent + "/" + path
        let direct = name.hasPrefix("/") ? [path] : [relative, path]
        for candidate in direct {
            if let match = notes.first(where: { $0.path == candidate }) { return .found(match.path) }
        }
        guard !name.contains("/") else { return .missing }
        let matches = notes.filter { ($0.path as NSString).lastPathComponent == name }
        if matches.count == 1 { return .found(matches[0].path) }
        return matches.isEmpty ? .missing : .ambiguous
    }
    public static func backlinks(to path: String, notes: [Note]) -> [Note] {
        notes.filter { note in note.path != path && note.metadata.links.contains {
            resolve($0.target, from: note.path, notes: notes) == .found(path)
        }}
    }
}
