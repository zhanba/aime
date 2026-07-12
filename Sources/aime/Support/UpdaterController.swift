import Sparkle

/// Sparkle 自动更新（直接分发）。feed 与公钥在 Info.plist（SUFeedURL 指向
/// GitHub Releases 的 appcast.xml，EdDSA 公钥 SUPublicEDKey）。
/// 启动时创建以启用后台定时检查；菜单「检查更新…」触发手动检查。
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
