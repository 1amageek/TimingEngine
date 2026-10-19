/// A numerical coordinate proposal failed its certificate; the primitive model is unchanged.
internal struct NativeSTAConservativeCandidateNotCertified: Error, Sendable, Equatable {
    let reason: String
}
