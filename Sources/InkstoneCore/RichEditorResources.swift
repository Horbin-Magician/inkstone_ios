import Foundation

public enum RichEditorResources {
    public static var readerURL: URL? {
        Bundle.module.url(forResource: "reader", withExtension: "html", subdirectory: "RichEditor")
    }
    public static var pageURL: URL? {
        Bundle.module.url(forResource: "editor", withExtension: "html", subdirectory: "RichEditor")
    }
}

/// Shared layout metrics used by the native reader and generated editor CSS.
public enum MarkdownAppearance {
    private static let values: [String: Double] = {
        guard let url = Bundle.module.url(forResource: "appearance", withExtension: "json", subdirectory: "RichEditor"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: Double].self, from: data) else {
            preconditionFailure("Missing Markdown appearance resource")
        }
        return values
    }()
    public static func metric(_ key: String) -> Double {
        guard let value = values[key] else { preconditionFailure("Unknown Markdown appearance metric: \(key)") }
        return value
    }
}
