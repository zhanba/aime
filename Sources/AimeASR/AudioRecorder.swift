import AVFoundation
import Accelerate
import CoreAudio
import os

/// 麦克风采集（会话侧握把）。回调运行在音频线程，调用方自行处理线程切换。
/// 实际管线由进程级 CaptureCore 持有，跨会话复用（见其注释）。
public final class AudioRecorder {
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onLevel: ((Float) -> Void)?
    /// 蓝牙耳机收音策略（默认快速释放），见 BluetoothMicStrategy。
    public var bluetoothMicStrategy: BluetoothMicStrategy = .quickRelease

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() throws {
        try CaptureCore.shared.acquire(for: self)
    }

    public func stop() {
        CaptureCore.shared.release(for: self)
    }
}

/// 进程级采集核心：持有输入管线并跨会话复用。
///
/// 蓝牙耳机坑（默认输入是蓝牙耳机麦时）：
/// 1. 录音要把耳机从 A2DP 切到 HFP——有提示音、约 1 秒建立延迟（开头的话会丢）；
/// 2. HFP 切换触发 AVAudioEngineConfigurationChange，无条件重建引擎会二次触发提示音；
/// 3. AVAudioEngine 的 inputNode 一旦实例化无法可靠改设备（格式焊死），
///    指定内置麦克风须走 AVCaptureSession。
/// 对策按 BluetoothMicStrategy 二选一：耳机麦克风（录完短暂保温后归还）/ 改用内置麦。
/// 配置变化后先观察 buffer 是否停滞，停了才重建（无条件重建会二次触发提示音）。
final class CaptureCore {
    static let shared = CaptureCore()

    private static let logger = Logger(subsystem: "com.zhanba.aime", category: "AudioRecorder")
    /// 保温时长：只覆盖"松开又马上按"的紧凑衔接，录完底噪立刻消失
    private static let bluetoothGraceSeconds: TimeInterval = 2

    /// unified logging 在部分机器查询不到，双写文件日志（~/Library/Logs/aime-audio.log）
    private static func dlog(_ message: String) {
        logger.log("\(message)")
        DiagLog.log(message)
    }

    /// 管线状态只在 queue 上访问；sink 由音频线程读、queue 写，用 sinkLock 保护。
    private let queue = DispatchQueue(label: "aime.capture-core")
    private let captureQueue = DispatchQueue(label: "aime.capture-core.buffers")

    private var engine: AVAudioEngine?
    /// 引擎创建时的系统默认输入设备（默认设备变了则热引擎作废）
    private var engineDeviceID: AudioDeviceID?
    private var captureSession: AVCaptureSession?
    private var captureDelegate: CaptureDelegate?
    private var observer: NSObjectProtocol?
    private var idleShutdown: DispatchWorkItem?
    private var aliveCheck: DispatchWorkItem?

    private let sinkLock = NSLock()
    private var bufferSink: ((AVAudioPCMBuffer) -> Void)?
    private var levelSink: ((Float) -> Void)?
    private weak var owner: AudioRecorder?
    /// 最近一次 acquire/warmUp 生效的策略，决定 release 后管线去留
    private var strategy: BluetoothMicStrategy = .quickRelease

    /// 诊断计数（音频线程写、无锁；只用于日志，允许弱一致）
    private var diagFrames: UInt64 = 0
    private var diagMaxRMS: Float = 0
    private var diagWindowFrames: UInt64 = 0
    private var engineStartedAt: Date?

    func acquire(for recorder: AudioRecorder) throws {
        try queue.sync {
            idleShutdown?.cancel()
            idleShutdown = nil
            owner = recorder
            strategy = recorder.bluetoothMicStrategy
            sinkLock.lock()
            bufferSink = { [weak recorder] buffer in recorder?.onBuffer?(buffer) }
            levelSink = { [weak recorder] level in recorder?.onLevel?(level) }
            sinkLock.unlock()
            diagFrames = 0
            diagMaxRMS = 0
            diagWindowFrames = 0
            engineStartedAt = Date()

            let wantBuiltin = strategy == .builtinMic
                && Self.defaultInputIsBluetooth()
                && Self.builtInMicrophone() != nil

            if !wantBuiltin, let engine, engine.isRunning,
               engineDeviceID == Self.defaultInputDeviceID() {
                Self.dlog("复用热引擎（跳过麦克风重新激活）")
                scheduleAliveCheck(after: 0.6, attempt: 0)
                return
            }
            teardown()
            if wantBuiltin, let builtIn = Self.builtInMicrophone() {
                try startCaptureSession(device: builtIn)
            } else {
                try startEngine()
            }
        }
    }

    func release(for recorder: AudioRecorder) {
        queue.sync {
            guard owner === recorder else { return }
            owner = nil
            sinkLock.lock()
            bufferSink = nil
            levelSink = nil
            sinkLock.unlock()
            Self.dlog("会话结束 总帧=\(self.diagFrames) 峰值RMS=\(self.diagMaxRMS)")

            // 蓝牙引擎短暂保温：覆盖"松开又马上按"的衔接，其余情况立即释放
            guard strategy == .quickRelease, engine != nil, Self.defaultInputIsBluetooth() else {
                teardown()
                return
            }
            Self.dlog("蓝牙麦克风保持就绪 \(Int(Self.bluetoothGraceSeconds)) 秒")
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.owner == nil else { return }
                Self.dlog("保温到期，释放麦克风")
                self.teardown()
            }
            idleShutdown = work
            queue.asyncAfter(deadline: .now() + Self.bluetoothGraceSeconds, execute: work)
        }
    }

    /// 音频线程回调：分发 buffer、更新电平与诊断计数。
    /// 计数在丢弃判断之前：保温期链路心跳也要被停滞检测看到。
    private func consume(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        if diagFrames == 0, let startedAt = engineStartedAt {
            Self.dlog(String(format: "首个音频块到达，距引擎启动 %.0fms", Date().timeIntervalSince(startedAt) * 1000))
        }
        diagFrames += UInt64(buffer.frameLength)
        sinkLock.lock()
        let sink = bufferSink
        let level = levelSink
        sinkLock.unlock()
        guard let sink else { return } // 保温期：丢弃数据，只维持链路
        sink(buffer)
        let rms = Self.rawRMS(of: buffer)
        level?(Self.normalizeLevel(rms))
        diagMaxRMS = max(diagMaxRMS, rms)
        diagWindowFrames += UInt64(buffer.frameLength)
        if Double(diagWindowFrames) >= sampleRate * 2 {
            diagWindowFrames = 0
            let db = diagMaxRMS > 0 ? 20 * log10(diagMaxRMS) : -120
            Self.dlog("采集中 总帧=\(self.diagFrames) 峰值RMS=\(self.diagMaxRMS)（\(Int(db))dB）")
        }
    }

    /// 仅在 queue 上调用。
    private func teardown() {
        idleShutdown?.cancel()
        idleShutdown = nil
        aliveCheck?.cancel()
        aliveCheck = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        engineDeviceID = nil
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
    }

    // MARK: - 系统默认输入（AVAudioEngine）

    /// 仅在 queue 上调用。蓝牙麦克风激活瞬间格式可能短暂无效，带一轮短重试。
    /// 启动后自带看门狗：冷启动的引擎可能永远不出数据（在 HFP 切换前创建、
    /// 切换后渲染链失效且不自愈），必须主动探测并恢复。
    private func startEngine(attempt: Int = 0) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            if attempt < 3 {
                Thread.sleep(forTimeInterval: 0.15)
                return try startEngine(attempt: attempt + 1)
            }
            throw AimeError.microphoneUnavailable
        }
        installTap(on: input, format: format)
        engine.prepare()
        try engine.start()
        Self.dlog("引擎启动 设备=\(Self.defaultInputDeviceName()) 格式=\(format.sampleRate)Hz/\(format.channelCount)ch")
        self.engine = engine
        engineStartedAt = Date()
        engineDeviceID = Self.defaultInputDeviceID()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        scheduleAliveCheck(after: 0.6, attempt: 0)
    }

    /// 仅在 queue 上调用。
    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, sampleRate: sampleRate)
        }
    }

    private func handleConfigurationChange() {
        queue.async { [weak self] in
            guard let self, self.engine != nil else { return }
            Self.dlog("音频设备配置变化，观察采集是否存活")
            self.scheduleAliveCheck(after: 0.3, attempt: 0)
        }
    }

    /// 仅在 queue 上调用。delay 秒后若无新 buffer 到达则分级恢复：
    /// 先原地恢复（同一引擎重装 tap + restart，不再次触发耳机激活音），
    /// 无效再销毁重建。同一时刻只保留一个检查（后来的覆盖先前的）。
    private func scheduleAliveCheck(after delay: TimeInterval, attempt: Int) {
        aliveCheck?.cancel()
        let reference = diagFrames
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.engine != nil else { return }
            guard self.diagFrames == reference else { return } // 采集正常流动
            guard self.owner != nil else {
                // 保温期没人用，链路死了就直接放掉，不为空转重建
                self.teardown()
                return
            }
            guard attempt < 4 else {
                Self.dlog("采集停滞且多次恢复无效，放弃")
                return
            }
            if attempt == 0 {
                Self.dlog("采集停滞，原地恢复（重装 tap + restart）")
                self.recoverInPlace()
            } else {
                Self.dlog("原地恢复无效，销毁重建（第 \(attempt) 次）")
                self.teardown()
                do {
                    try self.startEngine()
                    return // startEngine 已排了新的看门狗
                } catch {
                    Self.dlog("引擎重建失败: \(error)")
                }
            }
            self.scheduleAliveCheck(after: 0.6, attempt: attempt + 1)
        }
        aliveCheck = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 仅在 queue 上调用。同一引擎上按当前设备格式重装 tap 并重启——
    /// Apple 对配置变化的建议处理方式，不销毁 AUHAL，避免二次 HFP 激活。
    private func recoverInPlace() {
        guard let engine else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Self.dlog("原地恢复：格式无效 \(format.sampleRate)Hz，交给下一级重建")
            return
        }
        installTap(on: input, format: format)
        engine.prepare()
        do {
            try engine.start()
            Self.dlog("原地恢复完成 格式=\(format.sampleRate)Hz/\(format.channelCount)ch running=\(engine.isRunning)")
        } catch {
            Self.dlog("原地恢复 restart 失败: \(error)")
        }
    }

    // MARK: - 内置麦克风（AVCaptureSession）

    /// 仅在 queue 上调用。
    private func startCaptureSession(device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AimeError.microphoneUnavailable }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        let delegate = CaptureDelegate { [weak self] buffer in
            self?.consume(buffer, sampleRate: buffer.format.sampleRate)
        }
        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        guard session.canAddOutput(output) else { throw AimeError.microphoneUnavailable }
        session.addOutput(output)
        session.startRunning()
        captureSession = session
        captureDelegate = delegate
        Self.dlog("采集启动（内置麦克风 \(device.localizedName)）")
    }

    /// CMSampleBuffer → AVAudioPCMBuffer，转发给 handler。
    private final class CaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        private let handler: (AVAudioPCMBuffer) -> Void

        init(handler: @escaping (AVAudioPCMBuffer) -> Void) {
            self.handler = handler
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0 else { return }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                return
            }
            pcm.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            ) == noErr else { return }
            handler(pcm)
        }
    }

    // MARK: - 工具

    private static func rawRMS(of buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return 0 }
        if let data = buffer.floatChannelData?[0] {
            var rms: Float = 0
            vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
            return rms
        }
        // 采集会话可能给出 Int16 PCM
        if let data = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for index in 0 ..< Int(buffer.frameLength) {
                let sample = Float(data[index]) / Float(Int16.max)
                sum += sample * sample
            }
            return sqrtf(sum / Float(buffer.frameLength))
        }
        return 0
    }

    /// 归一化到 0...1 的响度，供浮层电平动画使用。
    private static func normalizeLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        // 转 dB 后映射 [-50, 0] → [0, 1]
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 50) / 50))
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func defaultInputIsBluetooth() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func builtInMicrophone() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        )
        return discovery.devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
    }

    private static func defaultInputDeviceName() -> String {
        guard let deviceID = defaultInputDeviceID() else { return "未知" }
        var name = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, $0)
        }
        return status == noErr ? (name as String) : "未知"
    }
}

/// 超时保护：超时抛 CancellationError，避免 finalize 卡死整个会话。
public func withTimeout(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        try await group.next()
        group.cancelAll()
    }
}
