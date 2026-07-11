import AimeASR
import AudioCommon
import AVFoundation
import Foundation
import Qwen3ASR
import Speech
import SpeechVAD

// ASR 评测 CLI（W6）：
//   单文件：  swift run -c release aime-bench <audio...> [--backend <id>] [--context <text>] [--vad]
//   测试集：  swift run -c release aime-bench --suite testdata [--backend <id>]
// backend: speechanalyzer | HF 模型 id（默认 aufklarer/Qwen3-ASR-0.6B-MLX-4bit）
// 测试集布局：<dir>/testset.tsv（id\t参考文本），<dir>/audio/<id>.wav

// MARK: - 参数

var files: [String] = []
var backendArg = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
var context: String?
var language: String? = "zh"
var suiteDir: String?
var useVAD = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--backend", "--model": backendArg = args.removeFirst()
    case "--context": context = args.removeFirst()
    case "--language": language = args.removeFirst()
    case "--auto-language": language = nil
    case "--suite": suiteDir = args.removeFirst()
    case "--vad": useVAD = true
    default: files.append(arg)
    }
}

guard suiteDir != nil || !files.isEmpty else {
    print("usage: aime-bench <audio...> | --suite <dir>  [--backend speechanalyzer|<hf-id>] [--context text] [--vad]")
    exit(2)
}

// MARK: - 峰值内存

func peakFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.ledger_phys_footprint_peak) / 1_048_576
}

// MARK: - 混合 CER（中文按字、英文/数字按词，忽略标点与大小写）

func tokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var word = ""
    func flushWord() {
        if !word.isEmpty {
            tokens.append(word)
            word = ""
        }
    }
    for scalar in text.lowercased().unicodeScalars {
        switch scalar.value {
        case 0x4E00 ... 0x9FFF, 0x3400 ... 0x4DBF: // CJK：单字为一个 token
            flushWord()
            tokens.append(String(scalar))
        case 0x30 ... 0x39, 0x61 ... 0x7A: // 数字/拉丁字母：连续段为一个 token
            word.unicodeScalars.append(scalar)
        default: // 标点、空白、全角符号：分隔符
            flushWord()
        }
    }
    flushWord()
    return tokens
}

func editDistance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0 ... b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1 ... a.count {
        current[0] = i
        for j in 1 ... b.count {
            let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
            current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

struct CERStat {
    var errors = 0
    var referenceTokens = 0
    var rate: Double { referenceTokens == 0 ? 0 : Double(errors) / Double(referenceTokens) }
}

// MARK: - 后端抽象（bench 内部：文件转写）

protocol BenchBackend {
    var name: String { get }
    mutating func load() async throws
    func transcribe(url: URL) async throws -> String
}

struct QwenBench: BenchBackend {
    let modelID: String
    let wantVAD: Bool
    let language: String?
    let context: String?
    var name: String { modelID.components(separatedBy: "/").last ?? modelID }
    private var model: Qwen3ASRModel?
    private var vad: SileroVADHolder?

    init(modelID: String, wantVAD: Bool, language: String?, context: String?) {
        self.modelID = modelID
        self.wantVAD = wantVAD
        self.language = language
        self.context = context
    }

    mutating func load() async throws {
        model = try await Qwen3ASRModel.fromPretrained(
            modelId: modelID,
            cacheDir: ModelStore.modelDir(for: modelID),
            offlineMode: ModelStore.hasWeights(for: modelID),
            progressHandler: { progress, status in
                FileHandle.standardError.write(Data("\r\(status) \(Int(progress * 100))%   ".utf8))
            }
        )
        FileHandle.standardError.write(Data("\n".utf8))
        if wantVAD {
            vad = try await SileroVADHolder()
        }
    }

    func transcribe(url: URL) async throws -> String {
        guard let model else { throw AimeError.transcriberNotReady }
        var samples = try AudioFileLoader.load(url: url, targetSampleRate: 16000)
        if let vad {
            guard let trimmed = vad.trim(samples) else { return "" }
            samples = trimmed
        }
        return model.transcribe(audio: samples, sampleRate: 16000, language: language, context: context)
    }
}

/// Silero VAD 修剪（与 AimeASR.Qwen3Inference.vadTrim 同参数）
final class SileroVADHolder {
    private let vad: SileroVADModel

    init() async throws {
        let modelID = SileroVADModel.defaultModelId
        vad = try await SileroVADModel.fromPretrained(
            modelId: modelID,
            engine: .mlx,
            cacheDir: ModelStore.modelDir(for: modelID),
            offlineMode: ModelStore.hasWeights(for: modelID)
        )
    }

    func trim(_ samples: [Float], threshold: Float = 0.5, paddingSeconds: Double = 0.25) -> [Float]? {
        vad.resetState()
        let chunkSize = SileroVADModel.chunkSize
        var firstSpeech: Int?
        var lastSpeech: Int?
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            var chunk = Array(samples[offset ..< end])
            if chunk.count < chunkSize {
                chunk.append(contentsOf: [Float](repeating: 0, count: chunkSize - chunk.count))
            }
            if vad.processChunk(chunk) >= threshold {
                if firstSpeech == nil { firstSpeech = offset }
                lastSpeech = end
            }
            offset = end
        }
        guard let firstSpeech, let lastSpeech else { return nil }
        let padding = Int(paddingSeconds * 16000)
        return Array(samples[max(0, firstSpeech - padding) ..< min(samples.count, lastSpeech + padding)])
    }
}

struct SpeechAnalyzerBench: BenchBackend {
    let name = "SpeechAnalyzer"

    mutating func load() async throws {
        try await SpeechAnalyzerSession.ensureModel(localeID: "zh_CN")
    }

    func transcribe(url: URL) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else {
            throw AimeError.localeUnsupported("zh_CN")
        }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var text = ""
            do {
                for try await result in transcriber.results where result.isFinal {
                    text += String(result.text.characters)
                }
            } catch {}
            return text
        }
        let audioFile = try AVAudioFile(forReading: url)
        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 执行

var backend: BenchBackend = backendArg.lowercased() == "speechanalyzer"
    ? SpeechAnalyzerBench()
    : QwenBench(modelID: backendArg, wantVAD: useVAD, language: language, context: context)

let loadBegan = Date()
try await backend.load()
print("backend: \(backend.name)  load: \(String(format: "%.2f", Date().timeIntervalSince(loadBegan)))s  vad: \(useVAD)")

struct Case {
    var id: String
    var reference: String?
    var url: URL
}

var cases: [Case] = []
if let suiteDir {
    let dir = URL(fileURLWithPath: suiteDir)
    let tsv = try String(contentsOf: dir.appendingPathComponent("testset.tsv"), encoding: .utf8)
    for line in tsv.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let id = String(parts[0])
        cases.append(Case(
            id: id,
            reference: String(parts[1]),
            url: dir.appendingPathComponent("audio/\(id).wav")
        ))
    }
} else {
    cases = files.map { Case(id: URL(fileURLWithPath: $0).lastPathComponent, reference: nil, url: URL(fileURLWithPath: $0)) }
}

var total = CERStat()
var totalAudioSeconds = 0.0
var totalTranscribeSeconds = 0.0
var worst: [(id: String, cer: Double, hyp: String, ref: String)] = []

for (index, testCase) in cases.enumerated() {
    let audioFile = try AVAudioFile(forReading: testCase.url)
    let seconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
    let began = Date()
    let hypothesis = try await backend.transcribe(url: testCase.url)
    let cost = Date().timeIntervalSince(began)
    totalAudioSeconds += seconds
    totalTranscribeSeconds += cost

    if let reference = testCase.reference {
        let refTokens = tokenize(reference)
        let hypTokens = tokenize(hypothesis)
        let errors = editDistance(refTokens, hypTokens)
        total.errors += errors
        total.referenceTokens += refTokens.count
        let cer = refTokens.isEmpty ? 0 : Double(errors) / Double(refTokens.count)
        if cer > 0 {
            worst.append((testCase.id, cer, hypothesis, reference))
        }
        print("[\(index + 1)/\(cases.count)] \(testCase.id)  cer=\(String(format: "%.1f%%", cer * 100))  rtf=\(String(format: "%.2f", cost / max(seconds, 0.01)))")
    } else {
        print("--- \(testCase.id)  audio=\(String(format: "%.1f", seconds))s  transcribe=\(String(format: "%.2f", cost))s  rtf=\(String(format: "%.2f", cost / max(seconds, 0.01)))")
        print(hypothesis)
    }
}

if suiteDir != nil {
    print("\n===== \(backend.name) 汇总 =====")
    print("句数: \(cases.count)  参考 token 数: \(total.referenceTokens)")
    print(String(format: "混合 CER: %.2f%%（错误 %d）", total.rate * 100, total.errors))
    print(String(format: "总音频: %.1fs  总转写: %.1fs  平均 RTF: %.3f", totalAudioSeconds, totalTranscribeSeconds, totalTranscribeSeconds / max(totalAudioSeconds, 0.01)))
    print(String(format: "峰值内存: %.0f MB", peakFootprintMB()))
    if !worst.isEmpty {
        print("\n有错句子（\(worst.count)）：")
        for item in worst.sorted(by: { $0.cer > $1.cer }).prefix(10) {
            print("  \(item.id) cer=\(String(format: "%.0f%%", item.cer * 100))")
            print("    ref: \(item.ref)")
            print("    hyp: \(item.hyp)")
        }
    }
}
