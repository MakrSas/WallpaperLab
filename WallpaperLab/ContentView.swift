import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let tendies = UTType(exportedAs: "com.makrsas.wallpaperlab.tendies")
}

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var isPresentingImporter = false
    @Published var isWorking = false
    @Published var activity = "Готов к импорту"
    @Published var logs: [ImportLogEntry] = []
    @Published var alert: UserAlert?

    struct UserAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    func importPackage(_ url: URL) {
        isWorking = true
        activity = "Импортирую пакет"
        add("Открыт \(url.lastPathComponent)")
        let hasSecurityScope = url.startAccessingSecurityScopedResource()

        Task.detached(priority: .userInitiated) {
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let result = try PosterBoardImporter().import(package: url) { message in
                    Task { @MainActor in self.add(message) }
                }
                await MainActor.run {
                    self.isWorking = false
                    self.activity = "Импортировано: \(result.descriptorCount)"
                    self.add("Готово. Открой экран настройки обоев после перезапуска SpringBoard.", level: .success)
                    self.alert = .init(title: "Импорт завершён", message: "Добавлено: \(result.descriptorCount). Если обои не появились сразу, перезагрузи SpringBoard или устройство.")
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.activity = "Импорт не выполнен"
                    self.add(error.localizedDescription, level: .error)
                    self.alert = .init(title: "Не получилось импортировать", message: error.localizedDescription)
                }
            }
        }
    }

    func rollback() {
        isWorking = true
        activity = "Откатываю последний импорт"
        Task.detached(priority: .userInitiated) {
            do {
                let manifest = try PosterBoardImporter().rollbackLatest { message in
                    Task { @MainActor in self.add(message, level: .warning) }
                }
                await MainActor.run {
                    self.isWorking = false
                    self.activity = "Последний импорт отменён"
                    self.add("Удалён пакет \(manifest.sourceName)", level: .success)
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.activity = "Откат не выполнен"
                    self.add(error.localizedDescription, level: .error)
                    self.alert = .init(title: "Откат не выполнен", message: error.localizedDescription)
                }
            }
        }
    }

    func add(_ message: String, level: ImportLogEntry.Level = .info) {
        logs.insert(ImportLogEntry(message, level: level), at: 0)
    }
}

struct ContentView: View {
    @StateObject private var model = ImportViewModel()

    var body: some View {
        NavigationStack {
            List {
                hero
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20))

                Section {
                    Button {
                        model.isPresentingImporter = true
                    } label: {
                        Label("Выбрать .tendies", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.isWorking)

                    Button(role: .destructive) {
                        model.rollback()
                    } label: {
                        Label("Откатить последний импорт", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.isWorking)
                } header: {
                    Text("Импорт")
                } footer: {
                    Text("Поддерживаются только descriptor/descriptors-пакеты. Папки container и ссылки автоматически отклоняются.")
                }

                Section("Состояние") {
                    HStack(spacing: 12) {
                        Image(systemName: model.isWorking ? "arrow.triangle.2.circlepath" : "checkmark.seal.fill")
                            .foregroundStyle(model.isWorking ? .blue : .green)
                            .symbolEffect(.rotate, isActive: model.isWorking)
                        Text(model.activity)
                        Spacer()
                        if model.isWorking { ProgressView() }
                    }
                }

                if !model.logs.isEmpty {
                    Section("Журнал") {
                        ForEach(model.logs.prefix(8)) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle()
                                    .fill(color(for: entry.level))
                                    .frame(width: 7, height: 7)
                                Text(entry.message)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                Section("Перед началом") {
                    Label("Сделай резервную копию устройства", systemImage: "externaldrive.badge.checkmark")
                    Label("Используй только доверенные пакеты", systemImage: "checkmark.shield")
                    Label("Не закрывай приложение во время операции", systemImage: "iphone.gen3")
                }
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Wallpaper Lab")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                }
            }
        }
        .fileImporter(isPresented: $model.isPresentingImporter, allowedContentTypes: [.tendies, .zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.importPackage(url)
            case .failure(let error):
                model.alert = .init(title: "Не удалось открыть файл", message: error.localizedDescription)
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .foregroundStyle(.white)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Свои обои, аккуратно")
                        .font(.title3.weight(.semibold))
                    Text("PosterBoard · iOS 27 beta 4")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Импортирует descriptor-пакеты в PosterBoard и сохраняет запись для одного безопасного отката.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func color(for level: ImportLogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
