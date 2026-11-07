import Foundation
import Testing
@testable import InkstoneCore

final class IndexTests {
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
