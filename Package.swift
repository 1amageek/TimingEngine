// swift-tools-version: 6.3
import PackageDescription
import Foundation

let workspaceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let xcircuitePackageDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("XcircuitePackage/Package.swift").path
)
    ? .package(path: "../XcircuitePackage")
    : .package(url: "https://github.com/1amageek/XcircuitePackage.git", revision: "55b757efa6c906c30e829c2ca5b67566856dec6b")

let logicDesignDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("LogicDesign/Package.swift").path
)
    ? .package(path: "../LogicDesign")
    : .package(url: "https://github.com/1amageek/LogicDesign.git", revision: "5daff0e5525f7bd03dacb2c90917cfa1c8d905f4")

let pdkKitDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("PDKKit/Package.swift").path
)
    ? .package(path: "../PDKKit")
    : .package(url: "https://github.com/1amageek/PDKKit.git", revision: "dde2fa2e3463e4a750e670829c0a9cb1a0661da8")

let signoffToolSupportDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("SignoffToolSupport/Package.swift").path
)
    ? .package(path: "../SignoffToolSupport")
    : .package(url: "https://github.com/1amageek/SignoffToolSupport.git", revision: "777adc160544043a803c986f4822e6ab06b4dfa8")

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
        xcircuitePackageDependency,
        logicDesignDependency,
        pdkKitDependency,
        signoffToolSupportDependency,
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
