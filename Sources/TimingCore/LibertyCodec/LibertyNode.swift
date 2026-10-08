/// Invocation-local syntax tree. Payload retention belongs to the parse owner.
struct LibertyNode: Sendable {
    let name: String
    let arguments: [String]
    let value: String?
    let children: [LibertyNode]
    let line: Int
    let sourceLine: Int
    let byteOffset: Int

    func child(named name: String, storage: LibertyParseStorage? = nil) throws -> LibertyNode? {
        for child in children {
            try storage?.step()
            if try Self.matches(child.name, name, storage: storage) { return child }
        }
        return nil
    }

    func attribute(named name: String, storage: LibertyParseStorage? = nil) throws -> String? {
        try child(named: name, storage: storage)?.value
    }

    private static func matches(_ lhs: String, _ rhs: String, storage: LibertyParseStorage?) throws -> Bool {
        if let storage {
            for _ in lhs.utf8 { try storage.step() }
            for _ in rhs.utf8 { try storage.step() }
            try storage.resources.check()
        }
        return lhs == rhs
    }
}
