import CommonCrypto
import CryptoKit
import Foundation

/// Расшифровка Fernet — того же формата, которым конвейер шифрует состояние
/// (`leadgen/storage/state_crypto.py`): ключ = SHA-256(секрет), токен = версия | время | IV | шифртекст | HMAC.
public enum Fernet {
    public enum Failure: Error, Equatable, LocalizedError {
        case badToken
        case badSignature
        case decryptFailed

        public var errorDescription: String? {
            switch self {
            case .badToken: return "Файл состояния повреждён или имеет неизвестный формат."
            case .badSignature: return "Неверный ключ шифрования: подпись не совпала. Проверьте STATE_ENCRYPTION_KEY."
            case .decryptFailed: return "Не удалось расшифровать состояние."
            }
        }
    }

    /// Ключ Fernet из секрета, как в Python: urlsafe_b64encode(sha256(secret)).
    static func keys(secret: String) -> (signing: Data, encryption: Data) {
        let digest = Data(SHA256.hash(data: Data(secret.utf8)))
        return (digest.prefix(16), digest.suffix(16))
    }

    public static func decrypt(token: Data, secret: String) throws -> Data {
        guard var text = String(data: token, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Failure.badToken
        }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let raw = Data(base64Encoded: text), raw.count >= 1 + 8 + 16 + 16 + 32, raw.first == 0x80 else {
            throw Failure.badToken
        }
        let (signing, encryption) = keys(secret: secret)
        let body = raw.prefix(raw.count - 32)
        let mac = raw.suffix(32)
        let expected = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: signing))
        guard Data(expected) == Data(mac) else { throw Failure.badSignature }

        let iv = raw.subdata(in: (raw.startIndex + 9)..<(raw.startIndex + 25))
        let ciphertext = raw.subdata(in: (raw.startIndex + 25)..<(raw.endIndex - 32))
        guard ciphertext.count % 16 == 0 else { throw Failure.badToken }
        return try aesCBCDecrypt(ciphertext, key: encryption, iv: iv)
    }

    private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.decryptFailed }
        out.count = moved
        return out
    }
}
