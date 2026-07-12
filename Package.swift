// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "TimingEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TimingCore", targets: ["TimingCore"]),
        .library(name: "STAEngine", targets: ["STAEngine"]),
        .library(name: "SignalIntegrityEngine", targets: ["SignalIntegrityEngine"]),
        .library(name: "TimingEngine", targets: ["TimingEngine"]),
        .executable(name: "timingengine", targets: ["TimingCLI"]),
    ],
    dependencies: [
        .package(path: "../XcircuitePackage"),
        .package(path: "../LogicDesign"),
        .package(path: "../PDKKit"),
        .package(path: "../SignoffToolSupport"),
    ],
    targets: [
        .target(
            name: "TimingCore",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage")]
        ),
        .target(
            name: "STAEngine",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "TimingCore", .product(name: "LogicIR", package: "LogicDesign"), .product(name: "PDKCore", package: "PDKKit")]
        ),
        .target(
            name: "SignalIntegrityEngine",
            dependencies: [.product(name: "XcircuitePackage", package: "XcircuitePackage"), "TimingCore", .product(name: "LogicIR", package: "LogicDesign"), .product(name: "PDKCore", package: "PDKKit")]
        ),
        .target(
            name: "TimingEngine",
            dependencies: [
                "TimingCore",
                "STAEngine",
                "SignalIntegrityEngine",
                .product(name: "XcircuitePackage", package: "XcircuitePackage"),
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ]
        ),
        .executableTarget(
            name: "TimingCLI",
            dependencies: [
                "TimingCore",
                "STAEngine",
                "SignalIntegrityEngine",
                "TimingEngine",
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit"),
                .product(name: "XcircuitePackage", package: "XcircuitePackage"),
            ]
        ),
        .testTarget(
            name: "TimingEngineTests",
            dependencies: ["TimingCore", "STAEngine", "SignalIntegrityEngine", "TimingEngine"]
        ),
    ]
)
