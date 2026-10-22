// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BlessengerRTC",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CompanionRTC", targets: ["CompanionRTC"])],
    targets: [
        .binaryTarget(name: "WebRTC", url: "https://github.com/stasel/WebRTC/releases/download/155.0.0/WebRTC-M155.xcframework.zip",
                      checksum: "cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe"),
        .target(name: "CompanionRTC", dependencies: ["WebRTC"], publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("AudioToolbox")]),
    ]
)
