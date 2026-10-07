// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "InkstoneMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "InkstoneCore", targets: ["InkstoneCore"]), .executable(name: "InkstonePreview", targets: ["InkstonePreview"])],
    targets: [
        .target(name: "InkstoneCore"),
        .executableTarget(name: "InkstonePreview", dependencies: ["InkstoneCore"], path: "App", exclude: ["Assets.xcassets", "Info.plist"]),
        .testTarget(name: "InkstoneCoreTests", dependencies: ["InkstoneCore"])
    ],
    swiftLanguageModes: [.v5]
)
