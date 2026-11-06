// Только Apple-платформы (CommonCrypto, Связка ключей). Остальное ядро собирается и на Linux,
// где на тестовом стенде проверяется облачная синхронизация.
#if canImport(Security)
import CommonCrypto
import Foundation
import Security

/// Учётная запись. Пароль не хранится — только соль и хэш PBKDF2.
public struct UserAccount: Identifiable, Hashable, Sendable {
    public var id: String { username }
    public var username: String
    public var createdAt: Date?
    public var lastLoginAt: Date?
}

public enum AuthError: LocalizedError, Equatable {
    case invalidUsername
    case weakPassword
    case passwordsDiffer
    case exists
    case wrongCredentials
    case tooManyAttempts(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidUsername: return "Имя пользователя: от 3 до 32 символов — буквы, цифры, точка, дефис или подчёркивание, начинается с буквы или цифры."
        case .weakPassword: return "Пароль должен быть не короче 8 символов."
        case .passwordsDiffer: return "Пароли не совпадают."
        case .exists: return "Такое имя пользователя уже занято."
        case .wrongCredentials: return "Неверное имя пользователя или пароль."
        case .tooManyAttempts(let s): return "Слишком много попыток. Повторите через \(s) с."
        }
    }
}

/// Регистрация и вход. Сейчас — локально, позже то же самое сделает сервер.
public protocol AuthService: AnyObject {
    var hasUsers: Bool { get }
    func register(username: String, password: String) throws -> UserAccount
    func login(username: String, password: String) throws -> UserAccount
    func account(_ username: String) -> UserAccount?
    func changePassword(username: String, old: String, new: String) throws
    /// Папка с данными пользователя (его база лидов).
    func dataDirectory(for username: String) -> URL
}

/// Локальные учётные записи в accounts.db рядом с базами пользователей.
public final class LocalAuthService: AuthService {
    public let root: URL
    private let db: SQLiteDB
    static let iterations: UInt32 = 310_000
    private var failures: [String: (count: Int, until: Date)] = [:]

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try SQLiteDB(path: root.appendingPathComponent("accounts.db").path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS users (
            username_key TEXT PRIMARY KEY,
            username TEXT NOT NULL,
            salt TEXT NOT NULL,
            hash TEXT NOT NULL,
            iterations INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            last_login_at TEXT
        );
        """)
    }

    private static let nameRx = try! NSRegularExpression(pattern: #"^[\p{L}\p{N}][\p{L}\p{N}_.-]{2,31}$"#)

    public static func normalized(_ username: String) -> String? {
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = NSRange(u.startIndex..<u.endIndex, in: u)
        return nameRx.firstMatch(in: u, range: r) != nil ? u : nil
    }

    static func key(_ username: String) -> String { username.lowercased() }

    public var hasUsers: Bool { ((try? db.scalar("SELECT COUNT(*) FROM users"))?.int ?? 0) > 0 }

    public func account(_ username: String) -> UserAccount? {
        guard let r = try? db.query("SELECT username, created_at, last_login_at FROM users WHERE username_key=?",
                                    [.text(Self.key(username))]).first else { return nil }
        return UserAccount(username: r["username"]?.string ?? username, createdAt: ISODate.parse(r["created_at"]?.string),
                           lastLoginAt: ISODate.parse(r["last_login_at"]?.string))
    }

    /// Все локальные учётные записи (для переноса их данных в облачную).
    public func allAccounts() -> [UserAccount] {
        ((try? db.query("SELECT username, created_at, last_login_at FROM users ORDER BY username_key")) ?? []).map {
            UserAccount(username: $0["username"]?.string ?? "", createdAt: ISODate.parse($0["created_at"]?.string),
                        lastLoginAt: ISODate.parse($0["last_login_at"]?.string))
        }
    }

    public func register(username: String, password: String) throws -> UserAccount {
        guard let name = Self.normalized(username) else { throw AuthError.invalidUsername }
        guard password.count >= 8 else { throw AuthError.weakPassword }
        guard account(name) == nil else { throw AuthError.exists }
        let salt = try Self.randomBytes(16)
        let hash = try Self.pbkdf2(password, salt: salt, iterations: Self.iterations)
        let now = ISODate.now()
        try db.run("INSERT INTO users(username_key, username, salt, hash, iterations, created_at, last_login_at) VALUES(?,?,?,?,?,?,?)",
                   [.text(Self.key(name)), .text(name), .text(salt.base64EncodedString()), .text(hash.base64EncodedString()),
                    .int(Int64(Self.iterations)), .text(now), .text(now)])
        try FileManager.default.createDirectory(at: dataDirectory(for: name), withIntermediateDirectories: true)
        return account(name) ?? UserAccount(username: name)
    }

    public func login(username: String, password: String) throws -> UserAccount {
        let key = Self.key(username.trimmingCharacters(in: .whitespacesAndNewlines))
        if let f = failures[key], f.until > Date() {
            throw AuthError.tooManyAttempts(Int(f.until.timeIntervalSinceNow.rounded(.up)))
        }
        guard verify(key: key, password: password) else {
            // После 5 неудачных попыток подряд — пауза, растущая с каждой следующей.
            var f = failures[key] ?? (count: 0, until: Date.distantPast)
            f.count += 1
            if f.count >= 5 { f.until = Date().addingTimeInterval(Double(min(300, 15 * (f.count - 4)))) }
            failures[key] = f
            throw AuthError.wrongCredentials
        }
        failures[key] = nil
        try db.run("UPDATE users SET last_login_at=? WHERE username_key=?", [.text(ISODate.now()), .text(key)])
        return account(key) ?? UserAccount(username: username)
    }

    private func verify(key: String, password: String) -> Bool {
        guard let r = try? db.query("SELECT salt, hash, iterations FROM users WHERE username_key=?", [.text(key)]).first,
              let salt = r["salt"]?.string.flatMap({ Data(base64Encoded: $0) }),
              let stored = r["hash"]?.string.flatMap({ Data(base64Encoded: $0) }),
              let rounds = r["iterations"]?.int,
              let hash = try? Self.pbkdf2(password, salt: salt, iterations: UInt32(rounds)) else {
            // Тратим столько же времени, сколько на настоящую проверку: имя пользователя не угадать по задержке.
            _ = try? Self.pbkdf2(password, salt: Data(repeating: 0, count: 16), iterations: Self.iterations)
            return false
        }
        return Self.constantTimeEqual(hash, stored)
    }

    public func changePassword(username: String, old: String, new: String) throws {
        let key = Self.key(username)
        guard verify(key: key, password: old) else { throw AuthError.wrongCredentials }
        guard new.count >= 8 else { throw AuthError.weakPassword }
        let salt = try Self.randomBytes(16)
        let hash = try Self.pbkdf2(new, salt: salt, iterations: Self.iterations)
        try db.run("UPDATE users SET salt=?, hash=?, iterations=? WHERE username_key=?",
                   [.text(salt.base64EncodedString()), .text(hash.base64EncodedString()), .int(Int64(Self.iterations)), .text(key)])
    }

    public func dataDirectory(for username: String) -> URL {
        root.appendingPathComponent("users", isDirectory: true).appendingPathComponent(Self.key(username), isDirectory: true)
    }

    // MARK: Криптография

    static func randomBytes(_ n: Int) throws -> Data {
        var d = Data(count: n)
        let status = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        guard status == errSecSuccess else { throw SQLiteError(message: "не удалось получить случайные байты") }
        return d
    }

    /// PBKDF2-HMAC-SHA256, 32 байта.
    static func pbkdf2(_ password: String, salt: Data, iterations: UInt32) throws -> Data {
        let pwd = Array(password.utf8).map { Int8(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwd, pwd.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
        }
        guard Int(status) == kCCSuccess else { throw SQLiteError(message: "ошибка PBKDF2 (\(status))") }
        return Data(out)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
#endif
