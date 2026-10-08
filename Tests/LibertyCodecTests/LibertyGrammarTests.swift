import Testing
@testable import TimingCore

@Suite("Shared Liberty grammar")
struct LibertyGrammarTests {
    @Test("ordinary and accounted grammar preserve continuation and argument semantics",
          arguments: ["\n", "\r\n"])
    func continuations(_ newline: String) throws {
        let continuation = "\\" + newline
        let source = "/* header */" + newline + "library (sample) {" + newline
            + " values (\"1," + continuation + " 2\", " + continuation + "\" 3, 4 \" );" + newline
            + " attr : before " + continuation + " after;" + newline
            + " leaf (\" left \", \" right \" );" + newline + "}"
        var ordinaryGrammar = try LibertyGrammar(source: source)
        let ordinary = try #require(try ordinaryGrammar.parse().first)
        let resources = LibertyCodecTestResources()
        let storage = try LibertyParseStorage.make(resources: resources)
        var ownedGrammar = try LibertyGrammar(source: source, storage: storage, maximumNestingDepth: 1)
        let owned = try #require(try ownedGrammar.parse().first)
        for node in [ordinary, owned] {
            #expect(node.name == "library")
            #expect(node.arguments == ["sample"])
            #expect(node.sourceLine == 2)
            #expect(node.byteOffset == "/* header */".utf8.count + newline.utf8.count)
            let values = try #require(try node.child(named: "values"))
            #expect(values.arguments == ["1, 2", " 3, 4 "])
            #expect(try node.attribute(named: "attr") == "before after")
            let leaf = try #require(try node.child(named: "leaf"))
            #expect(leaf.arguments == ["left", " right "])
        }
        #expect(ordinary.children.map(\.line) == owned.children.map(\.line))
        #expect(ordinary.children.map(\.sourceLine) == owned.children.map(\.sourceLine))
        #expect(ordinary.children.map(\.byteOffset) == owned.children.map(\.byteOffset))
        #expect(resources.work > 0)
        #expect(resources.temporaryBytes > 0)
    }

    @Test("ordinary non-ASCII retains byte-to-scalar lexer behavior")
    func ordinaryNonASCII() throws {
        var grammar = try LibertyGrammar(source: "library (\"é\") { attr : \"ü\"; }")
        let node = try #require(try grammar.parse().first)
        #expect(node.arguments == ["Ã©"])
        #expect(try node.attribute(named: "attr") == "Ã¼")
    }

    @Test("physical origins remain distinct from legacy next-token diagnostics")
    func physicalOrigins() throws {
        let source = "library\n(x) {\n note : \"a\nb\";\n cell(C) {}\n}"
        var grammar = try LibertyGrammar(source: source)
        let library = try #require(try grammar.parse().first)
        #expect(library.line == 2)
        #expect(library.sourceLine == 1)
        let cell = try #require(try library.child(named: "cell"))
        #expect(cell.line == 4)
        #expect(cell.sourceLine == 5)
        #expect(cell.byteOffset == "library\n(x) {\n note : \"a\nb\";\n ".utf8.count)
        #expect(try library.attribute(named: "note") == "a\nb")
    }

    @Test("owned depth is explicit and rejects the next group before stack growth")
    func nestingAdmission() throws {
        let storage = try LibertyParseStorage.make(resources: LibertyCodecTestResources())
        #expect(throws: LibertySourceError.self) {
            _ = try LibertyGrammar(source: "library (x) {}", storage: storage)
        }
        #expect(throws: LibertySourceError.self) {
            _ = try LibertyGrammar(source: "library (x) {}", storage: storage, maximumNestingDepth: 0)
        }
        let source = "library(x) { cell(C) { pin(A) {} } }"
        var limited = try LibertyGrammar(source: source, storage: storage, maximumNestingDepth: 2)
        do {
            _ = try limited.parse()
            Issue.record("A third open group must fail the caller's depth bound.")
        } catch LibertySourceError.nestingLimit(let maximum) {
            #expect(maximum == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        var admitted = try LibertyGrammar(source: source, storage: storage, maximumNestingDepth: 3)
        let library = try #require(try admitted.parse().first)
        let cell = try #require(try library.child(named: "cell", storage: storage))
        #expect(try cell.child(named: "pin", storage: storage)?.arguments == ["A"])
    }

    @Test("many siblings mutate the popped frame without retaining a shared builder")
    func frameOwnership() throws {
        let storage = try LibertyParseStorage.make(resources: LibertyCodecTestResources())
        var grammar = try LibertyGrammar(source: "library(x) { a; b; c; d; e; nested() { f; g; } h; }",
            storage: storage, maximumNestingDepth: 2)
        let library = try #require(try grammar.parse().first)
        #expect(library.children.map(\.name) == ["a", "b", "c", "d", "e", "nested", "h"])
        #expect(try library.child(named: "nested", storage: storage)?.children.map(\.name) == ["f", "g"])
    }

    @Test("ordinary group parsing uses an explicit stack at substantial depth")
    func iterativeDepth() throws {
        let depth = 1_024
        let source = String(repeating: "group() {", count: depth) + "leaf;" + String(repeating: "}", count: depth)
        var grammar = try LibertyGrammar(source: source)
        var node = try #require(try grammar.parse().first)
        for _ in 1..<depth {
            #expect(node.children.count == 1)
            node = try #require(node.children.first)
        }
        #expect(node.children.count == 1)
        #expect(node.children.first?.name == "leaf")
    }
}
