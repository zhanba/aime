import Foundation

// MARK: - 代理后端（把 ASRBackend/ASRSession 的调用转发给 daemon）

public final class XPCProxyBackend: ASRBackend {
    public let id: ASRBackendID = .qwen3ASR // 透传后端，实际引擎由 config.backend 决定
    public var onProgress: ((String?) -> Void)?

    private let client: DaemonClient

    public init(client: DaemonClient) {
        self.client = client
    }

    public func prepareModel(config: ASRSessionConfig) async throws {
        client.onProgress = { [weak self] status in
            self?.onProgress?(status.isEmpty ? nil : status)
        }
        let json = try JSONEncoder().encode(config)
        if let error = await client.prepare(configJSON: json) {
            throw AimeError.daemonUnavailable(error)
        }
    }

    public func makeSession() -> ASRSession {
        XPCProxySession(client: client)
    }
}

public final class XPCProxySession: ASRSession {
    public var onUpdate: (@MainActor (String) -> Void)?
    public var onLevel: (@MainActor (Float) -> Void)?

    private let client: DaemonClient

    public init(client: DaemonClient) {
        self.client = client
    }

    public func start(config: ASRSessionConfig) async throws {
        client.onUpdate = { [weak self] text in
            Task { @MainActor in self?.onUpdate?(text) }
        }
        client.onLevel = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        let json = try JSONEncoder().encode(config)
        if let error = await client.startSession(configJSON: json) {
            throw AimeError.daemonUnavailable(error)
        }
    }

    public func finish() async throws -> ASRResult {
        switch await client.finishSession() {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    public func cancel() async {
        client.cancelSession()
    }
}
