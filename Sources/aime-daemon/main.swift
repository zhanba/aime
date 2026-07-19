import AimeASR
import AimeLocalLLM
import AimePinyin
import AimeXPC
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
        reply("aime-daemon \(daemonVersion) pid=\(ProcessInfo.processInfo.processIdentifier)")
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
                session.onCaptureReady = { [weak self] isBluetooth in
                    self?.client()?.captureReady(isBluetooth)
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

    func convertPinyin(requestJSON: Data, reply: @escaping (String?, String?) -> Void) {
        guard let request = try? JSONDecoder().decode(PinyinConvertRequest.self, from: requestJSON) else {
            reply(nil, "请求解析失败")
            return
        }
        PinyinLLMService.shared.convert(request, reply: reply)
    }
}

/// 本地拼音 LLM（形态 A 约束解码）：模型进程级常驻（跨连接共享），
/// 串行队列消费 + latest-wins——打字场景旧 code 串的结果没人要，排队时被
/// 更新请求挤掉的直接回 (nil, nil)，客户端静默降级。
final class PinyinLLMService {
    static let shared = PinyinLLMService()

    private let queue = DispatchQueue(label: "com.zhanba.aime.pinyin-llm", qos: .userInitiated)
    private var decoder: PinyinLocalDecoder?
    private var loadAttempted = false
    private var loadError: String?
    private let lock = NSLock()
    private var latestGeneration = 0

    func convert(_ request: PinyinConvertRequest, reply: @escaping (String?, String?) -> Void) {
        lock.lock()
        latestGeneration += 1
        let myGeneration = latestGeneration
        lock.unlock()
        queue.async {
            self.lock.lock()
            let stale = myGeneration != self.latestGeneration
            self.lock.unlock()
            if stale {
                reply(nil, nil)
                return
            }
            if !self.loadAttempted {
                self.loadAttempted = true
                self.loadDecoder()
            }
            guard let decoder = self.decoder else {
                reply(nil, self.loadError ?? "本地拼音模型未加载")
                return
            }
            let result = decoder.convert(raw: request.raw, fuzzyRuleIDs: Set(request.fuzzyRuleIDs))
            reply(result?.sentence, nil)
        }
    }

    private func loadDecoder() {
        guard let modelDir = PinyinLocalDecoder.defaultModelDir() else {
            loadError = "本地拼音模型目录缺失（App Support/aime/models 或 HF 缓存）"
            return
        }
        guard let tokenTable = PinyinLocalDecoder.defaultTokenTableURL() else {
            loadError = "词元表缺失（App Support/aime/cjk_tokens.json）"
            return
        }
        guard let lexicon = Lexicon(url: Lexicon.defaultURL) else {
            loadError = "词库未安装"
            return
        }
        do {
            let began = Date()
            let decoder = try PinyinLocalDecoder(
                modelDir: modelDir, tokenTableURL: tokenTable, lexicon: lexicon)
            decoder.warmup()
            self.decoder = decoder
            NSLog("aime-daemon: 本地拼音 LLM 就绪 %.1fs（%@）", Date().timeIntervalSince(began), modelDir.path)
        } catch {
            loadError = error.localizedDescription
            NSLog("aime-daemon: 本地拼音 LLM 加载失败: %@", loadError!)
        }
    }
}

/// 版本号读宿主 app bundle 的 Info.plist（发布时由 release.sh 注入；daemon 自己的
/// __info_plist 在链接期嵌入、不经版本注入，不可作数）。裸跑（非 bundle 内）时标 dev。
let daemonVersion: String = {
    let appURL = Bundle.main.bundleURL // Contents/MacOS
        .deletingLastPathComponent()   // Contents
        .deletingLastPathComponent()   // Aime.app
    guard appURL.pathExtension == "app",
          let info = Bundle(url: appURL)?.infoDictionary,
          let short = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String
    else { return "dev" }
    return "\(short)(\(build))"
}()

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
