import AimePinyin
import Foundation

/// 白霜拼音词库的下载与编译（设置页 UI 的后端）。
/// GPL-3 数据：首次使用时由用户下载，编译产物独立存放，不随 app 分发。
@MainActor
final class LexiconInstaller: ObservableObject {
    static let shared = LexiconInstaller()

    enum Phase: Equatable {
        case idle
        case downloading(String) // 进度文案
        case compiling
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var installedInfo: String?

    /// 主源 jsDelivr（国内可达），回退 GitHub raw
    private static let sources = [
        "https://cdn.jsdelivr.net/gh/gaboolic/rime-frost@master/cn_dicts/",
        "https://raw.githubusercontent.com/gaboolic/rime-frost/master/cn_dicts/",
    ]
    private static let files = ["8105.dict.yaml", "base.dict.yaml"]

    init() {
        refresh()
    }

    func refresh() {
        guard let lexicon = Lexicon() else {
            installedInfo = nil
            return
        }
        let size = (try? Lexicon.defaultURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        installedInfo = "已安装 \(lexicon.entryCount) 词条（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）"
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
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aime-lexicon-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                var localFiles: [URL] = []
                for (index, file) in Self.files.enumerated() {
                    phase = .downloading("下载 \(file)（\(index + 1)/\(Self.files.count)）…")
                    let data = try await Self.fetch(file: file)
                    let local = tempDir.appendingPathComponent(file)
                    try data.write(to: local)
                    localFiles.append(local)
                }

                phase = .compiling
                // 编译在后台线程（~1s，37 万条排序）
                let output = Lexicon.defaultURL
                let files = localFiles
                let (kept, _) = try await Task.detached(priority: .userInitiated) {
                    try Lexicon.compile(rimeDicts: files, to: output)
                }.value

                PinyinEngine.shared.reloadIfChanged()
                phase = .idle
                refresh()
                installedInfo = (installedInfo ?? "") + "，本次收录 \(kept) 条"
            } catch {
                phase = .failed("失败：\(error.localizedDescription)")
            }
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: Lexicon.defaultURL)
        PinyinEngine.shared.reloadIfChanged()
        refresh()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// 逐源尝试下载单个文件
    private static func fetch(file: String) async throws -> Data {
        var lastError: Error = URLError(.cannotLoadFromNetwork)
        for source in sources {
            guard let url = URL(string: source + file) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, data.count > 10_000 {
                    return data
                }
                lastError = URLError(.badServerResponse)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
