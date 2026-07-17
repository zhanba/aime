import AimeASR
import AimeUI
import AppKit
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
        if CommandLine.arguments.contains("--overlay-demo") {
            runOverlayDemo()
            return
        }
        if CommandLine.arguments.contains("--daemon-prepare") {
            runPrepare()
            return
        }
        if CommandLine.arguments.contains("--daemon-roundtrip") {
            runRoundtrip()
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

    /// `--overlay-demo`：以当前鼠标位置模拟光标，走一遍浮层转场时间线
    /// （种子飞入 → 录音 → 润色 → 种子飞回），调动画不用真按热键说话。
    private static func runOverlayDemo() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = VoiceOverlayModel()
        let overlay = VoiceOverlayController()
        let mouse = NSEvent.mouseLocation
        let caret = NSRect(x: mouse.x, y: mouse.y, width: 2, height: 18)
        Task { @MainActor in
            model.phase = .recording
            model.captureReady = true
            overlay.show(model: model, from: caret)
            try? await Task.sleep(nanoseconds: 700_000_000)
            model.audioLevel = 0.6
            model.liveTranscript = "帮我把这段话整理一下"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            model.phase = .refining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            overlay.hide(returnTo: caret)
            try? await Task.sleep(nanoseconds: 800_000_000)
            exit(0)
        }
        app.run()
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

    /// `--daemon-roundtrip`：不经 prepare 直接跑一次完整会话（录 2 秒 → finish），
    /// 验证 daemon 端会话内模型自愈加载：全新 daemon 进程也应正常返回（静音则为空文本），
    /// 而不是「语音模型尚未就绪」。
    private static func runRoundtrip() {
        let client = DaemonClient()
        let settings = Settings.current()
        let config = ASRSessionConfig(
            backend: settings.asrBackend,
            localeID: Settings.recognitionLocaleID,
            qwen3ModelID: settings.qwen3ModelID,
            bluetoothMicStrategy: settings.bluetoothMicStrategy
        )
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let json = try JSONEncoder().encode(config)
                if let error = await client.startSession(configJSON: json) {
                    print("startSession: 失败 \(error)")
                    semaphore.signal()
                    return
                }
                print("startSession: ok（录音 2 秒…）")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let began = Date()
                switch await client.finishSession() {
                case .success(let result):
                    let cost = Date().timeIntervalSince(began)
                    print("finishSession: ok \(String(format: "%.2f", cost))s 文本=\"\(result.text)\"")
                case .failure(let error):
                    print("finishSession: 失败 \(error.localizedDescription)")
                }
            } catch {
                print("roundtrip: 编码失败 \(error)")
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
