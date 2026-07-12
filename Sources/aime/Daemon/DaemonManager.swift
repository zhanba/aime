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
        // 自愈：BTM 记录 enabled 但 daemon 拉不起来（app 路径变更后注册指向旧位置，
        // spawn EX_CONFIG），强制从当前位置重注册。ping 会触发 launchd 按需拉起，
        // 两次都不通才动注册（避免误伤慢启动）。
        Task {
            guard service.status == .enabled, await client.ping() == nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard await client.ping() == nil else { return }
            forceReregister()
        }
    }

    /// unregister + register：把 LaunchAgent 注册刷新到当前 app 位置。
    func forceReregister() {
        try? service.unregister()
        do {
            try service.register()
        } catch {
            statusText = "重注册失败：\(error.localizedDescription)"
        }
        refreshStatus()
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
