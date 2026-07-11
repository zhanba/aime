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

/// 取进程的代码签名 Team ID（未签名/ad-hoc 返回 nil）。
func codeSigningTeamID(ofPID pid: pid_t) -> String? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
        return nil
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        return nil
    }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any]
    else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

let ownTeamID = codeSigningTeamID(ofPID: getpid())

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 签名校验：连接方 Team ID 必须与本进程一致（aime.app / aime-ime 同证书）。
        // 注：基于 pid 的校验存在理论上的 pid 复用竞态，正式分发前应改用 audit token。
        // 本进程未签名（开发 ad-hoc）时降级为同 UID 放行（launchd MachService 天然限同会话）。
        if let ownTeamID {
            let peerTeamID = codeSigningTeamID(ofPID: newConnection.processIdentifier)
            guard peerTeamID == ownTeamID else {
                NSLog("aime-daemon 拒绝连接：peer team=\(peerTeamID ?? "nil") own=\(ownTeamID)")
                return false
            }
        }
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
