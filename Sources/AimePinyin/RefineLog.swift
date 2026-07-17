import Foundation

/// 精修链路耗时日志：~/Library/Logs/aime-refine.log，超 1MB 时从头重写。
/// AimePinyin 不依赖 AimeASR（避免拖 MLX），故不复用 DiagLog，实现同款。
public enum RefineLog {
    private static let queue = DispatchQueue(label: "aime.refinelog", qos: .utility)
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/aime-refine.log")
    private static let maxBytes = 1 << 20

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) [\(ProcessInfo.processInfo.processName)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
