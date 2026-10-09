import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import TimingCore

public struct STAEffectiveConfiguration: Sendable, Hashable, Codable {
    public let encodingVersion: Int
    public let algorithmIdentity: String
    public let reductionIdentity: String
    public let modeIDs: [String]
    public let cornerIDs: [String]
    public let analysisKinds: [STAAnalysisKind]
    public let maxPaths: Int
    public let requiresPostLayoutInputs: Bool
    public let variation: STAVariation
    public let inputSlews: [String: Double]
    public let defaultOutputLoads: [String: Double]
    public let characterizationPolicy: STACharacterizationPolicy
    public let characterizationBindings: [STACharacterizationBinding]
    public let digest: ContentDigest
    internal init(request: STARequest, modes: [String], constraints: [String: TimingConstraintSet]) throws {
        encodingVersion = 1; algorithmIdentity = "timing.sta.3.0.0"; reductionIdentity = "equipotential-cap-load.v1"
        modeIDs = modes; cornerIDs = request.requestedCornerIDs; analysisKinds = request.analysisKinds
        maxPaths = request.maxPaths; requiresPostLayoutInputs = request.requiresPostLayoutInputs; variation = request.variation
        inputSlews = constraints.mapValues(\.defaultInputSlew); defaultOutputLoads = constraints.mapValues(\.defaultOutputLoad)
        characterizationPolicy = request.characterizationPolicy; characterizationBindings = request.characterizationBindings
        digest = try Self.calculate(modeIDs: modeIDs, cornerIDs: cornerIDs, analysisKinds: analysisKinds,
            maxPaths: maxPaths, requiresPostLayoutInputs: requiresPostLayoutInputs, variation: variation,
            inputSlews: inputSlews, defaultOutputLoads: defaultOutputLoads,
            characterizationPolicy: characterizationPolicy, characterizationBindings: characterizationBindings)
    }
    private static func calculate(modeIDs: [String], cornerIDs: [String], analysisKinds: [STAAnalysisKind],
        maxPaths: Int, requiresPostLayoutInputs: Bool, variation: STAVariation, inputSlews: [String: Double],
        defaultOutputLoads: [String: Double], characterizationPolicy: STACharacterizationPolicy,
        characterizationBindings: [STACharacterizationBinding]) throws -> ContentDigest {
        var bytes = Data()
        func frame(_ text: String) { let utf8 = text.utf8; bytes.append(contentsOf: String(utf8.count).utf8); bytes.append(58); bytes.append(contentsOf: utf8) }
        frame("timing.sta.effective.configuration.v1"); frame("timing.sta.3.0.0"); frame("equipotential-cap-load.v1")
        frame("defaults.v1"); frame(String(modeIDs.count)); modeIDs.forEach(frame)
        frame(String(cornerIDs.count)); cornerIDs.forEach(frame)
        frame(String(analysisKinds.count)); analysisKinds.forEach { frame($0.rawValue) }
        frame(String(maxPaths)); frame(String(requiresPostLayoutInputs))
        for value in [variation.lateCellDelayScale, variation.earlyCellDelayScale,
            variation.lateInterconnectDelayScale, variation.earlyInterconnectDelayScale] { frame(String(value.bitPattern)) }
        for mode in modeIDs { frame(String(inputSlews[mode]!.bitPattern)); frame(String(defaultOutputLoads[mode]!.bitPattern)) }
        frame(characterizationPolicy.rawValue); frame(String(characterizationBindings.count))
        for binding in characterizationBindings.sorted(by: { $0.cornerID < $1.cornerID }) {
            frame(binding.cornerID); frame(binding.conditionName); frame(binding.requiredNumericProcess.map { String($0.bitPattern) } ?? "none")
        }
        return try SHA256ContentDigester().digest(data: bytes, using: .sha256)
    }
    private enum CodingKeys: String, CodingKey {
        case encodingVersion, algorithmIdentity, reductionIdentity, modeIDs, cornerIDs, analysisKinds, maxPaths
        case requiresPostLayoutInputs, variation, inputSlews, defaultOutputLoads, characterizationPolicy, characterizationBindings, digest
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        encodingVersion = try c.decode(Int.self, forKey: .encodingVersion)
        algorithmIdentity = try c.decode(String.self, forKey: .algorithmIdentity)
        reductionIdentity = try c.decode(String.self, forKey: .reductionIdentity)
        modeIDs = try c.decode([String].self, forKey: .modeIDs); cornerIDs = try c.decode([String].self, forKey: .cornerIDs)
        analysisKinds = try c.decode([STAAnalysisKind].self, forKey: .analysisKinds); maxPaths = try c.decode(Int.self, forKey: .maxPaths)
        requiresPostLayoutInputs = try c.decode(Bool.self, forKey: .requiresPostLayoutInputs)
        variation = try c.decode(STAVariation.self, forKey: .variation)
        inputSlews = try c.decode([String: Double].self, forKey: .inputSlews)
        defaultOutputLoads = try c.decode([String: Double].self, forKey: .defaultOutputLoads)
        characterizationPolicy = try c.decode(STACharacterizationPolicy.self, forKey: .characterizationPolicy)
        characterizationBindings = try c.decode([STACharacterizationBinding].self, forKey: .characterizationBindings)
        digest = try c.decode(ContentDigest.self, forKey: .digest)
        guard encodingVersion == 1, algorithmIdentity == "timing.sta.3.0.0", reductionIdentity == "equipotential-cap-load.v1",
              !modeIDs.isEmpty, !cornerIDs.isEmpty, !analysisKinds.isEmpty, maxPaths > 0, variation.isValid,
              Set(modeIDs).count == modeIDs.count, Set(cornerIDs).count == cornerIDs.count,
              Set(inputSlews.keys) == Set(modeIDs), Set(defaultOutputLoads.keys) == Set(modeIDs),
              inputSlews.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              defaultOutputLoads.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              characterizationBindings.allSatisfy({ $0.requiredNumericProcess?.isFinite ?? true }),
              digest == (try Self.calculate(modeIDs: modeIDs, cornerIDs: cornerIDs, analysisKinds: analysisKinds,
                  maxPaths: maxPaths, requiresPostLayoutInputs: requiresPostLayoutInputs, variation: variation,
                  inputSlews: inputSlews, defaultOutputLoads: defaultOutputLoads,
                  characterizationPolicy: characterizationPolicy, characterizationBindings: characterizationBindings)) else {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: c, debugDescription: "Effective STA configuration is inconsistent")
        }
    }
}
