// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Envelope",
    platforms: [.macOS("13.0")],
    products: [
        .library(name: "Mail", targets: ["Mail"]),
        .library(name: "Emlx", targets: ["Emlx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/MimeFoundation", revision: "dcb6746729d20cf00c42ad6453b4637a075f7d0b")
    ],
    targets: [
        .target(name: "Mail"),
        .target(name: "Emlx", dependencies: [.product(name: "MimeFoundation", package: "MimeFoundation")]),
        .testTarget(name: "MailTests", dependencies: ["Mail", "Emlx"]),
        .testTarget(name: "EmlxTests", dependencies: ["Emlx"]),
    ]
)
