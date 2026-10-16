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
        ),
        .library(
            name: "Mail",
            targets: ["Mail"]
        ),
        .library(
            name: "Emlx",
            targets: ["Emlx"]
        ),
    ],
    targets: [
        .target(
            name: "Mail",
            dependencies: []
        ),
        .target(
            name: "MIME",
            dependencies: []
        ),
        .target(
            name: "Emlx",
            dependencies: ["MIME"]
        ),
        .target(
            name: "Envelope",
            dependencies: ["Mail", "Emlx"]
        ),
        .testTarget(
            name: "MailTests",
            dependencies: ["Mail", "Emlx", "Envelope"]
        ),
        .testTarget(
            name: "EmlxTests",
            dependencies: ["Emlx", "MIME"]
        ),
        .testTarget(
            name: "MIMETests",
            dependencies: ["MIME", "Emlx"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
