import Foundation

/// daemon 的 launchd MachService 名（LaunchAgent plist 与 NSXPCConnection 两侧共用）。
public let aimeDaemonMachServiceName = "com.zhanba.aime.daemon"

/// app → daemon。config 为 ASRSessionConfig 的 JSON。
/// 单会话模型：同一时刻至多一个活动会话（与按住说话的产品形态一致）。
@objc public protocol AimeDaemonXPC {
    func ping(reply: @escaping (String) -> Void)
    /// 预加载/下载模型。reply(nil) 成功，否则为错误描述。
    func prepare(configJSON: Data, reply: @escaping (String?) -> Void)
    /// 开始会话（daemon 侧启动麦克风采集）。reply(nil) 成功。
    func startSession(configJSON: Data, reply: @escaping (String?) -> Void)
    /// 结束会话并定稿。reply(ASRResult JSON, 错误描述)。
    func finishSession(reply: @escaping (Data?, String?) -> Void)
    func cancelSession()
    /// 本地拼音 LLM（形态 A 约束解码）。request 为 PinyinConvertRequest JSON。
    /// reply(整句, 错误描述)——两者都为 nil 表示被更新的请求挤掉（latest-wins）。
    func convertPinyin(requestJSON: Data, reply: @escaping (String?, String?) -> Void)
}

/// 本地拼音 LLM 请求（IME → daemon）。
public struct PinyinConvertRequest: Codable, Sendable {
    public var raw: String
    public var fuzzyRuleIDs: [String]
    /// 光标前文（可选）：注入本地解码做上下文条件。Optional 保证与旧版 daemon/客户端互通。
    public var context: String?

    public init(raw: String, fuzzyRuleIDs: [String], context: String? = nil) {
        self.raw = raw
        self.fuzzyRuleIDs = fuzzyRuleIDs
        self.context = context
    }
}

/// daemon → app（NSXPCConnection 的 exportedObject 反向回调）。
@objc public protocol AimeDaemonClientXPC {
    func transcriptUpdate(_ text: String)
    func audioLevel(_ level: Float)
    /// 模型准备进度文案；空串表示进度清除。
    func modelProgress(_ status: String)
    /// 采集真正就绪（首帧音频到达），参数为输入设备是否蓝牙。
    func captureReady(_ inputIsBluetooth: Bool)
}
