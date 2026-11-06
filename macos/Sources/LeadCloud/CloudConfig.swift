import Foundation

/// Адрес проекта Supabase и публичный (anon / publishable) ключ.
///
/// Оба значения публичные: они встраиваются в приложение при сборке (Info.plist) и
/// дают только то, что разрешают политики RLS. Секретные ключи в приложение не попадают.
public struct CloudConfig: Equatable, Sendable {
    public let url: URL
    public let anonKey: String

    public init?(url: String, anonKey: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), let scheme = u.scheme, u.host != nil,
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost"].contains(u.host ?? "")),
              !key.isEmpty, Self.isPublicKey(key) else { return nil }
        self.url = u
        self.anonKey = key
    }

    /// Публичный ключ: publishable (sb_publishable_…) или JWT с ролью anon. Секретный ключ
    /// (sb_secret_… или JWT с другой ролью) отклоняется, чтобы его нельзя было встроить по ошибке.
    public static func isPublicKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_publishable_") { return true }
        if key.hasPrefix("sb_secret_") { return false }
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return false }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["role"] as? String == "anon"
    }

    /// Из Info.plist (ключи LGSupabaseURL и LGSupabaseAnonKey, их заполняет скрипт сборки).
    public static func fromBundle(_ bundle: Bundle = .main) -> CloudConfig? {
        guard let url = bundle.object(forInfoDictionaryKey: "LGSupabaseURL") as? String,
              let key = bundle.object(forInfoDictionaryKey: "LGSupabaseAnonKey") as? String else { return nil }
        return CloudConfig(url: url, anonKey: key)
    }

    public static let redirectURL = "leadgenerator://auth/callback"
}
