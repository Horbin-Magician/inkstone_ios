import Foundation
import Testing
@testable import InkstoneCore

struct MarkdownTests {
    @Test func paragraphsAndBreaks() {
        let blocks = MarkdownDocument("first\nsecond\n\nthird  \nfourth").blocks
        #expect(blocks.count == 2)
        #expect(blocks[0].inline.map(\.plainText).joined() == "first second")
        #expect(blocks[1].inline.map(\.plainText).joined() == "third\nfourth")
    }
    @Test func nestedListsAndTaskSourceLines() {
        let document = MarkdownDocument("---\ntitle: demo\n---\n\n3. first\n   - [ ] nested\n     continuation\n4. second")
        #expect(document.blocks.count == 1)
        let items = document.blocks[0].children
        guard case .item("3.", nil) = items[0].kind else { Issue.record("Ordered start was lost"); return }
        let task = items[0].children[1].children[0]
        guard case .item(_, false) = task.kind else { Issue.record("Nested task was lost"); return }
        #expect(task.line == 5)
        #expect(task.children[0].inline.map(\.plainText).joined() == "nested continuation")
        guard case .item("4.", nil) = items[1].kind else { Issue.record("Ordered numbering was lost"); return }
    }
    @Test func quotesAndSetextHeadings() {
        let document = MarkdownDocument("Title\n=====\n\n> first\n>\n> second\n>\n> > nested")
        #expect(document.headings.map(\.title) == ["Title"])
        #expect(document.headings.first?.line == 0)
        #expect(document.blocks[1].children.count == 3)
        guard case .quote = document.blocks[1].children[2].kind else { Issue.record("Nested quote was lost"); return }
    }
    @Test func tablesAndEscapedPipes() {
        let table = MarkdownDocument("| Left | Right |\n| :--- | ---: |\n| a\\|b | **bold** |").blocks[0]
        guard case .table = table.kind else { Issue.record("Table was not recognized"); return }
        #expect(table.children.count == 2)
        #expect(table.children[1].children[0].inline.map(\.plainText).joined() == "a|b")
        guard case .cell("right") = table.children[0].children[1].kind else { Issue.record("Alignment was lost"); return }
    }
    @Test func tableConversionPreservesNestedInlineLinksAndSourceLocations() {
        let document = MarkdownDocument("# Heading\n\n| Left | Right |\n| :--- | ---: |\n| [[target]] | **bold** |").blocks[1]
        let head = document.children[0], row = document.children[1]
        #expect(head.line == 2 && row.line == 4)
        #expect(row.children.map(\.id) == ["1.1.0", "1.1.1"])
        #expect(row.children[0].inline.map(\.plainText).joined() == "target")
        #expect(row.children[1].inline.contains { if case .strong = $0 { return true }; return false })
    }
    @Test func fencesAndIndentedCodeAreLiteral() {
        let document = MarkdownDocument("````swift\n```\n[[hidden]]\n````\n\n    [[also hidden]]\n\n[[visible|名称]] `[[inline]]`")
        #expect(document.links == [WikiLink(target: "visible", label: "名称")])
        guard case .code("swift") = document.blocks[0].kind else { Issue.record("Code language was lost"); return }
        #expect(document.blocks[0].text == "```\n[[hidden]]\n")
        guard case .code = document.blocks[1].kind else { Issue.record("Indented code was lost"); return }
    }
    @Test func frontmatterMustCloseAndSourceLinesSurviveCRLF() {
        #expect(!MarkdownDocument("---\nvisible text").blocks.isEmpty)
        let document = MarkdownDocument("---\r\ntitle: a\r\n...\r\n# 中文\r\n- [X] done")
        #expect(document.headings.first?.line == 3)
        #expect(document.blocks[1].children[0].line == 4)
    }
    @Test func inlineStructureAndReferenceLinks() {
        let document = MarkdownDocument("**bold *italic*** ~~deleted~~ [site][ref] ![alt](https://example.com/a.png)\n\n[ref]: https://example.com")
        let nodes = document.blocks[0].inline
        #expect(nodes.contains { if case .strong = $0 { return true }; return false })
        #expect(nodes.contains { if case .strike = $0 { return true }; return false })
        #expect(nodes.contains { if case .link("https://example.com", _) = $0 { return true }; return false })
        #expect(nodes.contains { if case .image("https://example.com/a.png", "alt") = $0 { return true }; return false })
        #expect(document.blocks.count == 1)
    }
    @Test func togglingTaskPreservesSourceAndIgnoresCode() {
        let source = "---\r\ntitle: test\r\n---\r\n> - [ ] 中文\r\n\r\n```\r\n- [ ] literal\r\n```\r\n"
        #expect(MarkdownDocument(source).blocks[0].children[0].children[0].line == 3)
        let changed = MarkdownDocument.togglingTask(in: source, at: 3)
        #expect(changed == source.replacingOccurrences(of: "> - [ ]", with: "> - [x]"))
        #expect(MarkdownDocument.togglingTask(in: changed, at: 3) == source)
        #expect(MarkdownDocument.togglingTask(in: source, at: 6) == source)
        #expect(MarkdownDocument(source).togglingTask(at: 3) == changed)
        #expect(MarkdownDocument(source).togglingTask(at: 6) == source)
        let task = MarkdownDocument(source).blocks[0].children[0].children[0]
        #expect(task.children[0].inline.map(\.plainText).joined() == "中文")
        let escaped = #"> - \[ ] literal"#
        #expect(MarkdownDocument.togglingTask(in: escaped, at: 0) == escaped)
    }
    @Test func relativeNoteLinksResolveWithinLibrary() {
        let notes = [Note(path: "a.md", text: ""), Note(path: "folder/b.md", text: "")]
        #expect(NoteIndex.resolve("../a.md", from: "folder/b.md", notes: notes) == .found("a.md"))
        #expect(NoteIndex.resolve("./b.md", from: "folder/c.md", notes: notes) == .found("folder/b.md"))
        #expect(NoteIndex.resolve("../../a.md", from: "folder/b.md", notes: notes) == .missing)
    }
    @Test func wikiEdgeCasesDoNotCrashOrIndexEmbeds() {
        let document = MarkdownDocument("[[|]] ![[embed]] [[目录/笔记|名称]]")
        #expect(document.links == [WikiLink(target: "目录/笔记", label: "名称")])
    }
}

struct ObsidianImageTests {
    @Test func parsesImagesAndSizesWithoutIndexingAsNotes() {
        let document = MarkdownDocument("前 ![[附件/中文 photo.png| 320x200 ]] 后 ![[a.jpg]] `![[code.png]]` ![[note]]")
        let images = document.blocks[0].inline.compactMap { node -> ObsidianImageReference? in
            guard case .image(let source, _) = node else { return nil }
            return ObsidianImageReference(source: source)
        }
        #expect(images.count == 2)
        #expect(images.first?.target == "附件/中文 photo.png")
        #expect(images.first?.width == 320)
        #expect(images.first?.height == 200)
        #expect(document.links.isEmpty)
    }
    @Test func rootedImagesFromNestedNotesLoadActualPreview() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault")
        let vault = try Vault(root: root, recovery: base.appendingPathComponent("recovery"))
        let target = "00 默认收集箱/附件/Pasted image 20231215124340.png"
        let file = root.appendingPathComponent(target)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imageFixture(width: 80, height: 40).write(to: file)
        let note = "01 知识库/2 自然科学/23 大气科学/PALM 模式.md"
        // A same-path file under the note directory must not override a rooted reference.
        let decoy = root.appendingPathComponent((note as NSString).deletingLastPathComponent).appendingPathComponent(target)
        try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: decoy)
        let encoded = try #require(("/" + target).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        for markdown in ["![[/" + target + "]]", "![photo](" + encoded + ")"] {
            let document = MarkdownDocument(markdown)
            let node = try #require(document.blocks.first?.inline.first(where: { if case .image = $0 { return true }; return false }))
            guard case .image(let source, _) = node else { Issue.record("Image did not parse"); continue }
            let preview = try await ImagePreviewPipeline().preview(source: source,
                context: ImageResourceContext(library: "test", notePath: note, generation: "0")) {
                    try await vault.attachment($0, from: note)
                }
            #expect(preview.image.width == 80 && preview.image.height == 40)
        }
        for target in ["/../outside.png", "//server/image.png", "/.hidden/image.png"] {
            let embed = try #require(ObsidianImageReference(target)?.source)
            for source in [target, embed] {
                await #expect(throws: (any Error).self) { try await vault.attachment(source, from: note) }
            }
        }
    }
    @Test func resolvesVaultImagesAndRejectsAmbiguousNames() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("vault")
        let vault = try Vault(root: root, recovery: base.appendingPathComponent("recovery"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: root.appendingPathComponent("assets/中文 # photo.png"))
        for target in ["中文 # photo.png", "assets/中文 # photo.png"] {
            let source = try #require(ObsidianImageReference(target)?.source)
            let actual = try await vault.attachment(source, from: "notes/deep/test.md")
            #expect(actual == bytes)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other"), withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent("other/中文 # photo.png"))
        let source = try #require(ObsidianImageReference("中文 # photo.png")?.source)
        await #expect(throws: (any Error).self) { try await vault.attachment(source, from: "notes/test.md") }
        let unsafe = try #require(ObsidianImageReference("../../outside.png")?.source)
        await #expect(throws: (any Error).self) { try await vault.attachment(unsafe, from: "test.md") }
    }
}

struct MarkdownExtensionTests {
    @Test func mathProtectsTeXAndRetainsTaskLineNumbers() {
        let source = "前 $x_1 + \\alpha$ 后\r\n\r\n$$\r\n\\frac{a}{b}\r\n$$\r\n\r\n- [ ] task"
        let document = MarkdownDocument(source)
        #expect(document.blocks[0].inline.contains { if case .math("x_1 + \\alpha", false) = $0 { return true }; return false })
        #expect(document.blocks[1].inline.contains { if case .math("\\frac{a}{b}", true) = $0 { return true }; return false })
        #expect(document.togglingTask(at: 6) == source.replacingOccurrences(of: "[ ]", with: "[x]"))
    }
    @Test func mathIgnoresCodeEscapesCurrencyAndMetadata() {
        for source in [#"\$x$"#, "$20 and $30", "`$x$`", "```tex\n$x$\n```", "$$\nnot closed", "$ x $", "---\na: $x$\n---\ntext"] {
            let document = MarkdownDocument(source)
            #expect(!document.blocks.flatMap(\.inline).contains { if case .math = $0 { return true }; return false }, "\(source)")
        }
    }
    @Test func mathPreservesEscapedDollarAndDoesNotChangeWikiTargets() {
        let document = MarkdownDocument(#"中文 $a\$b$ 和 $x_2$ [[价格$x$|别名]]"#)
        let formulas = document.blocks[0].inline.compactMap { node -> String? in
            if case .math(let value, _) = node { return value }; return nil
        }
        #expect(formulas == [#"a\$b"#, "x_2"])
        #expect(document.links == [WikiLink(target: "价格$x$", label: "别名")])
    }
    @Test func calloutHasTitleFoldAndNestedContent() {
        let source = "> [!WARNING]- 注意\n> 内容\n>\n> > [!TIP]+\n> > 提示\n>\n> - [ ] task"
        let document = MarkdownDocument(source)
        #expect(document.blocks[0].callout?.type == "warning")
        #expect(document.blocks[0].callout?.title == "注意")
        #expect(document.blocks[0].callout?.expanded == false)
        #expect(document.blocks[0].children[0].inline.map(\.plainText).joined() == "内容")
        #expect(document.blocks[0].children[1].callout?.type == "tip")
        #expect(document.togglingTask(at: 6).contains("[x] task"))
    }
}
