// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhysioAIFaultEvidenceKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "PhysioAIFaultEvidenceKit",
            targets: ["PhysioAIFaultEvidenceKit"],
        ),
    ],
    targets: [
        .target(
            name: "PhysioAIFaultEvidenceKit",
            resources: [.process("Resources")],
        ),
        .testTarget(
            name: "PhysioAIFaultEvidenceKitTests",
            dependencies: ["PhysioAIFaultEvidenceKit"],
        ),
    ],
)
