import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Транспорт HTTP. В тестах подменяется заглушкой.
public protocol CloudTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCloudTransport: CloudTransport {
    let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 3
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            #if canImport(FoundationNetworking)
            (data, response) = try await withCheckedThrowingContinuation { cont in
                session.dataTask(with: request) { d, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r!)) }
                }.resume()
            }
            #else
            (data, response) = try await session.data(for: request)
            #endif
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.network("нет ответа") }
        return (data, http)
    }
}
