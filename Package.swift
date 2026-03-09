// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KytosWorkspace",
    dependencies: [
        .package(url: "https://github.com/yonaskolb/XcodeGen.git", from: "2.44.1"),
    ],
    targets: [
        .target(name: "Dummy", path: "Scripts/Dummy") // SPM usually requires at least one target
    ]
)
