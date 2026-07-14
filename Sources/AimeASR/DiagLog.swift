import Foundation

/// 音频链路诊断日志。unified logging 在部分环境查询不到（log show 无记录），
/// 因此直接落文件：~/Library/Logs/aime-audio.log，超 1MB 时从头重写。
enum DiagLog {
    private static let queue = DispatchQueue(label: "aime.diaglog", qos: .utility)
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/aime-audio.log")
    private static let maxBytes = 1 << 20

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
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
