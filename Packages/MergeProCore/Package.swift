// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MergeProCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MergeProCore", targets: ["MergeProCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .target(name: "MergeProCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "Yams", package: "Yams")]),
        .testTarget(name: "MergeProCoreTests", dependencies: ["MergeProCore"])
    ],
    swiftLanguageModes: [.v6]
)
