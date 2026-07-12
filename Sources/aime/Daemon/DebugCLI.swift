import AimeASR
import Carbon
import Foundation
import ServiceManagement

/// 无头验证入口：`aime.app/Contents/MacOS/aime --daemon-status`
/// 注册 LaunchAgent、ping daemon，打印结果后退出（不进入 GUI）。
enum DebugCLI {
    static func runIfNeeded() {
        if CommandLine.arguments.contains("--register-ime") {
            registerIME()
            return
        }
        if CommandLine.arguments.contains("--daemon-prepare") {
            runPrepare()
            return
        }
        guard CommandLine.arguments.contains("--daemon-status") else { return }

        let service = SMAppService.agent(plistName: "com.zhanba.aime.daemon.plist")
        if service.status != .enabled {
            do {
                try service.register()
                print("register: ok")
            } catch {
                print("register: \(error.localizedDescription)")
            }
        }
        print("SMAppService status: \(describe(service.status))")

        let client = DaemonClient()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let pong = await client.ping() {
                print("ping: \(pong)")
            } else {
                print("ping: 失败（daemon 未运行、未批准或连接被拒）")
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    /// `--register-ime`：向 TIS 注册 ~/Library/Input Methods/aime-ime.app 并启用。
    private static func registerIME() {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Input Methods/aime-ime.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("register-ime: 未找到 \(url.path)（先 make install-ime）")
            exit(1)
        }
        let registerStatus = TISRegisterInputSource(url as CFURL)
        print("TISRegisterInputSource: \(registerStatus == noErr ? "ok" : "错误 \(registerStatus)")")

        let filter = [kTISPropertyBundleID as String: "com.zhanba.inputmethod.aime"] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              !list.isEmpty
        else {
            print("未找到已注册的输入源（可能需要注销重新登录后重试）")
            exit(1)
        }
        for source in list {
            let enableStatus = TISEnableInputSource(source)
            print("TISEnableInputSource: \(enableStatus == noErr ? "ok" : "错误 \(enableStatus)")")
        }
        print("完成。到 系统设置 → 键盘 → 输入法 或菜单栏输入法图标里选择「Aime拼音」。")
        exit(0)
    }

    /// `--daemon-prepare`：经 XPC 让 daemon 加载 Qwen3 0.6B。连跑两次对比耗时，
    /// 验证模型常驻 daemon（第二次应接近 0s）。
    private static func runPrepare() {
        let client = DaemonClient()
        let config = ASRSessionConfig(
            backend: .qwen3ASR,
            localeID: "zh_CN",
            qwen3ModelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        )
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let json = try JSONEncoder().encode(config)
                let began = Date()
                let error = await client.prepare(configJSON: json)
                let cost = Date().timeIntervalSince(began)
                if let error {
                    print("prepare: 失败 \(error)")
                } else {
                    print("prepare: ok \(String(format: "%.2f", cost))s")
                }
            } catch {
                print("prepare: 编码失败 \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval（系统设置 → 登录项待批准）"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound（需从打包后的 aime.app 运行）"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
