import Foundation
import Testing

struct STAProcessCLIFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sta-process-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try TimingTestResources.corpusRoot.appending(path: "fixtures/simple")
        for name in ["design.json", "library.lib", "constraints.sdc"] {
            try FileManager.default.copyItem(at: source.appending(path: name), to: root.appending(path: name))
        }
        try STATestProcessFactory.data(library: Data(contentsOf: root.appending(path: "library.lib")))
            .write(to: root.appending(path: "pdk.json"))
    }

    var arguments: [String] {
        ["run-sta", "--workspace-root", root.path, "--design", root.appending(path: "design.json").path,
         "--library", root.appending(path: "library.lib").path,
         "--constraints", root.appending(path: "constraints.sdc").path,
         "--pdk-manifest", root.appending(path: "pdk.json").path,
         "--process", "test", "--pdk-version", "1", "--corner", "typical", "--top", "top",
         "--run-id", "sta-cli-process", "--out", root.appending(path: "out").path]
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("STA CLI fixture cleanup failed: \(error.localizedDescription)") }
    }
}
