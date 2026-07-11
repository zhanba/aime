import AimeASR
import Foundation
import ServiceManagement

/// aime-daemon 的注册与连接管理（app 侧）。
///
/// daemon 是 LaunchAgent（SMAppService），模型常驻其中；app 经 XPC 使用。
/// daemon 不可用（未注册/待批准/连接失败）时调用方回退到进程内后端。
@MainActor
final class DaemonManager: ObservableObject {
    @Published var statusText = "未初始化"
    @Published var approvalRequired = false

    let proxyBackend: XPCProxyBackend
    private let client: DaemonClient
    private let service = SMAppService.agent(plistName: "com.zhanba.aime.daemon.plist")

    init() {
        let client = DaemonClient()
        self.client = client
        proxyBackend = XPCProxyBackend(client: client)
    }

    func bootstrap() {
        register()
    }

    func register() {
        do {
            if service.status != .enabled {
                try service.register()
            }
        } catch {
            statusText = "注册失败：\(error.localizedDescription)"
        }
        refreshStatus()
    }

    func unregister() {
        try? service.unregister()
        refreshStatus()
    }

    func refreshStatus() {
        switch service.status {
        case .enabled:
            statusText = "已注册"
            approvalRequired = false
        case .requiresApproval:
            statusText = "等待批准（系统设置 → 登录项）"
            approvalRequired = true
        case .notRegistered:
            statusText = "未注册"
            approvalRequired = false
        case .notFound:
            statusText = "未找到（需从打包后的 aime.app 运行）"
            approvalRequired = false
        @unknown default:
            statusText = "未知状态"
            approvalRequired = false
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 健康检查：能 ping 通才算可用（launchd 按需拉起 daemon）。
    func isHealthy() async -> Bool {
        guard service.status == .enabled else { return false }
        return await client.ping() != nil
    }

    func pingVersion() async -> String? {
        await client.ping()
    }
}

// MARK: - XPC 客户端

/// NSXPCConnection 封装。回调（onUpdate/onLevel/onProgress）由代理会话在使用前设置。
final class DaemonClient: NSObject, AimeDaemonClientXPC {
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    var onUpdate: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onProgress: ((String) -> Void)?

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let conn = NSXPCConnection(machServiceName: aimeDaemonMachServiceName)
        conn.remoteObjectInterface = NSXPCInterface(with: AimeDaemonXPC.self)
        conn.exportedInterface = NSXPCInterface(with: AimeDaemonClientXPC.self)
        conn.exportedObject = self
        conn.invalidationHandler = { [weak self] in self?.dropConnection() }
        conn.interruptionHandler = { [weak self] in self?.dropConnection() }
        conn.resume()
        connection = conn
        return conn
    }

    private func dropConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    /// 取远端代理；错误（daemon 未运行等）统一走 continuation 的 nil/错误分支。
    /// resumeOnce 防止 reply 与 errorHandler 双回调导致 continuation 二次恢复。
    private func withProxy<T>(
        timeout: TimeInterval = 15,
        _ body: @escaping (AimeDaemonXPC, @escaping (T) -> Void) -> Void
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = ResumeGuard()
            let proxy = activeConnection().remoteObjectProxyWithErrorHandler { _ in
                if resumed.claim() { continuation.resume(returning: nil) }
            }
            guard let daemon = proxy as? AimeDaemonXPC else {
                if resumed.claim() { continuation.resume(returning: nil) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if resumed.claim() { continuation.resume(returning: nil) }
            }
            body(daemon) { value in
                if resumed.claim() { continuation.resume(returning: value) }
            }
        }
    }

    func ping() async -> String? {
        await withProxy(timeout: 5) { daemon, done in
            daemon.ping(reply: done)
        }
    }

    /// 返回错误描述；nil 表示成功；连接失败返回占位错误。
    func prepare(configJSON: Data) async -> String? {
        let result: String?? = await withProxy(timeout: 600) { daemon, done in
            daemon.prepare(configJSON: configJSON, reply: done)
        }
        guard let inner = result else { return "无法连接后台服务" }
        return inner
    }

    func startSession(configJSON: Data) async -> String? {
        let result: String?? = await withProxy(timeout: 20) { daemon, done in
            daemon.startSession(configJSON: configJSON, reply: done)
        }
        guard let inner = result else { return "无法连接后台服务" }
        return inner
    }

    func finishSession() async -> Result<ASRResult, AimeError> {
        struct Reply { let data: Data?; let error: String? }
        let reply: Reply? = await withProxy(timeout: 60) { daemon, done in
            daemon.finishSession { data, error in done(Reply(data: data, error: error)) }
        }
        guard let reply else { return .failure(.daemonUnavailable("连接中断")) }
        if let error = reply.error { return .failure(.daemonUnavailable(error)) }
        guard let data = reply.data,
              let result = try? JSONDecoder().decode(ASRResult.self, from: data)
        else {
            return .failure(.daemonUnavailable("返回数据无法解析"))
        }
        return .success(result)
    }

    func cancelSession() {
        (activeConnection().remoteObjectProxyWithErrorHandler { _ in } as? AimeDaemonXPC)?
            .cancelSession()
    }

    // MARK: AimeDaemonClientXPC（daemon → app 回调）

    func transcriptUpdate(_ text: String) {
        onUpdate?(text)
    }

    func audioLevel(_ level: Float) {
        onLevel?(level)
    }

    func modelProgress(_ status: String) {
        onProgress?(status)
    }
}

/// continuation 只恢复一次的守卫。
private final class ResumeGuard: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

// MARK: - 代理后端（把 ASRBackend/ASRSession 的调用转发给 daemon）

final class XPCProxyBackend: ASRBackend {
    let id: ASRBackendID = .qwen3ASR // 透传后端，实际引擎由 config.backend 决定
    var onProgress: ((String?) -> Void)?

    private let client: DaemonClient

    init(client: DaemonClient) {
        self.client = client
    }

    func prepareModel(config: ASRSessionConfig) async throws {
        client.onProgress = { [weak self] status in
            self?.onProgress?(status.isEmpty ? nil : status)
        }
        let json = try JSONEncoder().encode(config)
        if let error = await client.prepare(configJSON: json) {
            throw AimeError.daemonUnavailable(error)
        }
    }

    func makeSession() -> ASRSession {
        XPCProxySession(client: client)
    }
}

final class XPCProxySession: ASRSession {
    var onUpdate: (@MainActor (String) -> Void)?
    var onLevel: (@MainActor (Float) -> Void)?

    private let client: DaemonClient

    init(client: DaemonClient) {
        self.client = client
    }

    func start(config: ASRSessionConfig) async throws {
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

    func finish() async throws -> ASRResult {
        switch await client.finishSession() {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    func cancel() async {
        client.cancelSession()
    }
}
