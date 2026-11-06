import AppKit
import LeadGenCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView().tabItem { Label("Внешний вид", systemImage: "paintpalette") }
            SyncSettingsView().tabItem { Label("Синхронизация", systemImage: "arrow.triangle.2.circlepath") }
            DataSettingsView().tabItem { Label("Данные", systemImage: "externaldrive") }
            ExclusionsSettingsView().tabItem { Label("Исключения", systemImage: "nosign") }
            OutreachSettingsView().tabItem { Label("Обращения", systemImage: "text.bubble") }
        }
        .frame(width: 680)
        .frame(minHeight: 520)
    }
}

// MARK: - Внешний вид

struct AppearanceSettingsView: View {
    @Environment(AppearanceSettings.self) private var look
    @State private var allFonts: [String] = []

    var body: some View {
        @Bindable var look = look
        Form {
            Section("Тема") {
                HStack(spacing: 14) {
                    ForEach(ThemeMode.allCases) { mode in
                        ThemeTile(mode: mode, selected: look.theme == mode) { look.theme = mode }
                    }
                }
                .padding(.vertical, 4)
                Picker("Акцентный цвет", selection: $look.accent) {
                    ForEach(AccentChoice.allCases) { a in
                        HStack { Circle().fill(a.color).frame(width: 10, height: 10); Text(a.title) }.tag(a)
                    }
                }
            }
            Section("Шрифты") {
                Picker("Шрифт интерфейса", selection: $look.fontFamily) {
                    Text("Системный (SF Pro)").tag(AppearanceSettings.systemFont)
                    let rec = AppearanceSettings.recommended.filter { allFonts.contains($0) }
                    if !rec.isEmpty {
                        Divider()
                        ForEach(rec, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                    }
                    Divider()
                    ForEach(allFonts.filter { !AppearanceSettings.recommended.contains($0) }, id: \.self) { Text($0).tag($0) }
                }
                Picker("Моноширинный (логи, данные)", selection: $look.monoFamily) {
                    Text("Системный (SF Mono)").tag(AppearanceSettings.systemFont)
                    ForEach(AppearanceSettings.recommendedMono.filter { allFonts.contains($0) }, id: \.self) { Text($0).tag($0) }
                }
                Text("Показаны шрифты, установленные на этом Mac. Новый шрифт можно добавить через «Шрифты» в macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Масштаб интерфейса") {
                HStack {
                    Text("А").font(.system(size: 11))
                    Slider(value: $look.scale, in: AppearanceSettings.scaleRange, step: 0.05)
                    Text("А").font(.system(size: 18))
                    Text("\(Int((look.scale * 100).rounded()))%")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                HStack {
                    ForEach([0.9, 1.0, 1.1, 1.25, 1.5], id: \.self) { v in
                        Button("\(Int(v * 100))%") { look.scale = v }
                            .buttonStyle(.bordered)
                            .tint(abs(look.scale - v) < 0.01 ? Color.accentColor : nil)
                    }
                    Spacer()
                    Text("⌘+  ⌘−  ⌘0").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Плотность строк", selection: $look.density) {
                    ForEach(Density.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Предпросмотр") {
                PreviewRow()
            }
        }
        .formStyle(.grouped)
        .onAppear { allFonts = AppearanceSettings.installedFamilies }
    }
}

private struct ThemeTile: View {
    let mode: ThemeMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    switch mode {
                    case .light: mini(bg: .white, side: Color(white: 0.95), fg: Color(white: 0.85))
                    case .dark: mini(bg: Color(white: 0.11), side: Color(white: 0.16), fg: Color(white: 0.3))
                    case .system:
                        HStack(spacing: 0) {
                            mini(bg: .white, side: Color(white: 0.95), fg: Color(white: 0.85))
                            mini(bg: Color(white: 0.11), side: Color(white: 0.16), fg: Color(white: 0.3))
                        }
                    }
                }
                .frame(width: 120, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 2.5 : 1))
                Text(mode.title).font(.callout).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func mini(bg: Color, side: Color, fg: Color) -> some View {
        HStack(spacing: 0) {
            side.frame(maxWidth: 30)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(i == 0 ? Color.accentColor.opacity(0.8) : fg).frame(height: 5)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bg)
        }
    }
}

private struct PreviewRow: View {
    @Environment(AppearanceSettings.self) private var look
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Студия красоты «Лаванда»").appFont(13, .medium)
                Text("Организация · ул. Баумана, 44 · Казань").appFont(11.5).foregroundStyle(.secondary)
            }
            Spacer()
            Tag(text: "Нет сайта", color: .red)
            ScoreView(score: 84)
        }
        .padding(.vertical, look.density.rowPadding * look.scale + 4)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .tint(look.accent.color)
    }
}

// MARK: - Синхронизация

struct SyncSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var secret = ""
    @State private var saved = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("Поиск выполняется по расписанию в GitHub Actions. После каждого запуска он публикует зашифрованную копию базы, а приложение скачивает её, расшифровывает на этом Mac и добавляет новые лиды в локальную базу. Ваши избранное, архив, заметки и удаления синхронизация не трогает.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Репозиторий") {
                TextField("Владелец", text: $model.githubOwner)
                TextField("Репозиторий", text: $model.githubRepo)
                TextField("Ветка", text: $model.githubBranch)
            }
            Section("Доступ (хранится в Связке ключей)") {
                SecureField("Токен GitHub", text: $token, prompt: Text(model.hasToken ? "сохранён" : "github_pat_…"))
                Text("Fine-grained токен только для этого репозитория. Права: Actions — Read and write (скачивание результатов и запуск поиска). Создать: github.com → Settings → Developer settings → Fine-grained tokens.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Ключ шифрования состояния", text: $secret, prompt: Text(model.hasSecret ? "сохранён" : "значение STATE_ENCRYPTION_KEY"))
                Text("То же значение, что в секрете STATE_ENCRYPTION_KEY репозитория. Без него зашифрованную базу не прочитать.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Сохранить") {
                        if !token.isEmpty { Keychain.set("github.token", token.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        if !secret.isEmpty { Keychain.set("state.secret", secret.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        token = ""; secret = ""; saved = true
                    }
                    .disabled(token.isEmpty && secret.isEmpty)
                    Button("Удалить из Связки ключей", role: .destructive) {
                        Keychain.set("github.token", ""); Keychain.set("state.secret", ""); saved = false
                    }
                    Spacer()
                    if saved { Label("Сохранено", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            Section("Автоматически") {
                Picker("Проверять новые результаты", selection: $model.autoSyncMinutes) {
                    Text("Выключено").tag(0)
                    Text("Каждые 15 минут").tag(15)
                    Text("Каждые 30 минут").tag(30)
                    Text("Каждый час").tag(60)
                    Text("Каждые 3 часа").tag(180)
                }
                Text("Поиск в Actions идёт раз в час; источники проверяются со своими интервалами.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Синхронизировать сейчас") { Task { await model.syncNow(force: true) } }
                        .disabled(!model.syncConfigured || model.syncing)
                    Button("Запустить поиск в Actions") { Task { await model.dispatchSearch() } }
                        .disabled(!model.githubConfig.isComplete || !model.hasToken)
                    Spacer()
                    if model.syncing { ProgressView().controlSize(.small) }
                }
                if let e = model.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                if let at = model.lastSyncAt { Text("Последняя синхронизация: \(at.fullRu)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Данные

struct DataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var backups: [URL] = []

    var body: some View {
        @Bindable var model = model
        Form {
            Section("База данных") {
                LabeledContent("Расположение") {
                    Text(model.databasePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                LabeledContent("Размер", value: ByteCountFormatter.string(fromByteCount: model.databaseSize, countStyle: .file))
                LabeledContent("Лидов", value: "\(model.leads.count)")
                HStack {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.databasePath)])
                    }
                    Button("Перенести в другую папку…") {
                        if let dir = chooseFolder() { model.moveDatabase(to: dir) }
                    }
                }
                Text("База и настройки лежат отдельно от программы: обновление приложения их не удаляет.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Резервные копии") {
                Toggle("Делать копию раз в сутки при запуске", isOn: $model.autoBackup)
                Stepper("Хранить копий: \(model.keepBackups)", value: $model.keepBackups, in: 1...60)
                LabeledContent("Папка") {
                    Text(model.backupDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Изменить папку…") { if let d = chooseFolder() { model.backupDirectory = d.path } }
                    Button("Создать копию сейчас") { model.backupNow(); backups = model.backups() }
                    Button("Восстановить из файла…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
                        if p.runModal() == .OK, let url = p.url { model.restore(from: url) }
                    }
                }
                ForEach(backups.prefix(8), id: \.self) { url in
                    HStack {
                        Image(systemName: "archivebox").foregroundStyle(.secondary)
                        Text(url.lastPathComponent).font(.callout)
                        Spacer()
                        Button("Восстановить") { model.restore(from: url) }
                    }
                }
            }
            Section("Перенос на другой Mac") {
                Text("Скопируйте файл базы (или любую резервную копию) на новый Mac и выберите его в «Восстановить из файла…». Токен и ключ шифрования в копию не попадают — введите их заново.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { backups = model.backups() }
    }

    private func chooseFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }
}

// MARK: - Исключения

struct ExclusionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var kind: ExclusionKind = .domain
    @State private var value = ""

    var body: some View {
        Form {
            Section("Добавить исключение") {
                HStack {
                    Picker("", selection: $kind) { ForEach(ExclusionKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .labelsHidden().fixedSize()
                    TextField("например, example.ru или +7 843 000-00-00", text: $value)
                        .onSubmit(add)
                    Button("Добавить", action: add).disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button("Импорт базы своих клиентов (CSV)…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.commaSeparatedText, .plainText]
                        if p.runModal() == .OK, let url = p.url { model.importExclusions(from: url) }
                    }
                    Spacer()
                }
                Text("Из файла берутся все ячейки с email, телефонами и доменами. Такие лиды попадают в раздел «Исключённые» и не мешают в общем списке.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Правила: \(model.exclusions.count)") {
                if model.exclusions.isEmpty { Text("Исключений нет").foregroundStyle(.secondary) }
                ForEach(model.exclusions) { e in
                    HStack {
                        Text(e.kind.title).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(e.value).textSelection(.enabled)
                        Spacer()
                        Button { model.removeExclusion(e.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        model.exclude(kind, v)
        value = ""
    }
}

// MARK: - Обращения

struct OutreachSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Подпись в черновиках") {
                TextEditor(text: $model.signature)
                    .frame(height: 80)
                Text("Например: «Максим, разработка сайтов и ботов, t.me/username». Подставляется в конец черновика.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Черновики собираются по шаблонам из проверенных фактов о лиде, без внешних AI-сервисов. Отправляете вы сами: массовой рассылки в приложении нет и не будет.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
