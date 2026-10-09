// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "TimingNativePreparedProof", platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../.."), .package(path: "../../../PDKKit"), .package(path: "../../../CircuiteFoundation")],
    targets: [
        .testTarget(name: "STAProcessCornerRegressionTests", dependencies: [
            .product(name: "STAEngine", package: "TimingEngine"), .product(name: "TimingCore", package: "TimingEngine"),
            .product(name: "PDKCore", package: "PDKKit"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")], resources: [.copy("Corpus")]),
        .testTarget(name: "TimingPDKProfileInspectionTests", dependencies: [
            .product(name: "TimingCore", package: "TimingEngine"),
            .product(name: "TimingPDKProfileInspection", package: "TimingEngine"),
            .product(name: "PDKCore", package: "PDKKit"), .product(name: "PDKProfileAdmission", package: "PDKKit"),
            .product(name: "PDKSourceCapture", package: "PDKKit"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")]),
        .testTarget(name: "STAPreparedExecutionTests", dependencies: [
            .product(name: "STAEngine", package: "TimingEngine"), .product(name: "TimingCore", package: "TimingEngine"),
            .product(name: "TimingPDKProfileInspection", package: "TimingEngine"),
            .product(name: "PDKCore", package: "PDKKit"), .product(name: "PDKProfileAdmission", package: "PDKKit"),
            .product(name: "PDKSourceCapture", package: "PDKKit"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")]),
    ])
