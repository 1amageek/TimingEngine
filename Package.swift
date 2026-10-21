// swift-tools-version: 6.4
import PackageDescription

let logicDesignDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/LogicDesign.git",
    revision: "9fbffcb1dfbf37517dfc05aa0f37f53c6a5e7659"
)

let pdkKitDependency: Package.Dependency = .package(url: "https://github.com/1amageek/PDKKit.git",
    revision: "82fddd548af704b3f0723eada8e5b09df2dad6e4"
)

let signoffToolSupportDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/SignoffToolSupport.git",
    revision: "e15ea6cd60ca1957297aafbba839e51a478d735e"
)

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    exact: "26.1021.1"
)

let toolQualificationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/ToolQualification.git",
    exact: "26.1021.1"
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
                .product(name: "LogicIR", package: "LogicDesign"),
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation")
            ],
            exclude: ["DESIGN.md", "ParasiticReduction/DESIGN.md", "LibertyCodec/DESIGN.md", "CanonicalModel/DESIGN.md", "PathConstraints/DESIGN.md", "NumericBounds/DESIGN.md", "SourceTransforms/DESIGN.md"]
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
                .product(name: "PDKCore", package: "PDKKit"),
                .product(name: "PDKDiscovery", package: "PDKKit")
            ],
            exclude: ["DESIGN.md", "NativeExecution/ClockPropagation/DESIGN.md", "NativeExecution/ConservativeCoupling/DESIGN.md", "NativeExecution/ConservativeCoupling/SourceFamilies/DESIGN.md", "NativeExecution/DESIGN.md", "NativeExecution/DistributedRC/DESIGN.md", "NativeExecution/PathAnalysis/DESIGN.md", "NativeExecution/PathAnalysis/SequentialExecution/DESIGN.md", "NativeExecution/PulsePropagation/DESIGN.md", "PreparedExecution/DESIGN.md", "ProcessCorners/DESIGN.md"]
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
            ], exclude: ["DESIGN.md", "ScalarReference/DESIGN.md"]
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
            ], exclude: ["DESIGN.md"]
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
            ], exclude: ["DESIGN.md"]
        ),
        .testTarget(name: "LibertyCodecTests", dependencies: ["TimingCore", .product(name: "CircuiteFoundation", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"), .product(name: "LogicIR", package: "LogicDesign"), .product(name: "LogicKernelCore", package: "LogicDesign")]),
        .testTarget(name: "TimingPDKProfileInspectionTests", dependencies: [
            "TimingCore", "TimingPDKProfileInspection", .product(name: "PDKCore", package: "PDKKit"),
            .product(name: "PDKProfileAdmission", package: "PDKKit"), .product(name: "PDKSourceCapture", package: "PDKKit"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")],
            path: "Tests/NativePreparedProof/Tests/TimingPDKProfileInspectionTests"),
        .testTarget(name: "STAPreparedExecutionTests", dependencies: [
            "STAEngine", "TimingCore", "TimingPDKProfileInspection", .product(name: "PDKCore", package: "PDKKit"),
            .product(name: "PDKDiscovery", package: "PDKKit"),
            .product(name: "PDKProfileAdmission", package: "PDKKit"), .product(name: "PDKSourceCapture", package: "PDKKit"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")],
            path: "Tests/NativePreparedProof/Tests/STAPreparedExecutionTests"),
        .testTarget(
            name: "TimingEngineTests",
            dependencies: [
                .product(name: "LogicIR", package: "LogicDesign"),
                "TimingCore",
                "STAEngine",
                "SignalIntegrityEngine",
                "TimingEngine",
                "OpenSTAOracleAdapter",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
                .product(name: "ToolQualification", package: "ToolQualification"),
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport")
            ],
            resources: [
                .copy("../../Corpus"),
                .copy("../../Qualification"),
            ]
        ),
    ]
)
