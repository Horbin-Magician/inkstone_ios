import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@main
struct InkstoneApp: App {
    @StateObject private var store = LibraryStore()
    var body: some Scene {
        WindowGroup { LibraryView().environmentObject(store).tint(InkTheme.accent).task { await store.start(); await store.importSharedInbox() } }
    }
}
enum InkTheme {
    static let accent: Color = {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.45, green: 0.75, blue: 0.82, alpha: 1)
                : UIColor(red: 0.14, green: 0.46, blue: 0.54, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.45, green: 0.75, blue: 0.82, alpha: 1)
                : NSColor(red: 0.14, green: 0.46, blue: 0.54, alpha: 1)
        })
        #endif
    }()
    static var background: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    static var surface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}
