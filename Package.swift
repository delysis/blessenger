// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "CallGemma",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "CallGemma", targets: ["CallGemma"])],
    dependencies: [
        .package(path: "Native/CompanionRTC"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "bd95867286539ca72c1f8f4253532143597483cf"),
        .package(url: "https://github.com/huggingface/swift-transformers.git",
                 revision: "e37cacea74498bba66002bb83ecafee3e4ab8884"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git",
                 revision: "de01c0ab8fd537bbd8216cea7f774275178501a2"),
    ],
    targets: [
        .systemLibrary(name: "CLiteRTLM"),
        .systemLibrary(name: "CEarshot"),
        .executableTarget(name: "CallGemma", dependencies: [
            "CLiteRTLM",
            "CEarshot",
            .product(name: "CompanionRTC", package: "CompanionRTC"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "Hub", package: "swift-transformers"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
        ], resources: [.process("Resources")], linkerSettings: [
            .linkedLibrary("CLiteRTLM_mac"),
            .unsafeFlags(["-L", root + "/Vendor", "-L", root + "/Vendor/earshot/macosx",
                          "-Xlinker", "-rpath", "-Xlinker", root + "/Vendor"]),
        ]),
        .testTarget(name: "CallGemmaTests", dependencies: ["CallGemma"]),
    ]
)
