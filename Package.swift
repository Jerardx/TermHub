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
        ),
        // Thin MCP (Model Context Protocol) stdio server that proxies tool calls
        // to the running app over its control socket. No dependencies.
        .executableTarget(
            name: "termhub-mcp",
            path: "Sources/TermHubMCP",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
