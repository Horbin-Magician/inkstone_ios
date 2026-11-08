import Foundation

public enum RichEditorResources {
    public static var pageURL: URL? {
        Bundle.module.url(forResource: "editor", withExtension: "html", subdirectory: "RichEditor")
    }
}
