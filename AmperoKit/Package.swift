// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AmperoKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AmperoKit", targets: ["AmperoKit"]),
    ],
    targets: [
        .target(
            name: "AmperoKit",
            resources: [
                .copy("Resources/param-map.json"),
                .copy("Resources/model-lists.json"),
            ]
        ),
        .testTarget(
            name: "AmperoKitTests",
            dependencies: ["AmperoKit"]
        ),
    ]
)
