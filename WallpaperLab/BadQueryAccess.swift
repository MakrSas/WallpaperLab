import Darwin
import Foundation

final class BadQueryLease {
    private var handles: [Int64] = []

    func grant(_ path: String, create: Bool = false) throws {
        var mutablePath = Array(path.utf8CString)
        let handle = bad_query(&mutablePath, create, nil, false)
        guard handle >= 0 else {
            throw WallpaperLabError.inaccessible("bad_query вернул \(handle) для \(path)")
        }
        handles.append(handle)
    }

    deinit {
        handles.reversed().forEach { bad_query_release($0) }
    }
}

enum PosterBoardLocator {
    static let applicationsRoot = "/var/mobile/Containers/Data/Application"

    static func locate(lease: BadQueryLease) throws -> URL {
        try lease.grant(applicationsRoot)
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: applicationsRoot, isDirectory: true)
        let candidates = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []

        for candidate in candidates {
            guard candidate.lastPathComponent.count >= 20 else { continue }
            do {
                try lease.grant(candidate.path)
                let metadata = candidate.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                if let values = NSDictionary(contentsOf: metadata),
                   values["MCMMetadataIdentifier"] as? String == "com.apple.PosterBoard" {
                    return candidate
                }
            } catch {
                continue
            }
        }
        throw WallpaperLabError.posterBoardUnavailable
    }
}

