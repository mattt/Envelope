// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "MIMEComparison",
    dependencies: [.package(url: "https://github.com/migueldeicaza/MimeFoundation", revision: "dcb6746729d20cf00c42ad6453b4637a075f7d0b")],
    targets: [.executableTarget(name: "Compare", dependencies: [.product(name: "MimeFoundation", package: "MimeFoundation")])]
)
