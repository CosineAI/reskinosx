// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ElCapitanReskin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ElCapitanReskin",
            targets: ["ElCapitanReskin"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ElCapitanReskin",
            path: "Sources"
        )
    ]
)
