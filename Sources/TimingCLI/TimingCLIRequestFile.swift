import Darwin
import Foundation
import TimingCore

/// One descriptor owns a bounded regular-file snapshot; no descriptor escapes this call.
enum TimingCLIRequestFile {
    static func read(_ url: URL, maximumBytes: UInt64) throws -> Data {
        guard maximumBytes > 0, maximumBytes < UInt64(Int.max) else {
            throw TimingError.invalidInput("Request byte limit must be positive and host-addressable")
        }
        let descriptor = Darwin.open(url.path(percentEncoded:false), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw TimingError.artifactReadFailed(path:url.path,message:"Cannot open request file; errno \(errno)")
        }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        let result: Data
        do {
            var status = stat()
            guard Darwin.fstat(descriptor,&status) == 0, (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else {
                throw TimingError.invalidInput("STA request must be a regular file")
            }
            let size = UInt64(status.st_size)
            guard size <= maximumBytes else { throw TimingError.invalidInput("STA request exceeds --maximum-request-bytes") }
            var data = Data(); data.reserveCapacity(Int(size))
            while data.count <= Int(size) {
                guard let chunk = try handle.read(upToCount:Int(size) - data.count + 1), !chunk.isEmpty else { break }
                guard chunk.count <= Int(size) - data.count else { throw TimingError.invalidInput("STA request length changed during read") }
                data.append(chunk)
            }
            guard data.count == Int(size) else { throw TimingError.invalidInput("STA request length changed during read") }
            result = data
        } catch {
            do { try handle.close() }
            catch let close {
                throw TimingError.artifactReadFailed(path:url.path,message:"Read failed: \(error); close failed: \(close)")
            }
            throw error
        }
        try handle.close()
        return result
    }
}
