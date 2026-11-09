import Foundation

/// Internal image source shared by the native reader and the bundled editor.
/// The original wiki syntax remains in the Markdown document.
public struct ObsidianImageReference: Sendable {
    public static let prefix = "inkstone-embed:"
    public let target: String
    public let width: Int?
    public let height: Int?
    public let source: String

    public init?(_ content: String) {
        let parts = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts[0]
        guard !target.isEmpty, ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "svg"].contains((target as NSString).pathExtension.lowercased()) else { return nil }
        self.target = target
        let size = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let dimensions = size.split(separator: "x", omittingEmptySubsequences: false)
        let valid = size.range(of: #"^[1-9][0-9]{0,4}(x[1-9][0-9]{0,4})?$"#, options: .regularExpression) != nil
        width = valid ? Int(dimensions[0]) : nil
        height = valid && dimensions.count == 2 ? Int(dimensions[1]) : nil
        source = Self.prefix + (content.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    public init?(source: String) {
        guard source.hasPrefix(Self.prefix), let content = String(source.dropFirst(Self.prefix.count)).removingPercentEncoding else { return nil }
        self.init(content)
    }
}
