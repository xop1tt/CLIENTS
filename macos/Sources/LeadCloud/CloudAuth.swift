import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Пользователь облака (Supabase Auth).
public struct CloudUser: Codable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var newEmail: String?
    public var emailConfirmedAt: String?
    public var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case newEmail = "new_email"
        case emailConfirmedAt = "email_confirmed_at"
        case createdAt = "created_at"
    }

    public init(id: String, email: String, newEmail: String? = nil, emailConfirmedAt: String? = nil, createdAt: String? = nil) {
        self.id = id; self.email = email; self.newEmail = newEmail
        self.emailConfirmedAt = emailConfirmedAt; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        newEmail = (try? c.decodeIfPresent(String.self, forKey: .newEmail)).flatMap { $0?.isEmpty == false ? $0 : nil }
        emailConfirmedAt = try? c.decodeIfPresent(String.self, forKey: .emailConfirmedAt)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    public var isConfirmed: Bool { emailConfirmedAt?.isEmpty == false }
}

/// Сессия: токены и пользователь. Хранится только в Связке ключей (через `SessionStore`).
public struct CloudSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var user: CloudUser

    public func expiresSoon(_ now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) < margin
    }
}

/// Где хранится сессия между запусками. В приложении — Связка ключей macOS.
public protocol SessionStore: Sendable {
    func load() -> CloudSession?
    func save(_ session: CloudSession?)
}

/// Чем закончилось открытие ссылки из письма.
public enum CallbackResult: Equatable, Sendable {
    case signedIn(type: String)   // signup, recovery, email_change, …
    case message(String)          // например, «подтвердите ссылку во втором письме»
}

/// Операции, на которые приложение запрашивает письмо (лимиты проверяет сервер).
public enum MailAction: String, Sendable {
    case signup, recovery
    case emailChange = "email_change"
}

/// Вход, регистрация, восстановление и смена пароля, смена адреса — через Supabase Auth.
///
/// Каждое письмо сначала разрешает функция email-gate (лимиты устройства, IP, адреса и общий
/// суточный), и только потом приложение просит Auth отправить письмо. Обычный вход писем не
/// тратит. Токены обновляются автоматически; при отзыве сессии сервером — `sessionExpired`.
public actor CloudAuth {
    public let config: CloudConfig
    let transport: CloudTransport
    let store: SessionStore
    let deviceID: String
    public private(set) var session: CloudSession?
    private var refreshTask: Task<CloudSession, Error>?

    public init(config: CloudConfig, transport: CloudTransport = URLSessionCloudTransport(),
                store: SessionStore, deviceID: String) {
        self.config = config
        self.transport = transport
        self.store = store
        self.deviceID = deviceID
        self.session = store.load()
    }

    public var user: CloudUser? { session?.user }

    // MARK: Запросы

    func request(_ method: String, _ path: String, body: Any? = nil, token: String? = nil,
                 extraHeaders: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: config.url.absoluteString + path) else { throw CloudError.server("bad url") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await transport.send(r)
    }

    func auth(_ method: String, _ path: String, body: Any? = nil, token: String? = nil) async throws -> Data {
        let (data, res) = try await request(method, "/auth/v1" + path, body: body, token: token)
        guard (200..<300).contains(res.statusCode) else { throw CloudError.fromAuth(status: res.statusCode, data: data) }
        return data
    }

    /// Разрешение на письмо от email-gate. Отказ — понятное сообщение с временем ожидания.
    func gate(_ action: MailAction, email: String) async throws {
        let (data, res) = try await request("POST", "/functions/v1/email-gate",
                                            body: ["action": action.rawValue, "email": email, "device_id": deviceID])
        if (200..<300).contains(res.statusCode) { return }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if obj["reason"] as? String == "invalid_email" { throw CloudError.invalidEmail }
        if let m = obj["message"] as? String { throw CloudError.rateLimited(m) }
        throw CloudError.server("HTTP \(res.statusCode)")
    }

    private func take(_ data: Data) throws -> CloudSession {
        struct Token: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
            let expires_at: Double?
            let user: CloudUser
        }
        let t = try JSONDecoder().decode(Token.self, from: data)
        let exp = t.expires_at.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(t.expires_in ?? 3600)
        let s = CloudSession(accessToken: t.access_token, refreshToken: t.refresh_token, expiresAt: exp, user: t.user)
        setSession(s)
        return s
    }

    private func setSession(_ s: CloudSession?) {
        session = s
        store.save(s)
    }

    private func validEmail(_ raw: String) throws -> String {
        guard let e = Validation.normalizedEmail(raw) else { throw CloudError.invalidEmail }
        return e
    }

    // MARK: Регистрация

    /// Регистрация. Если адрес уже занят, ответ такой же, как для нового: письмо просто не придёт.
    public func signUp(email raw: String, password: String) async throws {
        let email = try validEmail(raw)
        if let p = Validation.passwordProblem(password) { throw CloudError.weakPassword(p) }
        try await gate(.signup, email: email)
        let data = try await auth("POST", "/signup?redirect_to=\(Self.redirectParam)",
                                  body: ["email": email, "password": password,
                                         "options": ["email_redirect_to": CloudConfig.redirectURL]])
        // Если на сервере выключено подтверждение почты, Auth сразу возвращает сессию.
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] != nil { _ = try take(data) }
    }

    public func resendConfirmation(email raw: String) async throws {
        let email = try validEmail(raw)
        try await gate(.signup, email: email)
        _ = try await auth("POST", "/resend", body: ["type": "signup", "email": email,
                                                     "options": ["email_redirect_to": CloudConfig.redirectURL]])
    }

    /// Подтверждение кодом из письма (регистрация, восстановление, смена адреса).
    @discardableResult
    public func verify(email raw: String, code rawCode: String, type: String) async throws -> CloudSession? {
        let email = try validEmail(raw)
        guard let code = Validation.code(rawCode) else { throw CloudError.invalidCode }
        let data = try await auth("POST", "/verify", body: ["type": type, "email": email, "token": code])
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] != nil {
            return try take(data)
        }
        return nil
    }

    // MARK: Вход и выход

    @discardableResult
    public func signIn(email raw: String, password: String) async throws -> CloudSession {
        let email = try validEmail(raw)
        guard !password.isEmpty else { throw CloudError.invalidCredentials }
        let data = try await auth("POST", "/token?grant_type=password", body: ["email": email, "password": password])
        return try take(data)
    }

    /// Выход: сессия отзывается на сервере (если есть сеть) и всегда удаляется с этого Mac.
    public func signOut() async {
        if let s = session { _ = try? await auth("POST", "/logout?scope=local", token: s.accessToken) }
        setSession(nil)
    }

    /// Действующая сессия: при скором истечении токен обновляется. Параллельные вызовы
    /// ждут одно обновление (refresh-токен одноразовый). Отозванная сессия — `sessionExpired`.
    public func validSession() async throws -> CloudSession {
        guard let s = session else { throw CloudError.sessionExpired }
        if !s.expiresSoon() { return s }
        return try await refresh()
    }

    @discardableResult
    public func refresh() async throws -> CloudSession {
        if let t = refreshTask { return try await t.value }
        guard let s = session else { throw CloudError.sessionExpired }
        let task = Task { () throws -> CloudSession in
            let data = try await self.auth("POST", "/token?grant_type=refresh_token", body: ["refresh_token": s.refreshToken])
            return try self.take(data)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch let e as CloudError {
            if e == .sessionExpired || e == .invalidCredentials || isAuthRejection(e) { setSession(nil); throw CloudError.sessionExpired }
            throw e
        }
    }

    private func isAuthRejection(_ e: CloudError) -> Bool {
        if case .server(let m) = e { return m.lowercased().contains("refresh token") }
        return false
    }

    /// Запрос с токеном пользователя; при 401 один раз обновляет токен и повторяет.
    public func authorized(_ method: String, _ path: String, body: Any? = nil,
                           headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var s = try await validSession()
        var (data, res) = try await request(method, path, body: body, token: s.accessToken, extraHeaders: headers)
        if res.statusCode == 401 {
            s = try await refresh()
            (data, res) = try await request(method, path, body: body, token: s.accessToken, extraHeaders: headers)
            if res.statusCode == 401 { setSession(nil); throw CloudError.sessionExpired }
        }
        return (data, res)
    }

    /// Свежие данные пользователя с сервера (подтверждение почты, новый адрес).
    @discardableResult
    public func reloadUser() async throws -> CloudUser {
        let (data, res) = try await authorized("GET", "/auth/v1/user")
        guard (200..<300).contains(res.statusCode) else {
            let e = CloudError.fromAuth(status: res.statusCode, data: data)
            if e == .sessionExpired { setSession(nil) }
            throw e
        }
        let u = try JSONDecoder().decode(CloudUser.self, from: data)
        if var s = session { s.user = u; setSession(s) }
        return u
    }

    // MARK: Пароль

    public func requestPasswordReset(email raw: String) async throws {
        let email = try validEmail(raw)
        try await gate(.recovery, email: email)
        _ = try await auth("POST", "/recover?redirect_to=\(Self.redirectParam)", body: ["email": email])
    }

    /// Новый пароль после входа по коду восстановления. Остальные сессии завершаются.
    public func setNewPassword(_ password: String) async throws {
        if let p = Validation.passwordProblem(password) { throw CloudError.weakPassword(p) }
        let (data, res) = try await authorized("PUT", "/auth/v1/user", body: ["password": password])
        guard (200..<300).contains(res.statusCode) else { throw CloudError.fromAuth(status: res.statusCode, data: data) }
        try? await signOutOthers()
        _ = try? await refresh()
    }

    /// Смена пароля из настроек: сначала текущий пароль проверяется входом на сервере.
    public func changePassword(current: String, new: String) async throws {
        guard let email = session?.user.email else { throw CloudError.sessionExpired }
        if let p = Validation.passwordProblem(new) { throw CloudError.weakPassword(p) }
        do { try await signIn(email: email, password: current) } catch CloudError.invalidCredentials {
            throw CloudError.server("текущий пароль неверный")
        }
        try await setNewPassword(new)
    }

    func signOutOthers() async throws {
        let (data, res) = try await authorized("POST", "/auth/v1/logout?scope=others")
        guard (200..<300).contains(res.statusCode) else { throw CloudError.fromAuth(status: res.statusCode, data: data) }
    }

    // MARK: Адрес почты

    /// Смена адреса: нужен текущий пароль. Письма уходят на оба адреса; адрес меняется
    /// только после подтверждения обоих (Secure email change в Supabase).
    public func changeEmail(to raw: String, password: String) async throws {
        guard let current = session?.user.email else { throw CloudError.sessionExpired }
        let new = try validEmail(raw)
        guard new != current.lowercased() else { throw CloudError.server("это текущий адрес") }
        do { try await signIn(email: current, password: password) } catch CloudError.invalidCredentials {
            throw CloudError.server("пароль неверный")
        }
        try await gate(.emailChange, email: current)
        let (data, res) = try await authorized("PUT", "/auth/v1/user?redirect_to=\(Self.redirectParam)", body: ["email": new])
        guard (200..<300).contains(res.statusCode) else { throw CloudError.fromAuth(status: res.statusCode, data: data) }
        _ = try? await reloadUser()
    }

    /// Повторить письма смены адреса (с соблюдением лимитов).
    public func resendEmailChange() async throws {
        guard let current = session?.user.email, let new = session?.user.newEmail else { throw CloudError.sessionExpired }
        try await gate(.emailChange, email: current)
        _ = try await auth("POST", "/resend", body: ["type": "email_change", "email": new])
    }

    public func confirmEmailChange(email: String, code: String) async throws {
        try await verify(email: email, code: code, type: "email_change")
        _ = try? await reloadUser()
    }

    // MARK: Удаление учётной записи

    /// Удаляет учётную запись и все данные в облаке. Пароль проверяется заново.
    public func deleteAccount(password: String) async throws {
        guard let email = session?.user.email else { throw CloudError.sessionExpired }
        do { try await signIn(email: email, password: password) } catch CloudError.invalidCredentials {
            throw CloudError.server("пароль неверный")
        }
        let (data, res) = try await authorized("POST", "/functions/v1/delete-account")
        guard (200..<300).contains(res.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CloudError.server((obj?["message"] as? String) ?? "HTTP \(res.statusCode)")
        }
        setSession(nil)
    }

    // MARK: Ссылки из писем

    /// Обработка leadgenerator://auth/callback#access_token=…&refresh_token=…&type=…
    public func handleCallback(_ url: URL) async throws -> CallbackResult {
        let params = Self.fragmentParams(url)
        if let err = params["error_description"] ?? params["error"] {
            if params["error_code"] == "otp_expired" { throw CloudError.invalidCode }
            throw CloudError.server(err)
        }
        if let access = params["access_token"], let refresh = params["refresh_token"] {
            let exp = params["expires_at"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                ?? Date().addingTimeInterval(params["expires_in"].flatMap(Double.init) ?? 3600)
            let placeholder = CloudUser(id: "", email: "")
            setSession(CloudSession(accessToken: access, refreshToken: refresh, expiresAt: exp, user: placeholder))
            do { _ = try await reloadUser() } catch { setSession(nil); throw error }
            return .signedIn(type: params["type"] ?? "")
        }
        if let m = params["message"] { return .message(m) }
        throw CloudError.server("ссылка не распознана")
    }

    static func fragmentParams(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for source in [url.fragment, URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery] {
            for pair in (source ?? "").split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let k = kv.first?.removingPercentEncoding else { continue }
                let v = kv.count > 1 ? kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1] : ""
                if out[k] == nil { out[k] = v }
            }
        }
        return out
    }

    static let redirectParam = CloudConfig.redirectURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
}
