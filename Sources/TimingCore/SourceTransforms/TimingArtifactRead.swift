import CircuiteFoundation
import Foundation

/// Keep this paired owner alive while using its Data, including copied handles.
/// Detached bytes transfer their managed-storage responsibility to the caller.
public struct TimingArtifactRead: Sendable {
    public let data: Data
    public let reference: ArtifactReference
    private let retention: Retention

    internal init(data: Data, reference: ArtifactReference,
                  payload: LibertySourceStorageReservation,
                  metadata: LibertySourceStorageReservation) {
        self.data = data
        self.reference = reference
        self.retention = Retention(data: data, payload: payload, metadata: metadata)
    }

    private final class Retention: Sendable {
        let data: Data
        let payload: LibertySourceStorageReservation
        let metadata: LibertySourceStorageReservation
        init(data: Data, payload: LibertySourceStorageReservation,
             metadata: LibertySourceStorageReservation) {
            self.data = data; self.payload = payload; self.metadata = metadata
        }
    }

    internal static func metadataBytes() throws -> UInt64 {
        try LibertySourceCapacity.byteCount(of: (Data, LibertySourceStorageReservation,
            LibertySourceStorageReservation, ArtifactReference).self, capacity: 1)
    }
}
