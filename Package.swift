// swift-tools-version: 6.3
import PackageDescription
import Foundation

let workspaceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let logicDesignDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("LogicDesign/Package.swift").path
)
    ? .package(path: "../LogicDesign")
    : .package(
        url: "https://github.com/1amageek/LogicDesign.git",
        revision: "cc39c974bf14624e6ce29fd8722620385fde0762"
    )

let pdkKitDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("PDKKit/Package.swift").path
)
    ? .package(path: "../PDKKit")
    : .package(
        url: "https://github.com/1amageek/PDKKit.git",
        revision: "29cc9f6f8d24562a7dcb5fd43d8dc6437e695c21"
    )

let signoffToolSupportDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("SignoffToolSupport/Package.swift").path
)
    ? .package(path: "../SignoffToolSupport")
    : .package(
        url: "https://github.com/1amageek/SignoffToolSupport.git",
        revision: "7bfd1864edd147c59a1dc79e58f297120d165323"
    )

let circuiteFoundationDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("CircuiteFoundation/Package.swift").path
)
    ? .package(path: "../CircuiteFoundation")
    : .package(
        url: "https://github.com/1amageek/CircuiteFoundation.git",
        revision: "2ec6ee13a89ac6885be3c26b41a9ee0ef89948ac"
    )

let toolQualificationDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("ToolQualification/Package.swift").path
)
    ? .package(path: "../ToolQualification")
    : .package(
        url: "https://github.com/1amageek/ToolQualification.git",
        revision: "1856a1bc5660febbe2f0358d3e5e0262e496b3d3"
    )

let package = Package(
    name: "TimingEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TimingCore", targets: ["TimingCore"]),
        .library(name: "STAEngine", targets: ["STAEngine"]),
        .library(name: "SignalIntegrityEngine", targets: ["SignalIntegrityEngine"]),
        .library(name: "TimingEngine", targets: ["TimingEngine"]),
        .executable(name: "timingengine", targets: ["TimingCLI"]),
        .executable(name: "opensta-oracle-adapter", targets: ["OpenSTAOracleAdapter"]),
    ],
    dependencies: [
        logicDesignDependency,
        pdkKitDependency,
        signoffToolSupportDependency,
        circuiteFoundationDependency,
        toolQualificationDependency,
    ],
    targets: [
        .target(
            name: "TimingCore",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "ToolQualification", package: "ToolQualification")
            ]
        ),
        .target(
            name: "STAEngine",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                "TimingCore",
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit")
            ]
        ),
        .target(
            name: "SignalIntegrityEngine",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                "TimingCore",
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit")
            ]
        ),
        .target(
            name: "TimingEngine",
            dependencies: [
                "TimingCore",
                "STAEngine",
                "SignalIntegrityEngine",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
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
            ]
        ),
        .executableTarget(
            name: "OpenSTAOracleAdapter",
            dependencies: [
                "STAEngine",
                "TimingCore",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ]
        ),
        .testTarget(
            name: "TimingEngineTests",
            dependencies: [
                "TimingCore",
                "STAEngine",
                "SignalIntegrityEngine",
                "TimingEngine",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "ToolQualification", package: "ToolQualification")
            ],
            resources: [
                .copy("../../Corpus"),
                .copy("../../Qualification"),
            ]
        ),
    ]
)
