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
        let reregister = CommandLine.arguments.contains("--daemon-reregister")
        guard reregister || CommandLine.arguments.contains("--daemon-status") else { return }

        let service = SMAppService.agent(plistName: "com.zhanba.aime.daemon.plist")
        if reregister {
            // 注册刷新到当前 app 位置（app 挪位置后 BTM 记录指旧路径时用）
            try? service.unregister()
            Thread.sleep(forTimeInterval: 1)
        }
        if service.status != .enabled || reregister {
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

    /// `--register-ime`：仅注册已装到 ~/Library/Input Methods 的副本
    /// （make install-ime 拷贝后调用；分发版走设置页按钮 IMEInstaller.install()）。
    private static func registerIME() {
        do {
            print(try IMEInstaller.register())
            exit(0)
        } catch {
            print("register-ime: \(error.localizedDescription)")
            exit(1)
        }
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
