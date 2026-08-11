import CryptoKit
import Foundation
import ZIPFoundation

struct PosterBoardImporter {
    private let fileManager = FileManager.default
    private let maximumArchiveSize = 256 * 1024 * 1024
    private let maximumDescriptors = 10

    func `import`(package source: URL, report: (String) -> Void) throws -> ImportResult {
        report("Проверяю пакет")
        let staging = try unpack(package: source)
        defer { try? fileManager.removeItem(at: staging) }

        try validateTree(at: staging)
        let descriptors = try findDescriptorFolders(in: staging)
        guard !descriptors.isEmpty else {
            throw WallpaperLabError.invalidPackage("не найдена папка descriptor или descriptors")
        }
        guard descriptors.count <= maximumDescriptors else {
            throw WallpaperLabError.invalidPackage("не более \(maximumDescriptors) дескрипторов за импорт")
        }

        report("Ищу контейнер PosterBoard")
        let lease = BadQueryLease()
        let posterBoardRoot = try PosterBoardLocator.locate(lease: lease, report: report)
        try lease.grant(posterBoardRoot.path)
        let extensionsRoot = try locateExtensions(in: posterBoardRoot, lease: lease)

        let transactionID = UUID()
        let preferenceBackup = try backupPreferences(in: posterBoardRoot, transactionID: transactionID, lease: lease)
        var installedPaths: [String] = []

        do {
            for folder in descriptors {
                let provider = providerIdentifier(for: folder)
                let target = extensionsRoot
                    .appendingPathComponent(provider, isDirectory: true)
                    .appendingPathComponent("descriptors", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)

                try lease.grant(target.deletingLastPathComponent().path, create: true)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let prepared = target.appendingPathExtension("preparing")
                try fileManager.copyItem(at: folder, to: prepared)
                try rewriteMetadata(in: prepared, identifier: Int.random(in: 100_000...999_999))
                try fileManager.moveItem(at: prepared, to: target)
                installedPaths.append(target.path)
                report("Добавлен дескриптор \(installedPaths.count) из \(descriptors.count)")
            }

            let preferencesDigest = try refreshPosterBoardPreferences(in: posterBoardRoot, lease: lease)
            let manifest = ImportManifest(
                id: transactionID,
                createdAt: Date(),
                sourceName: source.lastPathComponent,
                importedPaths: installedPaths,
                preferencesBackupPath: preferenceBackup?.path,
                preferencesAfterDigest: preferencesDigest
            )
            try TransactionStore.save(manifest)
            report("Импорт завершён")
            return ImportResult(manifest: manifest, descriptorCount: installedPaths.count)
        } catch {
            installedPaths.forEach { try? fileManager.removeItem(atPath: $0) }
            throw error
        }
    }

    func rollbackLatest(report: (String) -> Void) throws -> ImportManifest {
        guard let manifest = try TransactionStore.latest() else { throw WallpaperLabError.nothingToRollback }

        report("Ищу контейнер PosterBoard")
        let lease = BadQueryLease()
        let posterBoardRoot = try PosterBoardLocator.locate(lease: lease, report: report)
        let extensionsRoot = try locateExtensions(in: posterBoardRoot, lease: lease).standardizedFileURL.path

        for path in manifest.importedPaths {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
            guard candidate.hasPrefix(extensionsRoot + "/") else { throw WallpaperLabError.unsafeTarget }
            try? fileManager.removeItem(atPath: candidate)
        }
        if let backupPath = manifest.preferencesBackupPath {
            let backup = URL(fileURLWithPath: backupPath)
            if fileManager.fileExists(atPath: backup.path) {
                let target = preferencesURL(in: posterBoardRoot)
                try lease.grant(target.deletingLastPathComponent().path, create: true)
                let currentDigest = (try? Data(contentsOf: target)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                if manifest.preferencesAfterDigest == nil || currentDigest == manifest.preferencesAfterDigest {
                    try? fileManager.removeItem(at: target)
                    try fileManager.copyItem(at: backup, to: target)
                } else {
                    report("Настройки PosterBoard менялись после импорта — резервная копия не восстановлена")
                }
            }
        }
        try TransactionStore.delete(manifest)
        report("Последний импорт отменён")
        return manifest
    }

    private func unpack(package source: URL) throws -> URL {
        let workRoot = try TransactionStore.workingDirectory()
        let destination = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        if source.hasDirectoryPath {
            try fileManager.copyItem(at: source, to: destination.appendingPathComponent(source.lastPathComponent, isDirectory: true))
            return destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        }

        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw WallpaperLabError.invalidPackage("ожидается ZIP-совместимый файл .tendies")
        }
        var expandedSize = 0
        for entry in archive {
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains(".."), entry.type != .symlink else {
                throw WallpaperLabError.invalidPackage("архив содержит небезопасный путь")
            }
            expandedSize += Int(entry.uncompressedSize)
            if expandedSize > maximumArchiveSize {
                throw WallpaperLabError.invalidPackage("распакованный размер больше 256 МБ")
            }
        }
        try fileManager.unzipItem(at: source, to: destination)
        return destination
    }

    private func validateTree(at root: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            throw WallpaperLabError.invalidPackage("не удаётся прочитать содержимое")
        }
        var totalSize = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { throw WallpaperLabError.invalidPackage("символические ссылки запрещены") }
            totalSize += values.fileSize ?? 0
            if totalSize > maximumArchiveSize { throw WallpaperLabError.invalidPackage("содержимое больше 256 МБ") }
        }
    }

    private func findDescriptorFolders(in root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [URL] = []
        for case let folder as URL in enumerator {
            guard (try folder.resourceValues(forKeys: keys).isDirectory) == true else { continue }
            if folder.lastPathComponent == "container" {
                throw WallpaperLabError.invalidPackage("пакеты с папкой container не поддерживаются")
            }
            guard ["descriptor", "descriptors"].contains(folder.lastPathComponent.lowercased()) else { continue }
            let children = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            result += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            enumerator.skipDescendants()
        }
        return result
    }

    private func locateExtensions(in root: URL, lease: BadQueryLease) throws -> URL {
        let dataStore = root.appendingPathComponent("Library/Application Support/PRBPosterExtensionDataStore", isDirectory: true)
        try lease.grant(dataStore.path)
        let candidates = try fileManager.contentsOfDirectory(at: dataStore, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { (Int($0.lastPathComponent) ?? 0) > (Int($1.lastPathComponent) ?? 0) }
        guard let store = candidates.first, Int(store.lastPathComponent) != nil else {
            throw WallpaperLabError.posterBoardUnavailable("В контейнере нет хранилища расширений.")
        }
        let extensions = store.appendingPathComponent("Extensions", isDirectory: true)
        try lease.grant(extensions.path, create: true)
        try fileManager.createDirectory(at: extensions, withIntermediateDirectories: true)
        return extensions
    }

    private func providerIdentifier(for folder: URL) -> String {
        let path = folder.path.lowercased()
        if path.contains("video") || path.contains("photos") { return "com.apple.PhotosUIPrivate.PhotosPosterProvider" }
        if path.contains("mercury") { return "com.apple.MercuryPoster" }
        return "com.apple.WallpaperKit.CollectionsPoster"
    }

    private func rewriteMetadata(in descriptor: URL, identifier: Int) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let enumerator = fileManager.enumerator(at: descriptor, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: keys).isDirectory) != true {
            let name = url.lastPathComponent
            if name == "com.apple.posterkit.provider.descriptor.identifier" {
                try "\(identifier)".write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            guard name.hasSuffix(".plist"), let data = try? Data(contentsOf: url),
                  var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            var changed = false
            if name.contains("userInfo") || name == "com.apple.posterkit.provider.contents.userInfo.plist" {
                plist["wallpaperRepresentingIdentifier"] = identifier
                changed = true
            }
            if name.hasSuffix("Wallpaper.plist") {
                plist["identifier"] = identifier
                plist["name"] = "Wallpaper Lab \(identifier)"
                changed = true
            }
            if changed {
                let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
                try updated.write(to: url, options: .atomic)
            }
        }
    }

    private func preferencesURL(in root: URL) -> URL {
        root.appendingPathComponent("Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist")
    }

    private func backupPreferences(in root: URL, transactionID: UUID, lease: BadQueryLease) throws -> URL? {
        let preferences = preferencesURL(in: root)
        try lease.grant(preferences.deletingLastPathComponent().path, create: true)
        guard fileManager.fileExists(atPath: preferences.path) else { return nil }
        let backup = try TransactionStore.backupsDirectory().appendingPathComponent("\(transactionID.uuidString).plist")
        try fileManager.copyItem(at: preferences, to: backup)
        return backup
    }

    private func refreshPosterBoardPreferences(in root: URL, lease: BadQueryLease) throws -> String {
        let preferences = preferencesURL(in: root)
        try lease.grant(preferences.deletingLastPathComponent().path, create: true)
        let existingData = try? Data(contentsOf: preferences)
        var values = (existingData.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }) ?? [:]
        values["PBF_LOCALE_DID_CHANGE"] = false
        values["PBF_RESET_FILE_PROTECTIONS"] = true
        values["PersistedPosterContainerBundleIdentifiers"] = ["com.apple.Posters.CollectionsPosterApp"]
        values["CompletedPosterBundleIdentifierMigrations"] = [
            "com.apple.Posters.CollectionsPosterApp",
            "com.apple.WallpaperKit.CollectionsPoster",
            "com.apple.PhotosUIPrivate.PhotosPosterProvider",
            "com.apple.MercuryPoster"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: preferences, options: .atomic)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum TransactionStore {
    private static var baseDirectory: URL {
        get throws {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("WallpaperLab", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }

    static func workingDirectory() throws -> URL {
        let url = try baseDirectory.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func backupsDirectory() throws -> URL {
        let url = try baseDirectory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func save(_ manifest: ImportManifest) throws {
        let directory = try baseDirectory.appendingPathComponent("Transactions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent("\(manifest.id.uuidString).json"), options: .atomic)
    }

    static func latest() throws -> ImportManifest? {
        let directory = try baseDirectory.appendingPathComponent("Transactions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
        for file in files {
            if let manifest = try? JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: file)) { return manifest }
        }
        return nil
    }

    static func delete(_ manifest: ImportManifest) throws {
        let file = try baseDirectory.appendingPathComponent("Transactions/\(manifest.id.uuidString).json")
        try? FileManager.default.removeItem(at: file)
    }
}
