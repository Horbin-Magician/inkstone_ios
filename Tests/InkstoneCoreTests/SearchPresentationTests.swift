import Foundation
import Testing
@testable import InkstoneCore

struct SearchPresentationTests {
    @Test func resultsKeepSearchOrderingAndHighlightUnicodeWithoutRescanningBodies() async throws {
        let notes = [
            Note(path: "中文.md", text: "标题命中但正文没有关键词"),
            Note(path: "emoji.md", text: String(repeating: "前文", count: 40) + "😀中文 cafe\u{301}\n中文"),
            Note(path: "absent.md", text: "absent")
        ]
        for query in ["中文", "cafe", "😀", "中文 cafe", "", "不存在"] {
            let results = await NoteIndex.searchResultsConcurrently(notes, query: query)
            #expect(results.map(\.note) == NoteIndex.search(notes, query: query))
            for result in results {
                for range in result.highlights {
                    let valid = try #require(Range(range, in: result.summary))
                    #expect(!result.summary[valid].isEmpty)
                }
            }
        }
        let matched = try #require(await NoteIndex.searchResultsConcurrently(notes, query: "😀中文").first)
        #expect(matched.summary.hasPrefix("…"))
        #expect(!matched.summary.contains("\n"))
        let range = try #require(matched.highlights.first.flatMap { Range($0, in: matched.summary) })
        #expect(matched.summary[range] == "😀中文")
    }
}
