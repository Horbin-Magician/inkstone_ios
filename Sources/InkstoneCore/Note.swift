import Foundation

public struct Note: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let text: String
    public let modified: Date
    public let title: String
    public let folder: String
    public let metadata: MarkdownMetadata
    public let excerpt: String
    public init(path: String, text: String, modified: Date = Date()) {
        self.path = path; self.text = text; self.modified = modified
        title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        folder = (path as NSString).deletingLastPathComponent
        metadata = MarkdownMetadata(text)
        var lines: [String] = []
        text.enumerateLines { line, stop in
            if !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line)
                stop = lines.count == 3
            }
        }
        excerpt = String(lines.joined(separator: " ").prefix(150))
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
public struct MarkdownMetadata: Hashable, Sendable {
    public let links: [WikiLink]
    public let headings: [Heading]
    public init(_ source: String) {
        let document = MarkdownDocument(source)
        headings = document.headings
        links = document.links
    }
}

public enum LinkResolution: Equatable, Sendable { case found(String), missing, ambiguous }
public struct NoteIndex: Sendable {
    private let paths: Set<String>
    private let filenames: [String: LinkResolution]
    private var incoming: [String: [Note]] = [:]

    public init(notes: [Note]) {
        paths = Set(notes.map(\.path))
        var filenames: [String: LinkResolution] = [:]
        for note in notes {
            let name = (note.path as NSString).lastPathComponent
            filenames[name] = filenames[name] == nil ? .found(note.path) : .ambiguous
        }
        self.filenames = filenames
        for note in notes {
            var targets = Set<String>()
            for link in note.metadata.links {
                if case .found(let path) = resolve(link.target, from: note.path),
                   path != note.path, targets.insert(path).inserted {
                    incoming[path, default: []].append(note)
                }
            }
        }
    }

    public func backlinks(to path: String) -> [Note] { incoming[path] ?? [] }

    public static func search(_ notes: [Note], query: String) -> [Note] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return notes.filter { note in
            guard !Task.isCancelled else { return false }
            return terms.allSatisfy {
                note.path.localizedStandardContains($0) || note.text.localizedStandardContains($0)
            }
        }.sorted { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
    }
    public static func resolve(_ target: String, from: String, notes: [Note]) -> LinkResolution {
        NoteIndex(notes: notes).resolve(target, from: from)
    }
    public func resolve(_ target: String, from: String) -> LinkResolution {
        let raw = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if raw.isEmpty { return .found(from) }
        let name = raw.lowercased().hasSuffix(".md") ? raw : raw + ".md"
        let path = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let parent = (from as NSString).deletingLastPathComponent
        let relative = parent.isEmpty ? path : parent + "/" + path
        let direct = name.hasPrefix("/") ? [path] : [relative, path]
        for unnormalized in direct {
            var components: [String] = []
            var escapedRoot = false
            for component in unnormalized.split(separator: "/") {
                if component == "." { continue }
                if component == ".." {
                    if components.isEmpty { escapedRoot = true; break }
                    components.removeLast()
                } else { components.append(String(component)) }
            }
            guard !escapedRoot else { continue }
            let candidate = components.joined(separator: "/")
            if paths.contains(candidate) { return .found(candidate) }
        }
        guard !name.contains("/") else { return .missing }
        return filenames[name] ?? .missing
    }
    public static func backlinks(to path: String, notes: [Note]) -> [Note] {
        NoteIndex(notes: notes).backlinks(to: path)
    }
}
