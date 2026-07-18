import Foundation

// LMDG 语法模型离线工具：
//   统计:   swift run -c release aime-gram stats <wanxiang.gram>
//   转换:   swift run -c release aime-gram convert <wanxiang.gram> --min-log <阈值> --out gram.bin
//
// .gram 是 librime-octagram 的文件格式（"Rime::Grammar/1.0"）：
//   44B 头(format[32] + checksum u32 + daSize u32 + 相对偏移 i32) + darts-clone 双数组镜像。
//   key = 2–8 个汉字的搭配串（句尾另有 "词$"），自定义变长编码；value = log(词频)×10000。
// 格式知识来源：darts-clone（BSD-2）与 CanCLID/yune 的 MIT 实现；未使用 GPL 代码。

// MARK: - .gram 读取（darts-clone 双数组只读遍历）

struct GramFile {
    let data: Data
    let unitsOffset: Int
    let unitCount: Int

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 44 else { return nil }
        let marker = data.prefix(17)
        guard marker == Data("Rime::Grammar/1.0".utf8) else {
            FileHandle.standardError.write(Data("格式标记不符\n".utf8))
            return nil
        }
        let daSize = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 36, as: UInt32.self))) }
        let relative = data.withUnsafeBytes { Int(Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 40, as: Int32.self))) }
        let payloadOffset = 40 + relative
        guard daSize > 0, payloadOffset >= 44, payloadOffset + daSize * 4 <= data.count else { return nil }
        self.data = data
        self.unitsOffset = payloadOffset
        self.unitCount = daSize
    }

    @inline(__always)
    func unit(_ index: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: unitsOffset + index * 4, as: UInt32.self) }
    }

    // darts-clone 单元位段
    @inline(__always) static func offset(of unit: UInt32) -> Int {
        Int((unit >> 10) << ((unit & (1 << 9)) >> 6))
    }
    @inline(__always) static func label(of unit: UInt32) -> UInt32 {
        unit & ((1 << 31) | 0xFF)
    }
    @inline(__always) static func hasLeaf(_ unit: UInt32) -> Bool {
        (unit >> 8) & 1 == 1
    }
    @inline(__always) static func value(of unit: UInt32) -> UInt32 {
        unit & 0x7FFF_FFFF
    }

    /// DFS 全量枚举 (编码 key, value)。keys ≤ 9 字 ≈ ≤18 字节，深度有限。
    func traverse(_ visit: (_ encodedKey: [UInt8], _ value: UInt32) -> Void) {
        var key: [UInt8] = []
        // 迭代式 DFS：栈元素 = (节点下标, 下一个待试 label)
        var stack: [(node: Int, nextLabel: UInt32)] = [(0, 0)]
        while !stack.isEmpty {
            let (node, next) = stack.removeLast()
            let nodeUnit = unit(node)
            let nodeOffset = GramFile.offset(of: nodeUnit)
            if next == 0 {
                // 首次进入该节点：叶子检查
                if GramFile.hasLeaf(nodeUnit) {
                    let leaf = unit(node ^ nodeOffset)
                    visit(key, GramFile.value(of: leaf))
                }
            }
            var label = next
            var found = false
            while label < 256 {
                if label != 0 {
                    let child = node ^ nodeOffset ^ Int(label)
                    if child < unitCount, GramFile.label(of: unit(child)) == label {
                        stack.append((node, label + 1))
                        stack.append((child, 0))
                        key.append(UInt8(label))
                        found = true
                        break
                    }
                }
                label += 1
            }
            if !found, !key.isEmpty, stack.last?.node != node || stack.isEmpty {
                key.removeLast()
            }
        }
    }
}

// MARK: - octagram key 编解码（ASCII 1 字节 / CJK 基本区 2 字节 / 0xE_ 转义）

enum GramKey {
    static func decode(_ encoded: [UInt8]) -> String? {
        var scalars: [Unicode.Scalar] = []
        var index = 0
        while index < encoded.count {
            let first = encoded[index]
            if first & 0x80 == 0 {
                scalars.append(Unicode.Scalar(first))
                index += 1
            } else if first & 0xF0 == 0xE0 {
                let width = Int(first & 0x0F) + 1
                guard index + width <= encoded.count else { return nil }
                if first == 0xE1, width == 2 {
                    let second = UInt32(encoded[index + 1])
                    guard second >= 0x80, let scalar = Unicode.Scalar((second - 0x40) << 8) else { return nil }
                    scalars.append(scalar)
                } else {
                    return nil  // 其他转义（罕见码位）：LMDG 纯汉字 key 不会出现，丢弃
                }
                index += width
            } else {
                guard index + 2 <= encoded.count else { return nil }
                let codePoint = (UInt32(first) - 0x40) << 8 | UInt32(encoded[index + 1])
                guard let scalar = Unicode.Scalar(codePoint) else { return nil }
                scalars.append(scalar)
                index += 2
            }
        }
        var result = ""
        result.unicodeScalars.append(contentsOf: scalars)
        return result
    }
}

// MARK: - AIMEGRM1 输出（与 AIMELEX1 同构：排序记录 + 偏移表；record = key UTF-8 + value u32LE）

func writeGramBin(entries: [(key: String, value: UInt32)], to url: URL) throws {
    let sorted = entries.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    var records = Data()
    var offsets: [UInt32] = [0]
    offsets.reserveCapacity(sorted.count + 1)
    for entry in sorted {
        records.append(Data(entry.key.utf8))
        var value = entry.value.littleEndian
        withUnsafeBytes(of: &value) { records.append(contentsOf: $0) }
        offsets.append(UInt32(records.count))
    }
    var file = Data("AIMEGRM1".utf8)
    var count = UInt32(sorted.count).littleEndian
    withUnsafeBytes(of: &count) { file.append(contentsOf: $0) }
    for offset in offsets {
        var value = offset.littleEndian
        withUnsafeBytes(of: &value) { file.append(contentsOf: $0) }
    }
    file.append(records)
    try file.write(to: url, options: .atomic)
}

// MARK: - 命令行

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("usage: aime-gram stats <file.gram> | convert <file.gram> --min-log <x10000> [--max-chars n] --out <gram.bin>")
    exit(2)
}
let command = arguments[0]
let gramURL = URL(fileURLWithPath: arguments[1])
guard let gram = GramFile(url: gramURL) else {
    FileHandle.standardError.write(Data("无法读取 \(gramURL.path)\n".utf8))
    exit(1)
}
print("双数组单元数: \(gram.unitCount)")

switch command {
case "stats":
    var total = 0
    var byLength = [Int: Int]()
    var valueBuckets = [Int: Int]()  // log 频整数部分 → 条数
    var undecodable = 0
    var samples: [(String, UInt32)] = []
    let began = Date()
    gram.traverse { encoded, value in
        total += 1
        guard let key = GramKey.decode(encoded) else {
            undecodable += 1
            return
        }
        byLength[key.count, default: 0] += 1
        valueBuckets[Int(value) / 10000, default: 0] += 1
        if samples.count < 20, key.count >= 3, value > 120_000 { samples.append((key, value)) }
    }
    print("总条数: \(total)（无法解码 \(undecodable)），遍历耗时 \(String(format: "%.1f", Date().timeIntervalSince(began)))s")
    print("按 key 长度: \(byLength.sorted { $0.key < $1.key })")
    print("按 log(频) 整数部分: \(valueBuckets.sorted { $0.key < $1.key })")
    print("高频样例: \(samples.map { "\($0.0)=\($0.1)" }.joined(separator: " "))")

case "convert":
    var minLog: UInt32 = 0
    var maxChars = 8
    var outPath: String?
    var rest = Array(arguments.dropFirst(2))
    while !rest.isEmpty {
        let arg = rest.removeFirst()
        switch arg {
        case "--min-log": minLog = UInt32(rest.removeFirst()) ?? 0
        case "--max-chars": maxChars = Int(rest.removeFirst()) ?? 8
        case "--out": outPath = rest.removeFirst()
        default:
            print("未知参数 \(arg)")
            exit(2)
        }
    }
    guard let outPath else {
        print("缺少 --out")
        exit(2)
    }
    var entries: [(key: String, value: UInt32)] = []
    var total = 0
    let began = Date()
    gram.traverse { encoded, value in
        total += 1
        guard value >= minLog, let key = GramKey.decode(encoded) else { return }
        // key 末尾可能是 '$'（句尾标记），字符数按汉字算
        let hanCount = key.hasSuffix("$") ? key.count - 1 : key.count
        guard hanCount <= maxChars else { return }
        entries.append((key, value))
    }
    print("总条数 \(total) → 保留 \(entries.count)（min-log=\(minLog)），遍历 \(String(format: "%.1f", Date().timeIntervalSince(began)))s")
    try writeGramBin(entries: entries, to: URL(fileURLWithPath: outPath))
    let size = ((try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int) ?? 0
    print("输出 \(outPath): \(entries.count) 条, \(String(format: "%.1f", Double(size) / 1_048_576)) MiB")

default:
    print("未知命令 \(command)")
    exit(2)
}
