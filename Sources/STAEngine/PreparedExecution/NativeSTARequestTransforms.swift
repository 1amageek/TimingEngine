import CircuiteFoundation
import TimingCore

/// Preserve the exact existing artifact order without temporary concatenation
/// arrays in the strict path. Public detached getters remain caller-managed.
internal enum NativeSTARequestTransforms {
    static func bindings(_ request: STARequest, storage: NativeSTATransformStorage) throws -> [TimingArtifactBinding] {
        if storage.budget.transformResources == nil { return request.artifactBindings }
        let base = request.libraries.count.addingReportingOverflow(3)
        let total = base.partialValue.addingReportingOverflow(request.parasitics == nil ? 0 : 1)
        guard !base.overflow, !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        try storage.reserve(TimingArtifactBinding.self, capacity: total.partialValue)
        var values: [TimingArtifactBinding] = []; values.reserveCapacity(total.partialValue)
        try storage.budget.chargeScheduledWork(1); values.append(request.design)
        for reference in request.libraries { try storage.budget.chargeScheduledWork(1); values.append(reference.artifact) }
        try storage.budget.chargeScheduledWork(2); values.append(request.constraints); values.append(request.pdkManifest)
        if let reference = request.parasitics { try storage.budget.chargeScheduledWork(1); values.append(reference) }
        return values
    }

    static func references(_ request: STARequest, storage: NativeSTATransformStorage) throws -> [ArtifactReference] {
        try storage.map(bindings(request, storage: storage), \.reference)
    }
}
