// swift-tools-version: 5.9
//
// Universal TV Remote for Mac
// ---------------------------
// A native macOS menu-bar app that discovers smart TVs on the local network (Fire TV, Android/Google TV, Samsung Tizen, LG webOS, Roku) and controls them with a full-featured remote.
//
// Built as a Swift Package executable. `scripts/build-app.sh` wraps the built binary into a proper `Universal TV Remote.app` bundle (menu-bar apps need an Info.plist with LSUIElement, which a bare executable cannot carry).
//
import PackageDescription

let package = Package(
    name: "UniversalTVRemote",
    platforms: [
        // macOS 14 gives us MenuBarExtra window-style popovers and modern Network-framework APIs used by discovery and the TV drivers.
        .macOS(.v14)
    ],
    dependencies: [
        // Android TV / Google TV "Remote v2" protocol (TLS + protobuf). Vendored locally (MIT, by Roman Odyshew) because the upstream Package.swift declares iOS-only platforms, which silently drops the macOS deployment target to 10.10 and breaks the build. Our vendored copy only patches the manifest — see Vendor/AndroidTVRemoteControl.
        .package(path: "Vendor/AndroidTVRemoteControl")
    ],
    targets: [
        .executableTarget(
            name: "UniversalTVRemote",
            dependencies: [
                .product(name: "AndroidTVRemoteControl", package: "AndroidTVRemoteControl")
            ],
            path: "Sources/UniversalTVRemote"
        )
    ]
)
