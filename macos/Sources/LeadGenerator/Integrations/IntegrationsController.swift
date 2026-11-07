import AppKit
import Foundation
import LeadGenCore
import Observation

/// Подключённые облачные диски пользователя: вход, отключение, выгрузка копии базы.
/// Токены и пароли — только в Связке ключей (запись на пользователя и сервис).
@MainActor @Observable
final class IntegrationsController {
    let user: String
    private(set) var connections: [DriveService: DriveConnection] = [:]
    /// Ключи приложений, введённые пользователем («Добавить ключ»).
    private(set) var keys: [OAuthProvider: OAuthKey] = [:]
    /// Сервис, у которого идёт вход или выгрузка.
    private(set) var busy: DriveService? = nil
    var message: String? = nil
    var error: String? = nil
    private let inert: Bool
    @ObservationIgnored private var loopback: OAuthLoopback?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(user: String, inert: Bool = false) {
        self.user = user
        self.inert = inert
        reload()
    }

    func reload() {
        guard !inert else { return }
        var found: [DriveService: DriveConnection] = [:]
        for s in DriveService.allCases {
            if let c = DriveConnection.decode(Keychain.get(DriveConnection.keychainAccount(s, user: user))) { found[s] = c }
        }
        connections = found
        var stored: [OAuthProvider: OAuthKey] = [:]
        for p in OAuthProvider.allCases {
            if let k = OAuthKey.decode(Keychain.get(p.keychainAccount)) { stored[p] = k }
        }
        keys = stored
    }

    /// Клиент OAuth: ключ сборки или введённый вручную.
    func oauthClient(_ p: OAuthProvider) -> OAuthClient? { OAuthClient.resolve(p, stored: keys[p]) }

    /// Ключ вшит в сборку: менять и удалять его из приложения нельзя.
    func isBuiltIn(_ p: OAuthProvider) -> Bool { OAuthClient.fromBundle(p) != nil }

    /// Сохраняет ключ. Возвращает текст ошибки или nil.
    @discardableResult
    func saveKey(_ key: OAuthKey, for p: OAuthProvider) -> String? {
        let clean = OAuthKey(clientID: key.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                             clientSecret: p.clientSecretKey == nil ? nil : key.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines))
        if let problem = clean.problem(for: p) { return problem }
        guard !inert else { keys[p] = clean; return nil }
        guard Keychain.set(p.keychainAccount, clean.encoded()) else { return "Не удалось сохранить ключ в Связке ключей" }
        keys[p] = clean
        message = "Ключ сохранён"
        return nil
    }

    /// Удаляет введённый ключ и подключения, сделанные с ним: токены без ключа бесполезны.
    func removeKey(for p: OAuthProvider) {
        if !inert { Keychain.set(p.keychainAccount, "") }
        keys[p] = nil
        for s in DriveService.allCases where s.auth == .oauth(p) && isConnected(s) { disconnect(s) }
        message = "Ключ удалён"
    }

    func isConnected(_ s: DriveService) -> Bool { connections[s] != nil }

    /// Можно ли подключить сервис в этой сборке (для OAuth нужен ключ приложения).
    func isAvailable(_ s: DriveService) -> Bool {
        if case .oauth(let p) = s.auth { return oauthClient(p) != nil }
        return true
    }

    private func save(_ c: DriveConnection) {
        Keychain.set(DriveConnection.keychainAccount(c.service, user: user), c.encoded())
        connections[c.service] = c
    }

    func disconnect(_ s: DriveService) {
        Keychain.set(DriveConnection.keychainAccount(s, user: user), "")
        connections[s] = nil
        message = "\(s.title) отключён"
    }

    /// Вход через браузер в отдельной задаче, чтобы его можно было отменить кнопкой «Отмена».
    func startOAuth(_ s: DriveService) {
        task?.cancel()
        task = Task { await connectOAuth(s) }
    }

    /// Отмена входа: сервер возврата закрывается, порт освобождается.
    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: Вход через браузер (OAuth + PKCE)

    func connectOAuth(_ s: DriveService) async {
        guard case .oauth(let provider) = s.auth else { return }
        guard let client = oauthClient(provider) else {
            error = IntegrationError.notConfigured(provider).localizedDescription
            return
        }
        busy = s
        error = nil
        defer { busy = nil; loopback = nil }
        do {
            let verifier = OAuthFlow.randomVerifier()
            let state = OAuthFlow.randomVerifier(length: 43)
            let lb = OAuthLoopback()
            loopback = lb
            async let callback = lb.waitForCallback()
            // Небольшая пауза, чтобы сервер успел открыть порт до перехода браузера.
            try await Task.sleep(nanoseconds: 200_000_000)
            NSWorkspace.shared.open(OAuthFlow.authorizeURL(client, state: state, codeChallenge: PKCE.challenge(verifier)))
            let answer = try await callback
            let code = try answer.validated(state: state)
            NSApp.activate(ignoringOtherApps: true)
            let (data, response) = try await URLSession.shared.data(for: OAuthFlow.tokenRequest(client, code: code, verifier: verifier))
            try Self.check(response, data)
            let token = try OAuthFlow.parseToken(data)
            save(DriveConnection(service: s, token: token))
            message = "\(s.title) подключён"
        } catch is CancellationError {
        } catch {
            self.error = "\(s.title): \(error.localizedDescription)"
        }
    }

    // MARK: WebDAV

    /// Проверяет адрес и пароль запросом PROPFIND и сохраняет подключение.
    func connectWebDAV(_ s: DriveService, url: String, login: String, password: String) async -> Bool {
        busy = s
        error = nil
        defer { busy = nil }
        do {
            let base = try DriveUpload.webdavBase(url)
            var r = URLRequest(url: base, timeoutInterval: 20)
            r.httpMethod = "PROPFIND"
            r.setValue("0", forHTTPHeaderField: "Depth")
            if !login.isEmpty { r.setValue(DriveUpload.basicAuth(login, password), forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: r)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw IntegrationError.http(status, "неверный логин или пароль приложения") }
            guard (200..<300).contains(status) || status == 207 else { try Self.check(response, data); return false }
            save(DriveConnection(service: s, webdavURL: base.absoluteString, login: login, password: password))
            message = "\(s.title) подключён"
            return true
        } catch {
            self.error = "\(s.title): \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Выгрузка

    /// Выгружает файл (копию базы) на диск. OAuth-токен при необходимости обновляется.
    func upload(_ file: URL, to s: DriveService) async {
        guard var c = connections[s] else { return }
        busy = s
        error = nil
        defer { busy = nil }
        do {
            if case .oauth(let provider) = s.auth, let token = c.token, token.isExpired() {
                guard let client = oauthClient(provider) else { throw IntegrationError.notConfigured(provider) }
                guard let refresh = token.refreshToken else { throw IntegrationError.reauthorize }
                let (data, response) = try await URLSession.shared.data(for: OAuthFlow.refreshRequest(client, refreshToken: refresh))
                if (response as? HTTPURLResponse)?.statusCode == 400 || (response as? HTTPURLResponse)?.statusCode == 401 {
                    throw IntegrationError.reauthorize
                }
                try Self.check(response, data)
                c.token = try OAuthFlow.parseToken(data, previousRefresh: refresh)
                save(c)
            }
            let data = try Data(contentsOf: file)
            for request in try DriveUpload.requests(for: c, fileName: file.lastPathComponent, data: data) {
                let (body, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 { throw IntegrationError.reauthorize }
                guard DriveUpload.isSuccess(request, status: status) else {
                    throw IntegrationError.http(status, String(decoding: body.prefix(200), as: UTF8.self))
                }
            }
            message = "Копия «\(file.lastPathComponent)» выгружена в \(s.title)"
        } catch {
            self.error = "\(s.title): \(error.localizedDescription)"
        }
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw IntegrationError.badResponse("нет ответа") }
        guard (200..<300).contains(http.statusCode) else {
            throw IntegrationError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}
