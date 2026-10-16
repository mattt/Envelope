// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Envelope",
    platforms: [
        .macOS("13.0")
    ],
    products: [
        .library(
            name: "Envelope",
            targets: ["Envelope"]
        )
    ],
    targets: [
        .target(
            name: "Envelope",
            dependencies: []
        ),
        .testTarget(
            name: "EnvelopeTests",
            dependencies: ["Envelope"],
            resources: [.copy("MIME/Fixtures")]
        ),
    ]
)
