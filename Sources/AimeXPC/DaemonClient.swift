import Foundation

/// daemon 的 XPC 客户端与代理后端（app 与 aime-ime 共用）。

// MARK: - XPC 客户端

/// NSXPCConnection 封装。回调（onUpdate/onLevel/onProgress）由代理会话在使用前设置。
public final class DaemonClient: NSObject, AimeDaemonClientXPC {
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    public var onUpdate: ((String) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public var onProgress: ((String) -> Void)?
    public var onCaptureReady: ((Bool) -> Void)?

    override public init() {
        super.init()
    }

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

    public func ping() async -> String? {
        await withProxy(timeout: 5) { daemon, done in
            daemon.ping(reply: done)
        }
    }

    /// 返回错误描述；nil 表示成功；连接失败返回占位错误。
    public func prepare(configJSON: Data) async -> String? {
        let result: String?? = await withProxy(timeout: 600) { daemon, done in
            daemon.prepare(configJSON: configJSON, reply: done)
        }
        guard let inner = result else { return "无法连接后台服务" }
        return inner
    }

    public func startSession(configJSON: Data) async -> String? {
        let result: String?? = await withProxy(timeout: 20) { daemon, done in
            daemon.startSession(configJSON: configJSON, reply: done)
        }
        guard let inner = result else { return "无法连接后台服务" }
        return inner
    }

    public func finishSession() async -> Result<ASRResult, AimeError> {
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

    public func cancelSession() {
        (activeConnection().remoteObjectProxyWithErrorHandler { _ in } as? AimeDaemonXPC)?
            .cancelSession()
    }

    // MARK: AimeDaemonClientXPC（daemon → 客户端回调）

    public func transcriptUpdate(_ text: String) {
        onUpdate?(text)
    }

    public func audioLevel(_ level: Float) {
        onLevel?(level)
    }

    public func modelProgress(_ status: String) {
        onProgress?(status)
    }

    public func captureReady(_ inputIsBluetooth: Bool) {
        onCaptureReady?(inputIsBluetooth)
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
