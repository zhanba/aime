import AudioCommon
import Foundation
import Qwen3ASR

// ASR 评测 CLI（W6 最小版）：
//   swift run -c release aime-bench <audio...> [--model <hf-id>] [--context <text>] [--language zh]
// 输出每个文件的转写、耗时、RTF，以及模型加载耗时。

var files: [String] = []
var modelID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
var context: String?
var language: String? = "zh"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--model": modelID = args.removeFirst()
    case "--context": context = args.removeFirst()
    case "--language": language = args.removeFirst()
    case "--auto-language": language = nil
    default: files.append(arg)
    }
}

guard !files.isEmpty else {
    print("usage: aime-bench <audio...> [--model <hf-id>] [--context <text>] [--language zh|--auto-language]")
    exit(2)
}

// 必须符合 HF Hub 布局 <base>/models/<org>/<name>，与 app 内 Qwen3Inference.modelDir 一致
let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("aime", isDirectory: true)
    .appendingPathComponent("models", isDirectory: true)
    .appendingPathComponent(modelID, isDirectory: true)
try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

let hasWeights = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil))?
    .contains { $0.pathExtension == "safetensors" } ?? false

let loadBegan = Date()
let model = try await Qwen3ASRModel.fromPretrained(
    modelId: modelID,
    cacheDir: cacheDir,
    offlineMode: hasWeights,
    progressHandler: { progress, status in
        FileHandle.standardError.write(Data("\r\(status) \(Int(progress * 100))%".utf8))
    }
)
FileHandle.standardError.write(Data("\n".utf8))
print("model: \(modelID)")
print(String(format: "load: %.2fs", Date().timeIntervalSince(loadBegan)))

for file in files {
    let url = URL(fileURLWithPath: file)
    let samples = try AudioFileLoader.load(url: url, targetSampleRate: 16000)
    let seconds = Double(samples.count) / 16000
    let began = Date()
    let text = model.transcribe(audio: samples, sampleRate: 16000, language: language, context: context)
    let cost = Date().timeIntervalSince(began)
    print("--- \(url.lastPathComponent)  audio=\(String(format: "%.1f", seconds))s  transcribe=\(String(format: "%.2f", cost))s  rtf=\(String(format: "%.2f", cost / max(seconds, 0.01)))")
    print(text)
}
