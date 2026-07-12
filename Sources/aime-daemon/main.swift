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

/// 取本进程的代码签名 Team ID（未签名/ad-hoc 返回 nil）。
func ownCodeSigningTeamID() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
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

extension NSXPCConnection {
    /// 连接方 audit token。NSXPCConnection 未公开此属性，经 KVC 读取（直接分发无审核限制，
    /// Objective-See/Sparkle 等同用此法）；取不到时返回 nil，调用方须拒绝连接。
    var peerAuditToken: audit_token_t? {
        guard let value = self.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token)
        return token
    }
}

/// 校验连接方满足签名要求：签名有效 + Apple 锚 + 与本进程相同 Team ID。
/// 用 audit token 定位进程（pid 有复用竞态），SecCodeCheckValidity 做动态校验。
func peerSatisfiesTeamRequirement(_ connection: NSXPCConnection, teamID: String) -> Bool {
    guard let token = connection.peerAuditToken else {
        NSLog("aime-daemon: 无法获取连接方 audit token")
        return false
    }
    let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
    let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
        return false
    }
    let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess else {
        return false
    }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

let ownTeamID = ownCodeSigningTeamID()

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 签名校验：连接方须签名有效且 Team ID 与本进程一致（aime.app / aime-ime 同证书）。
        // 本进程未签名（开发 ad-hoc）时降级为同 UID 放行（launchd MachService 天然限同会话）。
        if let ownTeamID {
            guard peerSatisfiesTeamRequirement(newConnection, teamID: ownTeamID) else {
                NSLog("aime-daemon 拒绝连接：pid=\(newConnection.processIdentifier) 未通过 Team ID \(ownTeamID) 签名校验")
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
