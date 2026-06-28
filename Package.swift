// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermHub",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "TermHub",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/TermHub",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
