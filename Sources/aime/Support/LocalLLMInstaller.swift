import AimeLocalLLM
import Foundation

/// 本地拼音 LLM 模型（Qwen3-0.6B-4bit，Apache 2.0）的下载安装（设置页 UI 的后端）。
/// 只需 model.safetensors 一个文件（config 硬编码在 PinyinTextModel.small，
/// tokenizer 由 bundle 内 cjk_tokens.json 替代），约 320MB，主源 HF、回退 hf-mirror。
@MainActor
final class LocalLLMInstaller: ObservableObject {
    static let shared = LocalLLMInstaller()

    enum Phase: Equatable {
        case idle
        case downloading(String) // 进度文案
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var installedInfo: String?

    private static let sources = [
        "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/main/model.safetensors",
        "https://hf-mirror.com/mlx-community/Qwen3-0.6B-4bit/resolve/main/model.safetensors",
    ]

    /// 受管落点（与 PinyinLocalDecoder.defaultModelDir 的优先路径一致）
    static var managedDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aime/models/Qwen3-0.6B-4bit", isDirectory: true)
    }

    init() {
        refresh()
    }

    func refresh() {
        guard let dir = PinyinLocalDecoder.defaultModelDir() else {
            installedInfo = nil
            return
        }
        let file = dir.appendingPathComponent("model.safetensors")
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let origin = dir.path.hasPrefix(Self.managedDir.path) ? "" : "（开发机 HF 缓存）"
        installedInfo = "已安装 Qwen3-0.6B（\(sizeText)）\(origin)"
    }

    func install() {
        guard phase == .idle || isFailed else { return }
        Task {
            do {
                phase = .downloading("下载模型…")
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aime-llm-\(UUID().uuidString).safetensors")
                defer { try? FileManager.default.removeItem(at: temp) }
                try await Self.fetch(to: temp) { [weak self] text in
                    Task { @MainActor in
                        if case .downloading = self?.phase { self?.phase = .downloading(text) }
                    }
                }
                try Self.validate(file: temp)
                let dir = Self.managedDir
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent("model.safetensors")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                phase = .idle
                refresh()
            } catch {
                phase = .failed("失败：\(error.localizedDescription)")
            }
        }
    }

    /// 只删受管副本（开发机 HF 缓存不动，删除后 refresh 会重新发现它）
    func delete() {
        try? FileManager.default.removeItem(at: Self.managedDir)
        refresh()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// 逐源流式下载到 file，每 ~8MB 报一次进度（350MB 不能整块进内存）
    private static func fetch(to file: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3600
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                let expected = response.expectedContentLength
                FileManager.default.createFile(atPath: file.path, contents: nil)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                var buffer = Data(capacity: 1 << 23)
                var written: Int64 = 0
                var nextReport: Int64 = 0
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 1 << 23 {
                        try handle.write(contentsOf: buffer)
                        written += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        if written >= nextReport {
                            nextReport = written + (1 << 23)
                            let done = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
                            if expected > 0 {
                                onProgress("下载模型… \(Int(Double(written) / Double(expected) * 100))%（\(done)）")
                            } else {
                                onProgress("下载模型… \(done)")
                            }
                        }
                    }
                }
                try handle.write(contentsOf: buffer)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// safetensors 结构校验：8 字节 LE header 长度 + 体积下限，防止把错误页/半截文件装进去
    private static func validate(file: URL) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 8) ?? Data()
        guard head.count == 8, size > 300_000_000 else {
            throw NSError(domain: "aime", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "下载不完整（\(size) 字节），请重试",
            ])
        }
        let headerLen = head.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard headerLen > 0, headerLen < 100_000_000 else {
            throw NSError(domain: "aime", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "文件格式不是 safetensors，请重试",
            ])
        }
    }
}
