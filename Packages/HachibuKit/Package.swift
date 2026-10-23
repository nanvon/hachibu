// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HachibuKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BatteryCore", targets: ["BatteryCore"]),
        .library(name: "HistoryStore", targets: ["HistoryStore"]),
        .library(name: "FeatureUI", targets: ["FeatureUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "BatteryCore"),
        .target(
            name: "HistoryStore",
            dependencies: [
                "BatteryCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "FeatureUI",
            dependencies: ["BatteryCore", "HistoryStore"],
            resources: [.process("Resources")]
        ),
        // 输出本机诊断数据，用于录制 Tests/Fixtures。不进入 App。
        .executableTarget(
            name: "hachibu-diagnostics",
            dependencies: ["BatteryCore"]
        ),
        .testTarget(
            name: "BatteryCoreTests",
            dependencies: ["BatteryCore"]
        ),
        .testTarget(
            name: "HistoryStoreTests",
            dependencies: ["HistoryStore", "BatteryCore"]
        ),
        .testTarget(
            name: "FeatureUITests",
            dependencies: ["FeatureUI", "HistoryStore", "BatteryCore"]
        ),
    ]
)
