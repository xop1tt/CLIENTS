import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Подключаемые сервисы: облачные диски, к которым приложение само входит по кнопке
// «Подключиться» (OAuth в браузере или WebDAV с паролем приложения), и куда выгружает
// резервные копии базы. Здесь каталог, адреса, разбор ответов и запросы выгрузки — только
// Foundation, без сети, чтобы всё проверялось тестами и собиралось на Linux. Сеть, браузер,
// Связка ключей и SHA-256 для PKCE — в приложении.

/// Облачный диск, который подключается из приложения.
public enum DriveService: String, CaseIterable, Identifiable, Codable, Sendable {
    case googleDrive, dropbox, oneDrive, yandexDisk, mega, pCloud, webdav
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .googleDrive: return "Google Диск"
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        case .yandexDisk: return "Яндекс Диск"
        case .mega: return "MEGA"
        case .pCloud: return "pCloud"
        case .webdav: return "WebDAV / Nextcloud"
        }
    }

    public var subtitle: String {
        switch self {
        case .googleDrive: return "Вход через Google, доступ только к файлам приложения"
        case .dropbox: return "Вход через Dropbox, отдельная папка приложения"
        case .oneDrive: return "Вход через Microsoft, папка приложения"
        case .yandexDisk: return "Логин и пароль приложения Яндекса (WebDAV)"
        case .mega: return "Через MEGAcmd: команда mega-webdav открывает папку по WebDAV"
        case .pCloud: return "Логин и пароль pCloud (WebDAV)"
        case .webdav: return "Nextcloud, ownCloud, Synology, Keenetic и другие"
        }
    }

    public var auth: DriveAuth {
        switch self {
        case .googleDrive: return .oauth(.google)
        case .dropbox: return .oauth(.dropbox)
        case .oneDrive: return .oauth(.microsoft)
        case .yandexDisk: return .webdav(defaultURL: "https://webdav.yandex.ru", passwordPage: URL(string: "https://id.yandex.ru/security/app-passwords"))
        case .mega: return .webdav(defaultURL: "http://127.0.0.1:4443/", passwordPage: URL(string: "https://mega.io/cmd"))
        case .pCloud: return .webdav(defaultURL: "https://ewebdav.pcloud.com", passwordPage: nil)
        case .webdav: return .webdav(defaultURL: "", passwordPage: nil)
        }
    }

    /// MEGAcmd раздаёт WebDAV только на этом Mac и без пароля.
    public var passwordOptional: Bool { self == .mega }
}

public enum DriveAuth: Equatable, Sendable {
    case oauth(OAuthProvider)
    case webdav(defaultURL: String, passwordPage: URL?)
}

/// Поставщик OAuth 2.0 с PKCE. Идентификатор клиента — публичный, но он свой у каждого
/// зарегистрированного приложения: его создаёт владелец репозитория и передаёт при сборке
/// (переменные репозитория → Info.plist). В коде ключей нет.
public enum OAuthProvider: String, Sendable, CaseIterable {
    case google, dropbox, microsoft

    public var authorizeURL: URL {
        switch self {
        case .google: return URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .dropbox: return URL(string: "https://www.dropbox.com/oauth2/authorize")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        }
    }

    public var tokenURL: URL {
        switch self {
        case .google: return URL(string: "https://oauth2.googleapis.com/token")!
        case .dropbox: return URL(string: "https://api.dropboxapi.com/oauth2/token")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        }
    }

    public var scope: String? {
        switch self {
        case .google: return "https://www.googleapis.com/auth/drive.file"
        case .dropbox: return nil // права задаются в консоли Dropbox (App folder, files.content.write)
        case .microsoft: return "Files.ReadWrite.AppFolder offline_access"
        }
    }

    /// Ключ Info.plist с идентификатором клиента и имя переменной репозитория для сборки.
    public var clientIDKey: String {
        switch self {
        case .google: return "LGGoogleClientID"
        case .dropbox: return "LGDropboxAppKey"
        case .microsoft: return "LGMicrosoftClientID"
        }
    }

    public var buildVariable: String {
        switch self {
        case .google: return "GOOGLE_OAUTH_CLIENT_ID"
        case .dropbox: return "DROPBOX_APP_KEY"
        case .microsoft: return "MICROSOFT_CLIENT_ID"
        }
    }

    /// Консоль, где создаётся приложение и берётся ключ.
    public var consolePage: URL {
        switch self {
        case .google: return URL(string: "https://console.cloud.google.com/apis/credentials")!
        case .dropbox: return URL(string: "https://www.dropbox.com/developers/apps")!
        case .microsoft: return URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!
        }
    }

    /// Как называется поле с идентификатором в консоли.
    public var clientIDLabel: String {
        switch self {
        case .google: return "Client ID"
        case .dropbox: return "App key"
        case .microsoft: return "Application (client) ID"
        }
    }

    /// Запись в Связке ключей с ключом, введённым пользователем. Общая для всех учётных записей
    /// приложения на этом Mac: ключ приложения принадлежит владельцу Mac, а не учётной записи.
    public var keychainAccount: String { "integration.oauthkey.\(rawValue)" }

    /// Google для приложений «Desktop» требует client_secret и при PKCE; он не считается
    /// секретом (Google: installed apps), но всё равно приходит из секрета репозитория, не из кода.
    public var clientSecretKey: String? { self == .google ? "LGGoogleClientSecret" : nil }

    /// Дополнительные параметры, чтобы получить refresh_token.
    var extraAuthorizeParams: [(String, String)] {
        switch self {
        case .google: return [("access_type", "offline"), ("prompt", "consent")]
        case .dropbox: return [("token_access_type", "offline")]
        case .microsoft: return [("prompt", "select_account")]
        }
    }
}

/// Ключ OAuth-приложения, который пользователь ввёл в приложении («Добавить ключ»).
/// Хранится только в Связке ключей.
public struct OAuthKey: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Подходит ли ключ поставщику: идентификатор без пробелов, для Google ещё и секрет.
    public func problem(for provider: OAuthProvider) -> String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return "Введите \(provider.clientIDLabel)" }
        if id.contains(where: { $0.isWhitespace }) || id.hasPrefix("$") { return "\(provider.clientIDLabel) не должен содержать пробелов" }
        if provider.clientSecretKey != nil, (clientSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Для Google нужен ещё Client secret"
        }
        return nil
    }

    public func encoded() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public static func decode(_ text: String?) -> OAuthKey? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthKey.self, from: data)
    }
}

/// Порт и адрес возврата из браузера. Порт постоянный: Dropbox сверяет адрес возврата целиком.
public enum OAuthRedirect {
    public static let port: UInt16 = 47811
    public static let path = "/oauth/callback"
    public static var uri: String { "http://localhost:\(port)\(path)" }
}

/// Данные OAuth-клиента, вшитые при сборке.
public struct OAuthClient: Equatable, Sendable {
    public let provider: OAuthProvider
    public let clientID: String
    public let clientSecret: String?

    public init?(provider: OAuthProvider, clientID: String?, clientSecret: String? = nil) {
        let id = (clientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Пустое значение или не подставленная переменная сборки: подключение недоступно.
        guard !id.isEmpty, !id.hasPrefix("$"), !id.contains(" ") else { return nil }
        self.provider = provider
        self.clientID = id
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = (secret?.isEmpty ?? true) || secret?.hasPrefix("$") == true ? nil : secret
        if provider.clientSecretKey != nil && self.clientSecret == nil { return nil }
    }

    /// Клиент из ключа, введённого пользователем.
    public init?(provider: OAuthProvider, key: OAuthKey) {
        guard key.problem(for: provider) == nil else { return nil }
        self.init(provider: provider, clientID: key.clientID, clientSecret: key.clientSecret)
    }

    /// Ключ, вшитый при сборке, главнее введённого вручную: владелец сборки отвечает за свой ключ.
    public static func resolve(_ provider: OAuthProvider, bundle: Bundle = .main, stored: OAuthKey?) -> OAuthClient? {
        if let built = fromBundle(provider, bundle: bundle) { return built }
        return stored.flatMap { OAuthClient(provider: provider, key: $0) }
    }

    public static func fromBundle(_ provider: OAuthProvider, bundle: Bundle = .main) -> OAuthClient? {
        OAuthClient(provider: provider,
                    clientID: bundle.object(forInfoDictionaryKey: provider.clientIDKey) as? String,
                    clientSecret: provider.clientSecretKey.flatMap { bundle.object(forInfoDictionaryKey: $0) as? String })
    }
}

/// Токены OAuth. Хранятся только в Связке ключей.
public struct OAuthToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Истёк или истечёт в ближайшую минуту.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }
}

public enum IntegrationError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured(OAuthProvider)
    case denied(String)
    case stateMismatch
    case badResponse(String)
    case http(Int, String)
    case invalidURL
    case reauthorize

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let p): return "Не задан ключ приложения (\(p.buildVariable)). Нажмите «Добавить ключ» и введите свой"
        case .denied(let s): return "Вход отменён: \(s)"
        case .stateMismatch: return "Ответ браузера не относится к этому входу. Попробуйте ещё раз"
        case .badResponse(let s): return "Непонятный ответ сервиса: \(s)"
        case let .http(code, s): return "Сервис ответил ошибкой \(code)\(s.isEmpty ? "" : ": " + s)"
        case .invalidURL: return "Неверный адрес сервера. Нужен адрес https:// (или http:// только для этого Mac)"
        case .reauthorize: return "Доступ к диску истёк. Подключите его заново"
        }
    }
}

public enum OAuthFlow {
    /// Адрес страницы входа с PKCE (S256). challenge = base64url(SHA-256(verifier)).
    public static func authorizeURL(_ client: OAuthClient, state: String, codeChallenge: String) -> URL {
        var c = URLComponents(url: client.provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: OAuthRedirect.uri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let scope = client.provider.scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        items += client.provider.extraAuthorizeParams.map { URLQueryItem(name: $0.0, value: $0.1) }
        c.queryItems = items
        return c.url!
    }

    /// Случайная строка для verifier и state: 43–128 символов из [A-Za-z0-9-._~] (RFC 7636).
    public static func randomVerifier(length: Int = 64) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var g = SystemRandomNumberGenerator()
        return String((0..<max(43, min(length, 128))).map { _ in chars[Int(g.next(upperBound: UInt64(chars.count)))] })
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Обмен кода на токены.
    public static func tokenRequest(_ client: OAuthClient, code: String, verifier: String) -> URLRequest {
        var params = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", OAuthRedirect.uri),
                      ("client_id", client.clientID), ("code_verifier", verifier)]
        if let s = client.clientSecret { params.append(("client_secret", s)) }
        return formRequest(client.provider.tokenURL, params)
    }

    public static func refreshRequest(_ client: OAuthClient, refreshToken: String) -> URLRequest {
        var params = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", client.clientID)]
        if let s = client.clientSecret { params.append(("client_secret", s)) }
        if let scope = client.provider.scope, client.provider == .microsoft { params.append(("scope", scope)) }
        return formRequest(client.provider.tokenURL, params)
    }

    /// Ответ сервера токенов. refresh_token при обновлении может не прийти — тогда остаётся прежний.
    public static func parseToken(_ data: Data, previousRefresh: String? = nil, now: Date = Date()) throws -> OAuthToken {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let err = obj["error"] as? String {
            if err == "invalid_grant" { throw IntegrationError.reauthorize }
            throw IntegrationError.denied((obj["error_description"] as? String) ?? err)
        }
        guard let access = obj["access_token"] as? String, !access.isEmpty else { throw IntegrationError.badResponse("нет access_token") }
        let expires = (obj["expires_in"] as? NSNumber)?.doubleValue ?? (obj["expires_in"] as? String).flatMap(Double.init)
        return OAuthToken(accessToken: access, refreshToken: (obj["refresh_token"] as? String) ?? previousRefresh,
                          expiresAt: expires.map { now.addingTimeInterval($0) })
    }

    static func formRequest(_ url: URL, _ params: [(String, String)]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Data(params.map { "\(ContactLinks.encode($0.0))=\(ContactLinks.encode($0.1))" }.joined(separator: "&").utf8)
        return r
    }
}

/// Возврат из браузера на http://localhost:47811/oauth/callback?code=…&state=….
public struct OAuthCallback: Equatable, Sendable {
    public let code: String?
    public let state: String?
    public let error: String?

    /// Разбирает первую строку HTTP-запроса («GET /oauth/callback?… HTTP/1.1»). Чужой путь — nil.
    public static func parse(requestLine: String) -> OAuthCallback? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let c = URLComponents(string: "http://localhost" + parts[1]),
              c.path == OAuthRedirect.path else { return nil }
        func q(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        return OAuthCallback(code: q("code"), state: q("state"), error: q("error_description") ?? q("error"))
    }

    /// Код, если вход разрешён и state совпал.
    public func validated(state expected: String) throws -> String {
        if let error { throw IntegrationError.denied(error) }
        guard state == expected else { throw IntegrationError.stateMismatch }
        guard let code, !code.isEmpty else { throw IntegrationError.badResponse("нет кода авторизации") }
        return code
    }
}

/// Сохранённое подключение диска (целиком в Связке ключей).
public struct DriveConnection: Codable, Equatable, Sendable {
    public var service: DriveService
    public var token: OAuthToken?
    public var webdavURL: String?
    public var login: String?
    public var password: String?
    public var connectedAt: Date

    public init(service: DriveService, token: OAuthToken? = nil, webdavURL: String? = nil, login: String? = nil,
                password: String? = nil, connectedAt: Date = Date()) {
        self.service = service
        self.token = token
        self.webdavURL = webdavURL
        self.login = login
        self.password = password
        self.connectedAt = connectedAt
    }

    public func encoded() -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public static func decode(_ text: String?) -> DriveConnection? {
        guard let data = text?.data(using: .utf8) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(DriveConnection.self, from: data)
    }

    /// Имя записи в Связке ключей: своё для каждого пользователя приложения и сервиса.
    public static func keychainAccount(_ service: DriveService, user: String) -> String {
        "integration.\(service.rawValue).\(user.lowercased())"
    }
}

/// Запросы выгрузки файла. Папка на диске — «Customers».
public enum DriveUpload {
    public static let folder = "Customers"

    /// Проверка адреса WebDAV: https, либо http только на этом Mac (MEGAcmd).
    public static func webdavBase(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasSuffix("/") { s += "/" }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(), u.user == nil else {
            throw IntegrationError.invalidURL
        }
        guard scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw IntegrationError.invalidURL
        }
        return u
    }

    public static func basicAuth(_ login: String, _ password: String) -> String {
        "Basic " + Data("\(login):\(password)".utf8).base64EncodedString()
    }

    /// Запросы по порядку: для WebDAV сначала MKCOL папки (405 — папка уже есть), потом PUT файла.
    public static func requests(for c: DriveConnection, fileName: String, data: Data) throws -> [URLRequest] {
        let name = fileName.replacingOccurrences(of: "/", with: "_")
        switch c.service.auth {
        case .webdav:
            let base = try webdavBase(c.webdavURL ?? "")
            let dir = base.appendingPathComponent(folder, isDirectory: true)
            var mk = URLRequest(url: dir)
            mk.httpMethod = "MKCOL"
            var put = URLRequest(url: dir.appendingPathComponent(name))
            put.httpMethod = "PUT"
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            put.httpBody = data
            if let login = c.login, !login.isEmpty {
                let auth = basicAuth(login, c.password ?? "")
                mk.setValue(auth, forHTTPHeaderField: "Authorization")
                put.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            return [mk, put]
        case .oauth(let provider):
            guard let token = c.token else { throw IntegrationError.reauthorize }
            var r: URLRequest
            switch provider {
            case .google:
                r = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
                r.httpMethod = "POST"
                let boundary = "lg-" + UUID().uuidString
                let meta = (try? JSONSerialization.data(withJSONObject: ["name": "\(folder) \(name)"])) ?? Data()
                var body = Data()
                body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
                body.append(meta)
                body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
                body.append(data)
                body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                r.httpBody = body
            case .dropbox:
                r = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
                r.httpMethod = "POST"
                r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                r.setValue(asciiJSON(["path": "/\(folder)/\(name)", "mode": "add", "autorename": true]), forHTTPHeaderField: "Dropbox-API-Arg")
                r.httpBody = data
            case .microsoft:
                let path = "\(folder)/\(name)".addingPercentEncoding(withAllowedCharacters: ContactLinks.unreserved.union(CharacterSet(charactersIn: "/"))) ?? name
                r = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(path):/content")!)
                r.httpMethod = "PUT"
                r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                r.httpBody = data
            }
            r.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            return [r]
        }
    }

    /// Ответ на запрос выгрузки — успех? MKCOL: 405/301 значат «папка уже есть».
    public static func isSuccess(_ request: URLRequest, status: Int) -> Bool {
        if request.httpMethod == "MKCOL" { return (200..<300).contains(status) || status == 405 || status == 301 }
        return (200..<300).contains(status)
    }

    /// JSON только из ASCII: Dropbox требует экранировать не-ASCII символы в заголовке (\uXXXX).
    public static func asciiJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var out = ""
        for unit in text.utf16 {
            if unit < 0x80 { out.unicodeScalars.append(Unicode.Scalar(unit)!) } else { out += String(format: "\\u%04x", unit) }
        }
        return out.replacingOccurrences(of: "\\/", with: "/")
    }
}
