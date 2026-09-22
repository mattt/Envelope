// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Envelope",
    platforms: [.macOS("13.0")],
    products: [
        .library(name: "Mail", targets: ["Mail"]),
        .library(name: "Emlx", targets: ["Emlx"]),
    ],
    targets: [
        .target(name: "Mail"),
        .target(name: "MIME"),
        .testTarget(name: "MIMETests", dependencies: ["MIME", "Emlx"], resources: [.copy("Fixtures")]),
        .target(name: "Emlx", dependencies: ["MIME"]),
        .testTarget(name: "MailTests", dependencies: ["Mail", "Emlx"]),
        .testTarget(name: "EmlxTests", dependencies: ["Emlx", "MIME"]),
    ]
)
