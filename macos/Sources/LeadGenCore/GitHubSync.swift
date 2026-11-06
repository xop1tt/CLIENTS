import Foundation

/// Настройки связи с репозиторием, где GitHub Actions выполняет поиск.
public struct GitHubConfig: Equatable, Sendable {
    public var owner: String
    public var repo: String
    public var branch: String
    public var workflowFile: String
    public var artifactName: String

    public init(owner: String, repo: String, branch: String = "main", workflowFile: String = "search.yml",
                artifactName: String = "leadgen-state") {
        self.owner = owner; self.repo = repo; self.branch = branch
        self.workflowFile = workflowFile; self.artifactName = artifactName
    }

    public var isComplete: Bool { !owner.isEmpty && !repo.isEmpty }
}

public struct WorkflowRun: Identifiable, Hashable, Sendable, Decodable {
    public var id: Int64
    public var runNumber: Int
    public var status: String
    public var conclusion: String?
    public var event: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var runStartedAt: Date?
    public var htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, status, conclusion, event
        case runNumber = "run_number"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case runStartedAt = "run_started_at"
        case htmlURL = "html_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        runNumber = (try? c.decode(Int.self, forKey: .runNumber)) ?? 0
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        conclusion = try? c.decodeIfPresent(String.self, forKey: .conclusion)
        event = (try? c.decode(String.self, forKey: .event)) ?? ""
        createdAt = ISODate.parse(try? c.decodeIfPresent(String.self, forKey: .createdAt))
        updatedAt = ISODate.parse(try? c.decodeIfPresent(String.self, forKey: .updatedAt))
        runStartedAt = ISODate.parse(try? c.decodeIfPresent(String.self, forKey: .runStartedAt))
        htmlURL = (try? c.decodeIfPresent(String.self, forKey: .htmlURL)).flatMap { $0.flatMap(URL.init(string:)) }
    }

    public var duration: TimeInterval? {
        guard let start = runStartedAt ?? createdAt, let end = updatedAt, status == "completed" else { return nil }
        return end.timeIntervalSince(start)
    }

    public var statusTitle: String {
        if status != "completed" { return status == "queued" ? "В очереди" : "Выполняется" }
        switch conclusion {
        case "success": return "Успешно"
        case "failure": return "Ошибка"
        case "cancelled": return "Отменён"
        case "skipped": return "Пропущен"
        case "timed_out": return "Превышено время"
        default: return conclusion ?? "Завершён"
        }
    }

    public var failed: Bool { status == "completed" && ["failure", "timed_out", "cancelled"].contains(conclusion ?? "") }
}

public struct Artifact: Decodable, Sendable {
    public var id: Int64
    public var name: String
    public var expired: Bool
    public var createdAt: Date?
    public var archiveDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case id, name, expired
        case createdAt = "created_at"
        case archiveDownloadURL = "archive_download_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        expired = (try? c.decode(Bool.self, forKey: .expired)) ?? false
        createdAt = ISODate.parse(try? c.decodeIfPresent(String.self, forKey: .createdAt))
        archiveDownloadURL = try c.decode(URL.self, forKey: .archiveDownloadURL)
    }
}

public struct GitHubError: Error, LocalizedError {
    public let status: Int
    public let message: String
    public var errorDescription: String? {
        switch status {
        case 401: return "GitHub не принял токен (401). Проверьте токен в настройках синхронизации."
        case 403: return "Нет прав (403). Токену нужен доступ Actions: Read and write к репозиторию. \(message)"
        case 404: return "Не найдено (404): проверьте владельца, репозиторий и имя workflow."
        default: return "GitHub ответил \(status): \(message)"
        }
    }
}

/// Не передаёт токен GitHub на сторонний хост при редиректе на скачивание архива.
private final class RedirectStripper: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var r = request
        if r.url?.host != "api.github.com" { r.setValue(nil, forHTTPHeaderField: "Authorization") }
        return r
    }
}

/// Клиент GitHub REST API: запуски поиска и зашифрованное состояние.
public final class GitHubClient: @unchecked Sendable {
    public let config: GitHubConfig
    private let token: String
    private let session: URLSession
    private let redirectDelegate = RedirectStripper()

    public init(config: GitHubConfig, token: String, session: URLSession = .shared) {
        self.config = config
        self.token = token
        self.session = session
    }

    private var base: String { "https://api.github.com/repos/\(config.owner)/\(config.repo)" }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: base + path)!)
        r.httpMethod = method
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("LeadGenerator-macOS", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.timeoutInterval = 60
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: r, delegate: redirectDelegate)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GitHubError(status: status, message: msg ?? String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data
    }

    public func runs(limit: Int = 30) async throws -> [WorkflowRun] {
        struct Page: Decodable { let workflow_runs: [WorkflowRun] }
        let data = try await send(request("/actions/workflows/\(config.workflowFile)/runs?per_page=\(limit)"))
        return try JSONDecoder().decode(Page.self, from: data).workflow_runs
    }

    /// Запускает поиск вручную (workflow_dispatch).
    public func dispatch(force: Bool = false) async throws {
        let payload: [String: Any] = ["ref": config.branch, "inputs": ["force": force ? "true" : "false"]]
        _ = try await send(request("/actions/workflows/\(config.workflowFile)/dispatches", method: "POST",
                                   body: try JSONSerialization.data(withJSONObject: payload)))
    }

    /// Перезапускает упавшие задачи запуска.
    public func rerunFailed(_ runId: Int64) async throws {
        _ = try await send(request("/actions/runs/\(runId)/rerun-failed-jobs", method: "POST"))
    }

    public func latestStateArtifact() async throws -> Artifact? {
        struct Page: Decodable { let artifacts: [Artifact] }
        let data = try await send(request("/actions/artifacts?name=\(config.artifactName)&per_page=10"))
        return try JSONDecoder().decode(Page.self, from: data).artifacts
            .filter { !$0.expired }
            .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    public func download(_ artifact: Artifact) async throws -> Data {
        var r = URLRequest(url: artifact.archiveDownloadURL)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("LeadGenerator-macOS", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 120
        return try await send(r)
    }
}

/// Скачивает свежее зашифрованное состояние из Actions, расшифровывает и вливает в локальную базу.
public enum StateSync {
    public struct Outcome: Sendable {
        public var result: ImportResult
        public var artifactDate: Date?
        public var skipped: Bool
    }

    public static func sync(store: LeadStore, client: GitHubClient, secret: String, force: Bool = false) async throws -> Outcome {
        guard let artifact = try await client.latestStateArtifact() else {
            throw GitHubError(status: 404, message: "артефакт \(client.config.artifactName) не найден: поиск ещё не публиковал состояние")
        }
        if !force, store.value("last_artifact_id") == String(artifact.id) {
            return Outcome(result: ImportResult(added: 0, updated: 0, sources: 0), artifactDate: artifact.createdAt, skipped: true)
        }
        let zip = try await client.download(artifact)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("leadgen-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zipURL = tmp.appendingPathComponent("state.zip")
        try zip.write(to: zipURL)
        try unzip(zipURL, into: tmp)
        guard let enc = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.hasSuffix(".enc") }) else {
            throw SQLiteError(message: "в артефакте нет файла .enc")
        }
        let plain = try Fernet.decrypt(token: try Data(contentsOf: enc), secret: secret)
        let dbURL = tmp.appendingPathComponent("pipeline.db")
        try plain.write(to: dbURL)
        let result = try store.importPipelineDatabase(at: dbURL.path)
        try store.setValue("last_artifact_id", String(artifact.id))
        try store.setValue("last_sync_at", ISODate.now())
        if let d = artifact.createdAt { try store.setValue("last_state_at", ISODate.format(d) ?? "") }
        return Outcome(result: result, artifactDate: artifact.createdAt, skipped: false)
    }

    static func unzip(_ zip: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SQLiteError(message: "не удалось распаковать архив состояния") }
    }
}
