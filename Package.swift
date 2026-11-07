// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "InkstoneMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "InkstoneCore", targets: ["InkstoneCore"]), .executable(name: "InkstonePreview", targets: ["InkstonePreview"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3")],
    targets: [
        .target(name: "InkstoneCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")], resources: [.copy("Resources/ThirdPartyNotices.txt")]),
        .executableTarget(name: "InkstonePreview", dependencies: ["InkstoneCore"], path: "App", exclude: ["Assets.xcassets", "Info.plist", "Inkstone.entitlements"]),
        .testTarget(name: "InkstoneCoreTests", dependencies: ["InkstoneCore"])
    ],
    swiftLanguageModes: [.v5]
)
