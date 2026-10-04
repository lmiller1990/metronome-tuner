// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViolinPracticeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ViolinPracticeCore", targets: ["ViolinPracticeCore"]),
    ],
    targets: [
        .target(name: "ViolinPracticeCore"),
        .testTarget(name: "ViolinPracticeCoreTests", dependencies: ["ViolinPracticeCore"]),
    ]
)
