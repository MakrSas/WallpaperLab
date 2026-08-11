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

enum BadQueryDirectory {
    /// `bad_query` cannot reliably issue an extension for a parent directory on
    /// iOS 27. The PoC supplies this inode-based enumerator specifically for
    /// discovering concrete child containers without first opening the parent.
    static func immediateChildren(of path: String, maximumInode: Int32 = 1_500_000) throws -> [URL] {
        var mutablePath = Array(path.utf8CString)
        guard let pointer = bad_query_list(&mutablePath, maximumInode) else {
            throw WallpaperLabError.inaccessible("не удалось перечислить \(path)")
        }
        defer { free(pointer) }
        return String(cString: pointer)
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }
}

enum PosterBoardLocator {
    static let applicationsRoot = "/var/mobile/Containers/Data/Application"

    static func locate(lease: BadQueryLease, report: (String) -> Void) throws -> URL {
        let candidates = try BadQueryDirectory.immediateChildren(of: applicationsRoot)
        report("Найдено контейнеров приложений: \(candidates.count)")
        var readableMetadata = 0

        for candidate in candidates {
            guard candidate.lastPathComponent.count >= 20 else { continue }
            do {
                // Do not keep sandbox extensions for unrelated applications.
                let probe = BadQueryLease()
                try probe.grant(candidate.path)
                let metadata = candidate.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                try probe.grant(metadata.path)
                if let values = NSDictionary(contentsOf: metadata),
                   let identifier = values["MCMMetadataIdentifier"] as? String {
                    readableMetadata += 1
                    if identifier != "com.apple.PosterBoard" { continue }
                    try lease.grant(candidate.path)
                    try lease.grant(metadata.path)
                    return candidate
                }
            } catch {
                continue
            }
        }
        throw WallpaperLabError.posterBoardUnavailable("Проверено UUID: \(candidates.count), доступны metadata: \(readableMetadata).")
    }
}
