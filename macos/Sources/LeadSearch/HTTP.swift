import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var status: Int
    public var data: Data
    /// Заголовки в нижнем регистре.
    public var headers: [String: String]
    public var url: URL?

    public init(status: Int, data: Data, headers: [String: String] = [:], url: URL? = nil) {
        self.status = status; self.data = data
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.url = url
    }

    /// Текст ответа: UTF-8, иначе Windows-1251 (старые русские сайты), иначе Latin-1.
    public var text: String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1251)
            ?? String(decoding: data, as: UTF8.self)
    }
}

/// Транспорт. В приложении — URLSession, в тестах — подмена, на сервере — что угодно.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForResource = 180
        session = URLSession(configuration: c)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, resp) = try await session.data(for: request)
        guard let h = resp as? HTTPURLResponse else { throw HTTPError(message: "нет HTTP-ответа", transient: true) }
        var headers: [String: String] = [:]
        for (k, v) in h.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
        return HTTPResponse(status: h.statusCode, data: data, headers: headers, url: h.url)
    }
}

public struct HTTPError: Error, LocalizedError, Sendable {
    public var message: String
    public var status: Int?
    public var transient: Bool
    public init(message: String, status: Int? = nil, transient: Bool = false) {
        self.message = message; self.status = status; self.transient = transient
    }
    public var errorDescription: String? { message }
}

/// Исчерпан лимит запросов источника на этот запуск.
public struct BudgetExceeded: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

public typealias Sleeper = @Sendable (Double) async -> Void

public let realSleep: Sleeper = { seconds in
    guard seconds > 0 else { return }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// HTTP для одного источника: пауза между запросами, лимит на запуск, повторы с растущей задержкой.
public final class SourceHTTP: @unchecked Sendable {
    public static let userAgent = "LeadGenerator/1.0 (macOS; personal non-commercial research)"
    static let retryStatuses: Set<Int> = [429, 500, 502, 503, 504]

    let name: String
    let transport: HTTPTransport
    let minInterval: Double
    let maxRequests: Int
    let maxAttempts: Int
    let baseDelay: Double
    let timeout: Double
    let sleep: Sleeper
    public private(set) var requestsMade = 0
    private var last: Date?

    public init(name: String, transport: HTTPTransport, minInterval: Double = 1, maxRequests: Int = 50,
                maxAttempts: Int = 4, baseDelay: Double = 2, timeout: Double = 20, sleep: @escaping Sleeper = realSleep) {
        self.name = name; self.transport = transport; self.minInterval = minInterval; self.maxRequests = maxRequests
        self.maxAttempts = maxAttempts; self.baseDelay = baseDelay; self.timeout = timeout; self.sleep = sleep
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPResponse {
        var r = URLRequest(url: url)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return try await send(r)
    }

    public func postForm(_ url: URL, _ fields: [String: String]) async throws -> HTTPResponse {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        return try await send(r)
    }

    func send(_ base: URLRequest) async throws -> HTTPResponse {
        var request = base
        request.timeoutInterval = timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let shown = Self.safe(request.url)
        var lastError: Error = HTTPError(message: "\(name): запрос не выполнен", transient: true)
        for attempt in 1...max(1, maxAttempts) {
            try Task.checkCancellation()
            guard requestsMade < maxRequests else {
                throw BudgetExceeded(message: "\(name): лимит \(maxRequests) запросов за запуск")
            }
            if let last {
                let wait = minInterval - Date().timeIntervalSince(last)
                if wait > 0 { await sleep(wait) }
            }
            last = Date()
            requestsMade += 1
            do {
                let resp = try await transport.send(request)
                if resp.status < 400 { return resp }
                let err = HTTPError(message: "HTTP \(resp.status) для \(shown)", status: resp.status,
                                    transient: Self.retryStatuses.contains(resp.status))
                guard err.transient else { throw err }
                lastError = err
                if let ra = resp.headers["retry-after"], let secs = Double(ra), attempt < maxAttempts {
                    await sleep(min(secs, 120))
                    continue
                }
            } catch let e as HTTPError {
                if !e.transient { throw e }
                lastError = e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = HTTPError(message: "\(shown): \(error.localizedDescription)", transient: true)
            }
            if attempt < maxAttempts {
                await sleep(baseDelay * pow(2, Double(attempt - 1)) + Double.random(in: 0...0.5))
            }
        }
        throw lastError
    }

    /// Адрес без параметров (там бывают ключи доступа).
    static func safe(_ url: URL?) -> String {
        guard let url else { return "?" }
        return url.absoluteString.components(separatedBy: "?")[0]
    }
}
