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
        .package(url: "https://github.com/1amageek/XcircuitePackage.git", revision: "55b757efa6c906c30e829c2ca5b67566856dec6b"),
        .package(url: "https://github.com/1amageek/LogicDesign.git", revision: "6c4b1cc197d81520bff58ba57b4a97e2bd6bb91a"),
        .package(url: "https://github.com/1amageek/PDKKit.git", revision: "07eae4cb9feaedc70a536b5fe02ab9021d26a869"),
        .package(url: "https://github.com/1amageek/SignoffToolSupport.git", revision: "777adc160544043a803c986f4822e6ab06b4dfa8"),
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
