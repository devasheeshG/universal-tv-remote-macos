// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AndroidTVRemoteControl",
    platforms: [.iOS(.v13), .macOS(.v14)],
    products: [
        .library(
            name: "AndroidTVRemoteControl",
            targets: ["AndroidTVRemoteControl"]),
    ],
    targets: [
        .target(
            name: "AndroidTVRemoteControl"),
    ],
    swiftLanguageVersions: [.v4, .v4_2, .v5]
)
