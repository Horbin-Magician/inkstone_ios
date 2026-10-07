import SwiftUI

/// A native, offline subset renderer. Source is never rewritten during rendering.
struct MarkdownReader: View {
    let text: String
    var openLink: (String) -> Void
    var toggleTask: (Int) -> Void
    private struct Block: Identifiable { let id: Int; let kind: Kind; let text: String }
    private enum Kind { case heading(Int), paragraph, quote, code, task(Bool), bullet, divider }
    private var blocks: [Block] {
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = []
        var fence: String?, code: [String] = [], codeStart = 0
        var frontmatter = false
        for (index, line) in lines.enumerated() {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 && s == "---" { frontmatter = true; continue }
            if frontmatter { if s == "---" { frontmatter = false }; continue }
            if let marker = fence {
                if s.hasPrefix(marker) { result.append(Block(id: codeStart, kind: .code, text: code.joined(separator: "\n"))); code = []; fence = nil }
                else { code.append(line) }; continue
            }
            if s.hasPrefix("```") || s.hasPrefix("~~~") { fence = String(s.prefix(3)); codeStart = index; continue }
            guard !s.isEmpty else { continue }
            if s == "---" || s == "***" { result.append(Block(id: index, kind: .divider, text: "")); continue }
            let level = s.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), s.dropFirst(level).hasPrefix(" ") {
                result.append(Block(id: index, kind: .heading(level), text: String(s.dropFirst(level + 1)))); continue
            }
            if s.range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) != nil {
                result.append(Block(id: index, kind: .task(s.lowercased().hasPrefix("- [x]") || s.lowercased().hasPrefix("* [x]") || s.lowercased().hasPrefix("+ [x]")), text: String(s.dropFirst(6)))); continue
            }
            if s.hasPrefix(">") { result.append(Block(id: index, kind: .quote, text: String(s.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
                result.append(Block(id: index, kind: .bullet, text: String(s.dropFirst(2)))); continue
            }
            result.append(Block(id: index, kind: .paragraph, text: line))
        }
        if fence != nil { result.append(Block(id: codeStart, kind: .code, text: code.joined(separator: "\n"))) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level):
                    inline(block.text).font(.system(size: level == 1 ? 30 : level == 2 ? 23 : 19, weight: .semibold, design: .serif)).padding(.top, level == 1 ? 5 : 14)
                case .paragraph: inline(block.text).font(.body).lineSpacing(7)
                case .quote:
                    HStack(alignment: .top, spacing: 14) {
                        RoundedRectangle(cornerRadius: 2).fill(InkTheme.accent.opacity(0.6)).frame(width: 3)
                        inline(block.text).foregroundStyle(.secondary).padding(.vertical, 8)
                    }.fixedSize(horizontal: false, vertical: true)
                case .code:
                    ScrollView(.horizontal) { Text(block.text).font(.system(.callout, design: .monospaced)).padding(16) }
                        .background(InkTheme.background, in: RoundedRectangle(cornerRadius: 12))
                case .task(let checked):
                    HStack(alignment: .top, spacing: 10) {
                        Button { toggleTask(block.id) } label: { Image(systemName: checked ? "checkmark.circle.fill" : "circle").font(.title3).frame(minWidth: 32, minHeight: 32) }
                            .buttonStyle(.plain).foregroundStyle(InkTheme.accent).accessibilityLabel((checked ? "取消完成：" : "完成：") + block.text)
                        inline(block.text).strikethrough(checked).foregroundStyle(checked ? .secondary : .primary).padding(.top, 4)
                    }
                case .bullet: HStack(alignment: .top, spacing: 12) { Text("•").foregroundStyle(InkTheme.accent); inline(block.text) }
                case .divider: Divider().padding(.vertical, 8)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "inkstone", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value {
                openLink(target); return .handled
            }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .systemAction }
            return .discarded
        })
    }
    private func inline(_ source: String) -> Text {
        var result = source
        if let regex = try? NSRegularExpression(pattern: #"(?<!!)\[\[([^\]]+)\]\]"#) {
            let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result), let capture = Range(match.range(at: 1), in: source) else { continue }
                let parts = source[capture].split(separator: "|", maxSplits: 1).map(String.init)
                var url = URLComponents(); url.scheme = "inkstone"; url.host = "note"; url.queryItems = [URLQueryItem(name: "target", value: parts[0])]
                let label = (parts.count > 1 ? parts[1] : parts[0]).replacingOccurrences(of: "]", with: "\\]")
                result.replaceSubrange(range, with: "[\(label)](\(url.string ?? ""))")
            }
        }
        return Text((try? AttributedString(markdown: result, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source))
    }
}
