import TimingCore

extension PreparedSTAExecution {
    /// Verifies retained semantic identity; no request digest substitutes for this comparison.
    public func requireDesignBinding(to expected: TimingDesign) throws(STADesignBindingError) {
        func step() throws(STADesignBindingError) {
            try designBindingBudget.charge(1)
            do { try Task.checkCancellation(); try sourceResources.check(); try sourceResources.chargeWork(1) }
            catch { throw .resource(error) }
        }
        func equal(_ lhs: String, _ rhs: String) throws(STADesignBindingError) -> Bool {
            var a = lhs.utf8.makeIterator(), b = rhs.utf8.makeIterator()
            while true {
                try step()
                let x = a.next(), y = b.next()
                if x != y { return false }
                if x == nil { return true }
            }
        }
        try step()
        guard design.schemaVersion == expected.schemaVersion,
              try equal(design.topDesignName,expected.topDesignName) else { throw .mismatch("top or schema") }
        guard design.ports.count == expected.ports.count, design.instances.count == expected.instances.count,
              design.nets.count == expected.nets.count else { throw .mismatch("named table cardinality") }
        for (index,port) in design.ports.enumerated() {
            try step()
            for earlier in 0..<index {
                if try equal(port.name,design.ports[earlier].name) { throw .mismatch("duplicate port") }
            }
            var match: TimingDesign.Port?
            for candidate in expected.ports {
                if try equal(port.name,candidate.name) {
                    guard match == nil else { throw .mismatch("duplicate expected port") }; match = candidate
                }
            }
            guard let match, port.direction == match.direction, try equal(port.netName,match.netName) else { throw .mismatch("port binding") }
            switch (port.clock,match.clock) {
            case (nil,nil): break
            case (.some(let a),.some(let b)):
                guard try equal(a,b) else { throw .mismatch("port clock") }
            default: throw .mismatch("port clock")
            }
        }
        for (index,instance) in design.instances.enumerated() {
            try step()
            for earlier in 0..<index {
                if try equal(instance.name,design.instances[earlier].name) { throw .mismatch("duplicate instance") }
            }
            var match: TimingDesign.Instance?
            for candidate in expected.instances {
                if try equal(instance.name,candidate.name) {
                    guard match == nil else { throw .mismatch("duplicate expected instance") }; match = candidate
                }
            }
            guard let match, try equal(instance.cell,match.cell), instance.connections.count == match.connections.count else {
                throw .mismatch("instance master or connection cardinality")
            }
            for (pin,net) in instance.connections {
                // Charge the exact key bytes before the dictionary's bounded key lookup.
                for _ in pin.utf8 { try step() }
                try step()
                guard let bound = match.connections[pin], try equal(net,bound) else { throw .mismatch("instance pin connection") }
            }
        }
        for (index,net) in design.nets.enumerated() {
            try step()
            for earlier in 0..<index {
                if try equal(net.name,design.nets[earlier].name) { throw .mismatch("duplicate net") }
            }
            var match: TimingDesign.Net?
            for candidate in expected.nets {
                if try equal(net.name,candidate.name) {
                    guard match == nil else { throw .mismatch("duplicate expected net") }; match = candidate
                }
            }
            guard let match, net.capacitance.isFinite, match.capacitance.isFinite,
                  net.capacitance == match.capacitance, net.constant == match.constant else { throw .mismatch("net metadata") }
        }
    }
}
