import Foundation
import MLX
import MLXFast
import MLXNN

// 数值回归探针：验证批量 KV cache 解码路径逐位正确。
// 历史背景：MLXNN.RoPE（mlx-swift 0.31.6）offset 路径在 batch>1 时输出脏数据，
// 曾把句准从 78.6% 拖到 72.1%（症状是"语言判断力变差"型错字，极难肉眼定位）。
// 升级 mlx-swift 或改动解码器后先跑：aime-llm --probe。全部行差应为 0。

extension PinyinLocalDecoder {
    /// 打印各级数值探针结果；有非零行差即为批量路径回归。
    public func runDiagnosticProbes() {
        let probe = promptLogits[0].asType(.float32)
        let top = argSort(probe)[(-5)...]
        for id in top.asArray(Int32.self).reversed() {
            print("probe prompt top: \(id) \(probe[Int(id)].item(Float.self))")
        }
        print("probe dtype: logits=\(promptLogits.dtype)")

        // 整段前向 vs 逐步 cache 前向
        let extra: [Int32] = [35946, 101161]  // "我" "喜欢"
        let fullIds = promptIds + extra
        let (fullHidden, _) = model(inputIds: MLXArray(fullIds).expandedDimensions(axis: 0))
        let fullLast = lmHead(fullHidden[0..., fullHidden.dim(1) - 1, 0...]).asType(.float32)

        var stepCache = promptCache
        var stepLogits = promptLogits
        for token in extra {
            let (h, c) = model(inputIds: MLXArray([token]).reshaped([1, 1]), cache: stepCache)
            stepCache = c
            stepLogits = lmHead(h[0..., 0, 0...])
        }
        print("probe 整段 vs cache: \(max(abs(fullLast - stepLogits.asType(.float32))).item(Float.self))")

        // batch=2 + 分叉 gather 置换后与整段一致
        let idx = MLXArray([Int32(0), Int32(0)])
        let batchCache = promptCache.map { (take($0.0, idx, axis: 0), take($0.1, idx, axis: 0)) }
        let input2 = MLXArray([extra[0], extra[0]]).reshaped([2, 1])
        let (h2, c2) = model(inputIds: input2, cache: batchCache)
        print("probe batch行差(hidden): \(max(abs(h2[0] - h2[1])).item(Float.self))")
        let picked = c2.map { (take($0.0, MLXArray([Int32(1)]), axis: 0), take($0.1, MLXArray([Int32(1)]), axis: 0)) }
        let (h3, _) = model(inputIds: MLXArray([extra[1]]).reshaped([1, 1]), cache: picked)
        let batchLast = lmHead(h3[0..., 0, 0...]).asType(.float32)
        print("probe batch+gather vs 整段: \(max(abs(fullLast - batchLast)).item(Float.self))")

        // 上游 MLXNN.RoPE 的 batch bug 是否仍在（信息性输出，不影响本实现）
        let rope = MLXNN.RoPE(dimensions: 128, traditional: false, base: 1000000.0)
        func synth(_ shape: [Int], scale: Float) -> MLXArray {
            let n = shape.reduce(1, *)
            return sin(MLXArray(0 ..< Int32(n)).asType(.float32) * scale).reshaped(shape).asType(.bfloat16)
        }
        let row = synth([1, 16, 1, 128], scale: 0.017)
        let ropeOut = rope(concatenated([row, row], axis: 0), offset: 5)
        print("probe 上游MLXNN.RoPE batch行差(非0=上游bug仍在): \(max(abs(ropeOut[0] - ropeOut[1])).item(Float.self))")

        // 本实现的 batch-safe RoPE
        let ours = applyBatchSafeRoPE(concatenated([row, row], axis: 0), offset: 5, headDim: 128, base: 1000000.0)
        print("probe 本实现RoPE batch行差: \(max(abs(ours[0] - ours[1])).item(Float.self))")
    }
}
