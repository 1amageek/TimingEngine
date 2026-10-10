// swift-tools-version: 6.4
import PackageDescription

let logicDesignDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/LogicDesign.git",
    revision: "d13cebf1454e124a352f87186a22a70ef47d99a5"
)

let pdkKitDependency: Package.Dependency = .package(url: "https://github.com/1amageek/PDKKit.git",
    revision: "ada919723cad21aa40a33ee600fb558e5c3b7011"
)

let signoffToolSupportDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/SignoffToolSupport.git",
    exact: "26.812.0"
)

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    revision: "ae88104c556f5802819713ed741f5b2fffffc2d9"
)

let toolQualificationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/ToolQualification.git",
    revision: "7a69d2ba4e3c4c2262478312f9217de4293a7ab7"
)

let package = Package(
    name: "TimingEngine",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TimingCore", targets: ["TimingCore"]),
        .library(name: "STAEngine", targets: ["STAEngine"]),
        .library(name: "TimingPDKProfileInspection", targets: ["TimingPDKProfileInspection"]),
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
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation")
            ],
            exclude: ["DESIGN.md", "ParasiticReduction/DESIGN.md", "LibertyCodec/DESIGN.md"]
        ),
        .target(
            name: "TimingPDKProfileInspection",
            dependencies: ["TimingCore",
                .product(name: "PDKCore", package: "PDKKit"),
                .product(name: "PDKProfileAdmission", package: "PDKKit"),
                .product(name: "PDKSourceCapture", package: "PDKKit"),
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation")],
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "STAEngine",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                "TimingCore",
                "TimingPDKProfileInspection",
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit")
            ],
            exclude: ["DESIGN.md", "ProcessCorners/DESIGN.md", "PreparedExecution/DESIGN.md"]
        ),
        .target(
            name: "SignalIntegrityEngine",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                "TimingCore",
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "PDKCore", package: "PDKKit")
            ],
            exclude: ["DESIGN.md"]
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
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ]
        ),
        .testTarget(name: "LibertyCodecTests", dependencies: ["TimingCore"]),
        .testTarget(name: "TimingPDKProfileInspectionTests", dependencies: [
            "TimingCore", "TimingPDKProfileInspection", .product(name: "PDKCore", package: "PDKKit"),
            .product(name: "PDKProfileAdmission", package: "PDKKit"), .product(name: "PDKSourceCapture", package: "PDKKit"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")],
            path: "Tests/NativePreparedProof/Tests/TimingPDKProfileInspectionTests"),
        .testTarget(name: "STAPreparedExecutionTests", dependencies: [
            "STAEngine", "TimingCore", "TimingPDKProfileInspection", .product(name: "PDKCore", package: "PDKKit"),
            .product(name: "PDKProfileAdmission", package: "PDKKit"), .product(name: "PDKSourceCapture", package: "PDKKit"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")],
            path: "Tests/NativePreparedProof/Tests/STAPreparedExecutionTests"),
        .testTarget(
            name: "TimingEngineTests",
            dependencies: [
                "TimingCore",
                "STAEngine",
                "SignalIntegrityEngine",
                "TimingEngine",
                "OpenSTAOracleAdapter",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
                .product(name: "ToolQualification", package: "ToolQualification")
            ],
            resources: [
                .copy("../../Corpus"),
                .copy("../../Qualification"),
            ]
        ),
    ]
)
