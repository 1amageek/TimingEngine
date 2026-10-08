/// Checked managed element capacity; no allocator-size inference.
public enum LibertySourceCapacity {
    public static func byteCount<Element>(of: Element.Type, capacity: Int)
        throws(LibertySourceError) -> UInt64 {
        guard capacity >= 0 else { throw .invalidCapacity }
        let (bytes, overflow) = UInt64(capacity).multipliedReportingOverflow(by: UInt64(MemoryLayout<Element>.stride))
        guard !overflow else { throw .arithmeticOverflow }
        return bytes
    }
}
