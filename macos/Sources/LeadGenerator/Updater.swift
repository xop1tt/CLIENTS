import AppKit
import LeadGenCore
import Observation

/// Автообновление из GitHub Releases: проверка, скачивание, проверка SHA-256, замена и перезапуск.
///
/// Без серверов и ключей: публичный API релизов и файлы, которые публикует release.yml.
/// Окна — NSAlert, чтобы не связывать обновление с графом SwiftUI.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: AvailableUpdate?

    static let autoKey = "updates.auto"
    private static let skipKey = "updates.skip"
    private static let lastKey = "updates.lastCheck"

    var automatic: Bool {
        get { access(keyPath: \.automatic); return defaults.object(forKey: Self.autoKey) as? Bool ?? true }
        set { withMutation(keyPath: \.automatic) { defaults.set(newValue, forKey: Self.autoKey) } }
    }

    /// Версия этой сборки. Нет у запуска без .app (swift run): тогда обновление выключено.
    let current: AppVersion? = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)

    var canUpdate: Bool { current != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private init() {
        lastCheck = defaults.object(forKey: Self.lastKey) as? Date
    }

    // MARK: Проверка

    /// Через полминуты после запуска и затем каждые 6 часов; сама проверка — не чаще раза в 20 часов.
    func startAutomaticChecks() {
        guard canUpdate else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.automaticCheck() }
        }
    }

    private func automaticCheck() {
        guard automatic else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 20 * 3600 { return }
        check(manual: false)
    }

    /// Ручная проверка показывает результат всегда, автоматическая — только если есть новая версия.
    func check(manual: Bool) {
        guard let current, canUpdate else {
            if manual { alert("Обновление недоступно", "Приложение запущено не из «Lead Generator.app», обновлять нечего.") }
            return
        }
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        phase = .checking
        Task {
            do {
                let release = try await Updates.fetchLatest(userAgent: "LeadGenerator/\(current) (macOS)")
                lastCheck = Date()
                defaults.set(lastCheck, forKey: Self.lastKey)
                guard let update = Updates.update(from: release, current: current) else {
                    phase = .upToDate
                    if manual { alert("Установлена последняя версия", "Lead Generator \(current) — самая новая версия.") }
                    return
                }
                phase = .available(update.version.description)
                if !manual, defaults.string(forKey: Self.skipKey) == update.version.description { return }
                offer(update)
            } catch {
                phase = .failed(error.localizedDescription)
                if manual { alert("Не удалось проверить обновления", error.localizedDescription) }
            }
        }
    }

    private func offer(_ update: AvailableUpdate) {
        let a = NSAlert()
        a.messageText = "Доступна версия \(update.version)"
        var notes = update.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 900 { notes = String(notes.prefix(900)) + "…" }
        a.informativeText = "Установлена версия \(current?.description ?? "?").\n\n\(notes)"
        a.addButton(withTitle: "Установить и перезапустить")
        a.addButton(withTitle: "Позже")
        a.addButton(withTitle: "Пропустить эту версию")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: install(update)
        case .alertThirdButtonReturn: defaults.set(update.version.description, forKey: Self.skipKey)
        default: break
        }
    }

    // MARK: Установка

    func install(_ update: AvailableUpdate) {
        pending = update
        phase = .downloading
        Task {
            do {
                let staged = try await download(update)
                phase = .installing
                try relaunch(replacingWith: staged)
            } catch {
                phase = .failed(error.localizedDescription)
                let a = NSAlert()
                a.messageText = "Обновление не установлено"
                a.informativeText = "\(error.localizedDescription)\n\nМожно скачать установщик со страницы релиза и установить вручную."
                a.addButton(withTitle: "Открыть страницу релиза")
                a.addButton(withTitle: "Закрыть")
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(update.page ?? Updates.releasesPage) }
            }
        }
    }

    /// Скачивает установщик, сверяет SHA-256, достаёт приложение из образа и проверяет его.
    /// Не на главном потоке: подсчёт суммы и hdiutil занимают несколько секунд.
    nonisolated private func download(_ update: AvailableUpdate) async throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeadGenerator-update-\(update.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // Ожидаемая сумма: digest от GitHub, иначе файл .sha256 из релиза. Без суммы не ставим.
        var expected = update.expectedDigest
        if expected == nil, let sumAsset = update.checksumFile {
            let (data, _) = try await URLSession.shared.data(from: sumAsset.browserDownloadURL)
            expected = Updates.parseChecksumFile(String(decoding: data, as: UTF8.self))
        }
        guard let expected else { throw UpdateError.noChecksum }

        let (tmp, resp) = try await URLSession.shared.download(from: update.dmg.browserDownloadURL)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.badResponse(code) }
        let dmg = work.appendingPathComponent(update.dmg.name)
        try FileManager.default.moveItem(at: tmp, to: dmg)
        guard try Updates.sha256(of: dmg) == expected else { throw UpdateError.checksumMismatch }

        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path])
        defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        guard let appName = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") })
        else { throw UpdateError.wrongApp("приложение не найдено в образе") }
        let staged = work.appendingPathComponent("Lead Generator.app")
        try Self.run("/usr/bin/ditto", [mount.appendingPathComponent(appName).path, staged.path])

        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.wrongApp("другой идентификатор приложения")
        }
        guard (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == update.version else {
            throw UpdateError.wrongApp("версия внутри не совпадает с версией релиза")
        }
        return staged
    }

    /// Заменяет приложение после выхода и запускает новую версию.
    private func relaunch(replacingWith staged: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            // Нет прав на папку с приложением: открываем образ, пользователь перетащит сам.
            NSWorkspace.shared.open(staged.deletingLastPathComponent().appendingPathComponent(pending?.dmg.name ?? ""))
            throw UpdateError.cannotInstall("нет прав на запись в \(parent.path). Установщик открыт: перетащите приложение в «Программы» вручную")
        }
        // Скрипт ждёт выхода приложения, меняет пакет целиком и запускает новую версию.
        // При ошибке возвращает прежнюю версию.
        let script = """
        #!/bin/sh
        PID="$1"; NEW="$2"; TARGET="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        rm -rf "$TARGET.update" "$TARGET.previous"
        /usr/bin/ditto "$NEW" "$TARGET.update" || exit 1
        mv "$TARGET" "$TARGET.previous" || exit 1
        if mv "$TARGET.update" "$TARGET"; then
          rm -rf "$TARGET.previous"
        else
          mv "$TARGET.previous" "$TARGET"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        /usr/bin/open "$TARGET"
        """
        let scriptURL = staged.deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path]
        try p.run()
        SessionModel.shared.current?.shutdown()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.cannotInstall("\(URL(fileURLWithPath: tool).lastPathComponent) завершился с кодом \(p.terminationStatus)")
        }
        return p.terminationStatus
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
