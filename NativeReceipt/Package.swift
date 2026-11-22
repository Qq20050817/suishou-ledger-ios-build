// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReceiptCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "ReceiptCore", targets: ["ReceiptCore"])],
    targets: [
        .target(name: "ReceiptCore", resources: [.process("Resources")]),
        .testTarget(name: "ReceiptCoreTests", dependencies: ["ReceiptCore"])
    ]
)
