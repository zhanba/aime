import AimePinyin
import Foundation

/// 语法模型（gram.bin）的下载安装（设置页 UI 的后端）。
/// 数据来自万象拼音 LMDG 语法模型（CC-BY-4.0，作者 amzxyz），
/// 由 aime-gram 工具离线剪枝转换后挂本仓库 GitHub Releases 分发。
@MainActor
final class GramInstaller: ObservableObject {
    static let shared = GramInstaller()

    enum Phase: Equatable {
        case idle
        case downloading(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var installedInfo: String?

    /// 主源 ghproxy 风格镜像可后续追加；文件名带版本，升级时改这里即可。
    /// .z = raw deflate（scripts/package_gram.sh 产出），下载约 73MB，落盘约 215MB
    private static let sources = [
        "https://github.com/zhanba/aime/releases/download/gram-v1/gram.bin.z",
    ]

    init() {
        refresh()
    }

    func refresh() {
        guard let gram = GramModel() else {
            installedInfo = nil
            return
        }
        let size = (try? GramModel.defaultURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        installedInfo = "已安装 \(gram.entryCount) 条搭配（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）"
    }

    /// 首启自动补齐：未安装才下载，失败不重试（设置页可手动重试）
    func installIfNeeded() {
        guard installedInfo == nil else { return }
        install()
    }

    func install() {
        guard phase == .idle || isFailed else { return }
        Task {
            do {
                phase = .downloading("下载语法模型…")
                let data = try await Self.fetch()
                let output = GramModel.defaultURL
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: output, options: .atomic)
                PinyinEngine.shared.reloadIfChanged()
                phase = .idle
                refresh()
            } catch {
                phase = .failed("失败：\(error.localizedDescription)")
            }
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: GramModel.defaultURL)
        PinyinEngine.shared.reloadIfChanged()
        refresh()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private static func fetch() async throws -> Data {
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 600
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    let magic = Data("AIMEGRM1".utf8)
                    if data.prefix(8) == magic {
                        return data
                    }
                    // raw deflate（COMPRESSION_ZLIB）解压后再验 magic
                    if let inflated = try? (data as NSData).decompressed(using: .zlib) as Data,
                       inflated.prefix(8) == magic {
                        return inflated
                    }
                }
                lastError = URLError(.badServerResponse)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
