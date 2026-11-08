import Foundation
import Testing
@testable import InkstoneCore

final class IndexTests {
    @Test func replacingExistingUpdatesOnlyItsLinksAndKeepsSnapshotsImmutable() {
        let old = Note(path: "source.md", text: "[[a]] [[a|again]]", modified: .distantPast)
        let a = Note(path: "a.md", text: ""), b = Note(path: "b.md", text: "")
        var index = NoteIndex(notes: [old, a, b])
        let previous = index
        let edited = Note(path: "source.md", text: "[[b]] [[source]]")
        let replaced = index.replaceExisting(edited)
        #expect(replaced)
        #expect(index.backlinks(to: "a.md").isEmpty)
        #expect(index.backlinks(to: "b.md") == [edited])
        #expect(index.backlinks(to: "source.md").isEmpty)
        #expect(previous.backlinks(to: "a.md") == [old])
        let inserted = index.replaceExisting(Note(path: "new.md", text: "[[a]]"))
        #expect(!inserted)
        #expect(index.resolve("new", from: "source.md") == .missing)
    }
    @Test func parallelSearchMatchesSerialUnicodeSemanticsAndOrdering() async {
        let notes = (0..<1100).map { Note(path: "folder/\($0).md", text: $0.isMultiple(of: 2) ? "中文 café ＡＢＣ Straße 👩‍💻 é" : "another document", modified: Date(timeIntervalSince1970: Double($0 % 7))) }
        for query in ["中文 cafe", "abc", "strasse", "é", "👩‍💻", "missing", "", " \n ", "folder 中文"] {
            let serial = NoteIndex.search(notes, query: query)
            #expect(await NoteIndex.searchConcurrently(notes, query: query) == serial)
            let sorted = NoteIndex.search(notes, query: "")
            #expect(await NoteIndex.searchConcurrently(sorted, query: query, alreadySorted: true) == serial)
        }
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await NoteIndex.searchConcurrently(notes, query: "中文")
        }
        #expect(await worker.value.isEmpty)
        #expect(await NoteIndex.searchConcurrently([], query: "test").isEmpty)
    }
    @Test func reusableIndexPreservesResolutionAndDeduplicatesBacklinks() {
        let notes = [
            Note(path: "one/a.md", text: "[[a]]", modified: .distantPast),
            Note(path: "two/a.md", text: ""),
            Note(path: "one/b.md", text: "[[a]] [[a|again]] [[../two/a]]"),
            Note(path: "index.md", text: "[[a]] [[/one/a#heading]]")
        ]
        let index = NoteIndex(notes: notes)
        #expect(index.resolve("a", from: "index.md") == .ambiguous)
        #expect(index.resolve("a", from: "one/b.md") == .found("one/a.md"))
        #expect(index.resolve("../two/a.md", from: "one/b.md") == .found("two/a.md"))
        #expect(index.resolve("../../a", from: "one/b.md") == .missing)
        #expect(index.resolve("#heading", from: "one/a.md") == .found("one/a.md"))
        #expect(index.backlinks(to: "one/a.md").map(\.path) == ["one/b.md", "index.md"])
        #expect(index.backlinks(to: "two/a.md").map(\.path) == ["one/b.md"])
    }
    @Test func searchKeepsNewestFirstWithStableTiesAndWhitespaceQueries() {
        let notes = [Note(path: "b.md", text: "中文", modified: .distantPast),
                     Note(path: "new.md", text: "中文"),
                     Note(path: "a.md", text: "中文", modified: .distantPast)]
        #expect(NoteIndex.search(notes, query: " \n ").map(\.path) == ["new.md", "a.md", "b.md"])
        #expect(NoteIndex.search(notes, query: "中文").map(\.path) == ["new.md", "a.md", "b.md"])
    }
    @Test func testMetadataExcludesFencedAndInlineCode() {
        let metadata = MarkdownMetadata("# 标题\n#中文 #read/book\n[[笔记|别名]]\n`#ignored [[no]]`\n```swift\n#bad [[bad]]\n```\n## 第二节")
        #expect(metadata.links == [WikiLink(target: "笔记", label: "别名")])
        #expect(metadata.headings.map(\.title) == ["标题", "第二节"])
    }
    @Test func testFrontmatterIsExcluded() {
        #expect(MarkdownMetadata("---\ntags: [读书, 随想]\nlink: [[hidden]]\n---\n# 标题").links.isEmpty)
    }
    @Test func cachedNoteSummaryAndMetadataMatchContent() {
        let note = Note(path: "folder/a.md", text: "# Heading\n\nfirst\nsecond\nthird\nfourth\n[[target]]")
        #expect(note.title == "a" && note.folder == "folder")
        #expect(note.excerpt == "first second third fourth target")
        #expect(note.metadata.links.first?.target == "target")
        #expect(note.metadata.headings.first?.title == "Heading")
    }
    @Test func previewStripsMarkupAndFrontmatter() {
        let source = "---\ntitle: secret\n---\n# Title\n\n**正文** [[target|别名]] [网站](https://example.com)\n\n- [ ] 待办\n\n```swift\nignored()\n```"
        #expect(Note(path: "a.md", text: source).excerpt == "正文 别名 网站 待办")
    }
    @Test func testAmbiguousLinkDoesNotSelectArbitraryNote() {
        let notes = [Note(path: "one/a.md", text: ""), Note(path: "two/a.md", text: "")]
        #expect(NoteIndex.resolve("a", from: "index.md", notes: notes) == .ambiguous)
        #expect(NoteIndex.resolve("a#标题", from: "one/b.md", notes: notes) == .found("one/a.md"))
        #expect(NoteIndex.resolve("/two/a", from: "one/b.md", notes: notes) == .found("two/a.md"))
    }
    @Test func testBacklinksAndCaseInsensitiveAllTermSearch() {
        let notes = [Note(path: "a.md", text: "# 标签\nSwift 中文 #学习"), Note(path: "b.md", text: "[[a|引用]]")]
        #expect(NoteIndex.backlinks(to: "a.md", notes: notes).map(\.path) == ["b.md"])
        #expect(NoteIndex.search(notes, query: "swift 中文").map(\.path) == ["a.md"])
        #expect((NoteIndex.search(notes, query: "Swift missing").isEmpty))
    }
}
