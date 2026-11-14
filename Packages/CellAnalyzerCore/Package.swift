// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CellAnalyzerCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CellAnalyzerCore", targets: ["CellAnalyzerCore"]),
    ],
    targets: [
        .target(name: "CellAnalyzerCore"),
        .testTarget(name: "CellAnalyzerCoreTests", dependencies: ["CellAnalyzerCore"]),
    ]
)
