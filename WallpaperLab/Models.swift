import Foundation

struct ImportLogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let message: String
    let level: Level

    enum Level: String, Codable {
        case info, success, warning, error
    }

    init(_ message: String, level: Level = .info) {
        self.id = UUID()
        self.timestamp = Date()
        self.message = message
        self.level = level
    }
}

struct ImportManifest: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let sourceName: String
    let importedPaths: [String]
    let preferencesBackupPath: String?
    let preferencesAfterDigest: String?
}

struct ImportResult {
    let manifest: ImportManifest
    let descriptorCount: Int
}

enum WallpaperLabError: LocalizedError {
    case inaccessible(String)
    case invalidPackage(String)
    case posterBoardUnavailable(String)
    case unsafeTarget
    case nothingToRollback

    var errorDescription: String? {
        switch self {
        case .inaccessible(let detail): return "Не удалось получить доступ: \(detail)"
        case .invalidPackage(let detail): return "Пакет не подходит: \(detail)"
        case .posterBoardUnavailable(let detail): return "Контейнер PosterBoard не найден. \(detail)"
        case .unsafeTarget: return "Откат остановлен: путь не прошёл проверку безопасности."
        case .nothingToRollback: return "Нет последней операции для отката."
        }
    }
}
