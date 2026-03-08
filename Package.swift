// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KytosWorkspace",
    dependencies: [
        .package(url: "https://github.com/yonaskolb/XcodeGen.git", from: "2.44.1"),
        .package(url: "https://github.com/holzschu/ios_system.git", from: "3.0.4"),
        // network_ios deferred — upstream checksum mismatch
        // .package(url: "https://github.com/holzschu/network_ios.git", from: "0.2.0"),
    ],
    targets: [
        .target(name: "Dummy", path: "Scripts/Dummy") // SPM usually requires at least one target
    ]
)
