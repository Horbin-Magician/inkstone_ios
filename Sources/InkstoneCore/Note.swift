import Foundation

public struct Note: Identifiable, Hashable, Codable, Sendable {
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
        let document = MarkdownDocument(text)
        metadata = MarkdownMetadata(document: document)
        excerpt = String(document.previewText.prefix(150))
    }
    /// Resolve a draft once before creating either its body or attachments.
    public static func draftPath(folder: String, filename: String, fallback: String) throws -> String {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.contains("/"), !name.contains("\\"), !name.hasPrefix(".") else { throw VaultError.invalidPath }
        let leaf = name.isEmpty ? (fallback as NSString).lastPathComponent
            : name + (name.lowercased().hasSuffix(".md") ? "" : ".md")
        let path = (folder.isEmpty ? "" : folder + "/") + leaf
        try SyncManifest.validatePath(path)
        return path
    }
    /// A provider may touch a file without changing its Markdown.
    /// Keep all content-derived values instead of parsing the document again.
    func withModified(_ modified: Date) -> Note {
        Note(path: path, text: text, modified: modified, title: title, folder: folder,
             metadata: metadata, excerpt: excerpt)
    }
    private init(path: String, text: String, modified: Date, title: String, folder: String,
                 metadata: MarkdownMetadata, excerpt: String) {
        self.path = path; self.text = text; self.modified = modified
        self.title = title; self.folder = folder; self.metadata = metadata; self.excerpt = excerpt
    }
}

/// Immutable presentation data produced alongside background search results.
public struct NoteSearchResult: Sendable {
    public let note: Note
    public let summary: String
    /// UTF-16 ranges into summary, suitable for Foundation and UI conversion.
    public let highlights: [NSRange]
    init(note: Note, terms: [String]) {
        self.note = note
        if let term = terms.first, let match = note.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = note.text.index(match.lowerBound, offsetBy: -35, limitedBy: note.text.startIndex) ?? note.text.startIndex
            summary = (start == note.text.startIndex ? "" : "…") + String(note.text[start...].prefix(150)).replacingOccurrences(of: "\n", with: " ")
        } else { summary = note.excerpt }
        var ranges: [NSRange] = []
        for term in terms {
            var remaining = summary.startIndex..<summary.endIndex
            while let match = summary.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
                guard match.lowerBound < match.upperBound else { break }
                ranges.append(NSRange(match, in: summary))
                remaining = match.upperBound..<summary.endIndex
            }
        }
        highlights = ranges
    }
}

public struct WikiLink: Hashable, Codable, Sendable {
    public let target: String
    public let label: String
}
public struct Heading: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { line }
    public let line: Int
    public let level: Int
    public let title: String
}
public struct MarkdownMetadata: Hashable, Codable, Sendable {
    public let links: [WikiLink]
    public let headings: [Heading]
    public init(_ source: String) {
        self.init(document: MarkdownDocument(source))
    }
    init(document: MarkdownDocument) {
        headings = document.headings
        links = document.links
    }
}

public enum LinkResolution: Equatable, Sendable { case found(String), missing, ambiguous }
public struct NoteIndex: Sendable {
    private let paths: Set<String>
    private let filenames: [String: LinkResolution]
    private var incoming: [String: [Note]] = [:]
    private var outgoing: [String: Set<String>] = [:]

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
            outgoing[note.path] = targets
        }
    }

    /// Existing paths cannot change filename ambiguity or other notes' link resolution.
    /// New / removed paths must still rebuild the index.
    @discardableResult public mutating func replaceExisting(_ note: Note) -> Bool {
        guard paths.contains(note.path) else { return false }
        for target in outgoing[note.path] ?? [] {
            incoming[target]?.removeAll { $0.path == note.path }
            if incoming[target]?.isEmpty == true { incoming.removeValue(forKey: target) }
        }
        var targets = Set<String>()
        for link in note.metadata.links {
            if case .found(let target) = resolve(link.target, from: note.path),
               target != note.path, targets.insert(target).inserted {
                incoming[target, default: []].append(note)
                incoming[target]?.sort { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
            }
        }
        outgoing[note.path] = targets
        return true
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
    /// Bounded parallel scans preserve Foundation's locale-aware substring semantics.
    /// Each child scans a disjoint range and checks cancellation between notes.
    public static func searchConcurrently(_ notes: [Note], query: String, alreadySorted: Bool = false) async -> [Note] {
        await parallelSearch(notes, query: query, alreadySorted: alreadySorted, presentation: false).map(\.note)
    }
    public static func searchResultsConcurrently(_ notes: [Note], query: String, alreadySorted: Bool = false) async -> [NoteSearchResult] {
        await parallelSearch(notes, query: query, alreadySorted: alreadySorted, presentation: true)
    }
    private static func parallelSearch(_ notes: [Note], query: String, alreadySorted: Bool, presentation: Bool) async -> [NoteSearchResult] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount), max(1, (notes.count + 255) / 256))
        let size = max(1, (notes.count + workers - 1) / workers)
        let chunks = await withTaskGroup(of: (Int, [NoteSearchResult]).self) { group in
            for start in stride(from: 0, to: notes.count, by: size) {
                let end = min(start + size, notes.count)
                group.addTask {
                    var matches: [NoteSearchResult] = []
                    for index in start..<end {
                        if Task.isCancelled { return (start, []) }
                        let note = notes[index]
                        if terms.allSatisfy({ note.path.localizedStandardContains($0) || note.text.localizedStandardContains($0) }) {
                            matches.append(NoteSearchResult(note: note, terms: presentation ? terms : []))
                        }
                    }
                    return (start, matches)
                }
            }
            var chunks: [(Int, [NoteSearchResult])] = []
            for await chunk in group { chunks.append(chunk) }
            return chunks
        }
        guard !Task.isCancelled else { return [] }
        let result = chunks.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        return alreadySorted ? result : result.sorted { $0.note.modified == $1.note.modified ? $0.note.path < $1.note.path : $0.note.modified > $1.note.modified }
    }
    public static func creationPath(_ target: String, from: String) throws -> String {
        let raw = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard !raw.isEmpty else { throw VaultError.invalidPath }
        var parts = raw.hasPrefix("/") ? [] : (from as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for part in raw.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { throw VaultError.invalidPath }
                parts.removeLast()
            } else { parts.append(String(part)) }
        }
        var path = parts.joined(separator: "/")
        if !path.lowercased().hasSuffix(".md") { path += ".md" }
        try SyncManifest.validatePath(path)
        return path
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
