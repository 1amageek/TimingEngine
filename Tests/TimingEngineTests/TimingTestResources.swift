import Foundation

enum TimingTestResources {
    enum ResourceError: Error, Equatable {
        case missingResourceRoot
        case missingResource(String)
    }

    static var corpusRoot: URL {
        get throws {
            try directory(named: "Corpus")
        }
    }

    static var qualificationRoot: URL {
        get throws {
            try directory(named: "Qualification")
        }
    }

    private static func directory(named name: String) throws -> URL {
        guard let resourceRoot = Bundle.module.resourceURL else {
            throw ResourceError.missingResourceRoot
        }
        let directory = resourceRoot.appending(path: name, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            throw ResourceError.missingResource(name)
        }
        return directory
    }
}
