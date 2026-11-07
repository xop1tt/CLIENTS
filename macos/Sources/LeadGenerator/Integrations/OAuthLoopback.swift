import CryptoKit
import Foundation
import LeadGenCore
import Network

/// Приём возврата из браузера после входа (OAuth): короткоживущий HTTP-сервер только на
/// петлевом интерфейсе (localhost), порт OAuthRedirect.port. Отвечает одной страницей и закрывается.
final class OAuthLoopback: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private let queue = DispatchQueue(label: "oauth.loopback")

    /// Ждёт возврата не дольше timeout. Другие запросы (например, /favicon.ico) получают 404.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> OAuthCallback {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: OAuthRedirect.port) else { throw IntegrationError.invalidURL }
        let listener = try NWListener(using: params, on: port)
        self.listener = listener
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OAuthCallback, Error>) in
                queue.async {
                    self.continuation = cont
                    listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                    listener.stateUpdateHandler = { [weak self] state in
                        if case .failed(let e) = state {
                            self?.finish(.failure(IntegrationError.badResponse("порт \(OAuthRedirect.port) занят: \(e.localizedDescription)")))
                        }
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(IntegrationError.denied("время ожидания истекло")))
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let callback = OAuthCallback.parse(requestLine: firstLine)
            let ok = callback != nil && callback?.error == nil
            let html = callback == nil ? "Not found" : ok
                ? "<!doctype html><meta charset=utf-8><title>Customers</title><body style=\"font:16px -apple-system;padding:40px\"><h2>Готово</h2><p>Диск подключён. Можно закрыть вкладку и вернуться в Customers.</p>"
                : "<!doctype html><meta charset=utf-8><title>Customers</title><body style=\"font:16px -apple-system;padding:40px\"><h2>Вход не выполнен</h2><p>Вернитесь в Customers и попробуйте ещё раз.</p>"
            let body = Data(html.utf8)
            let head = "HTTP/1.1 \(callback == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            if let callback { self.finish(.success(callback)) }
        }
    }

    private func finish(_ result: Result<OAuthCallback, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        listener?.cancel()
        listener = nil
        cont.resume(with: result)
    }
}

enum PKCE {
    /// code_challenge = base64url(SHA-256(verifier)).
    static func challenge(_ verifier: String) -> String {
        OAuthFlow.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}
