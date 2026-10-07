import Foundation
import Testing
@testable import InkstoneCore

final class IndexTests {
    @Test func testMetadataExcludesFencedAndInlineCode() {
        let metadata = MarkdownMetadata("# 标题\n#中文 #read/book\n[[笔记|别名]]\n`#ignored [[no]]`\n```swift\n#bad [[bad]]\n```\n## 第二节")
        #expect(metadata.tags == ["read/book", "中文"])
        #expect(metadata.links == [WikiLink(target: "笔记", label: "别名")])
        #expect(metadata.headings.map(\.title) == ["标题", "第二节"])
    }
    @Test func testInlineFrontmatterTags() {
        #expect(MarkdownMetadata("---\ntags: [读书, 随想]\n---\n# 标题").tags == ["读书", "随想"])
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
        #expect(NoteIndex.search(notes, query: "swift 中文", tag: "学习").map(\.path) == ["a.md"])
        #expect((NoteIndex.search(notes, query: "Swift missing").isEmpty))
    }
}
