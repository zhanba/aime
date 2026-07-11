import AimeASR
import Foundation

/// aime-daemon：模型常驻 + 麦克风采集的推理服务。
/// launchd（SMAppService LaunchAgent）按需拉起，经 MachService XPC 供 aime.app / 未来的 IME 进程使用。
///
/// 单会话模型：同一时刻至多一个活动会话；模型注册表进程级共享（跨连接常驻）。
final class DaemonService: NSObject, AimeDaemonXPC {
    weak var connection: NSXPCConnection?
    private var session: ASRSession?

    private func client() -> AimeDaemonClientXPC? {
        connection?.remoteObjectProxy as? AimeDaemonClientXPC
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("aime-daemon 0.1.0 pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    func prepare(configJSON: Data, reply: @escaping (String?) -> Void) {
        Task {
            do {
                let config = try JSONDecoder().decode(ASRSessionConfig.self, from: configJSON)
                let backend = ASRBackendRegistry.shared.backend(for: config.backend)
                backend.onProgress = { [weak self] status in
                    self?.client()?.modelProgress(status ?? "")
                }
                try await backend.prepareModel(config: config)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func startSession(configJSON: Data, reply: @escaping (String?) -> Void) {
        Task {
            do {
                let config = try JSONDecoder().decode(ASRSessionConfig.self, from: configJSON)
                if let old = self.session {
                    self.session = nil
                    await old.cancel()
                }
                let session = ASRBackendRegistry.shared.backend(for: config.backend).makeSession()
                session.onUpdate = { [weak self] text in
                    self?.client()?.transcriptUpdate(text)
                }
                session.onLevel = { [weak self] level in
                    self?.client()?.audioLevel(level)
                }
                self.session = session
                try await session.start(config: config)
                reply(nil)
            } catch {
                self.session = nil
                reply(error.localizedDescription)
            }
        }
    }

    func finishSession(reply: @escaping (Data?, String?) -> Void) {
        Task {
            guard let session = self.session else {
                reply(nil, "没有进行中的会话")
                return
            }
            self.session = nil
            do {
                let result = try await session.finish()
                reply(try JSONEncoder().encode(result), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func cancelSession() {
        Task {
            let session = self.session
            self.session = nil
            await session?.cancel()
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // TODO(M3): 校验连接方代码签名（同 Team ID），IME 进程接入前必须补上
        let service = DaemonService()
        service.connection = newConnection
        newConnection.exportedInterface = NSXPCInterface(with: AimeDaemonXPC.self)
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(with: AimeDaemonClientXPC.self)
        newConnection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: aimeDaemonMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
