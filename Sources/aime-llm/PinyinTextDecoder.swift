import Foundation
import MLX
import MLXCommon
import MLXFast
import MLXNN
import Qwen3ASR

// Qwen3 文本解码器（vendored 自 qwen3-asr-swift 的 QuantizedTextDecoder，仅一处实质改动）：
// MLXNN.RoPE 的 offset 路径在 batch>1 时输出脏数据（probe7/8/9 实证：相同两行输入、
// 输出行差 2.14，且不是简单的位置错位）——beam 批量解码依赖 batch 正确性，
// 这里改用手写的 batch-safe RoPE。其余结构与上游一致，权重布局兼容
// mlx-community/Qwen3-0.6B-4bit（model.* 前缀，tie embeddings 无 lm_head）。

/// batch-safe RoPE（split-half，非 traditional，与 Qwen3 一致）。
/// 位置 = offset + 序列内偏移，对 batch 维广播——不随行号漂移。
func applyBatchSafeRoPE(_ x: MLXArray, offset: Int, headDim: Int, base: Float) -> MLXArray {
    let half = headDim / 2
    let seqLen = x.dim(2)
    let exponents = MLXArray(stride(from: 0, to: headDim, by: 2).map { Float($0) / Float(headDim) })
    let invFreq = 1.0 / pow(MLXArray(base), exponents)  // [half]
    let positions = MLXArray((0 ..< seqLen).map { Float($0 + offset) })  // [S]
    let angles = positions.expandedDimensions(axis: 1) * invFreq.expandedDimensions(axis: 0)  // [S, half]
    let cosA = cos(angles).asType(x.dtype).reshaped([1, 1, seqLen, half])
    let sinA = sin(angles).asType(x.dtype).reshaped([1, 1, seqLen, half])
    let x1 = x[.ellipsis, 0 ..< half]
    let x2 = x[.ellipsis, half ..< headDim]
    return concatenated([x1 * cosA - x2 * sinA, x2 * cosA + x1 * sinA], axis: -1)
}

final class PinyinTextAttention: Module {
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float
    let ropeBase: Float

    @ModuleInfo var qProj: QuantizedLinear
    @ModuleInfo var kProj: QuantizedLinear
    @ModuleInfo var vProj: QuantizedLinear
    @ModuleInfo var oProj: QuantizedLinear
    @ModuleInfo var qNorm: RMSNorm
    @ModuleInfo var kNorm: RMSNorm

    init(config: TextDecoderConfig) {
        self.numHeads = config.numHeads
        self.numKVHeads = config.numKVHeads
        self.headDim = config.headDim
        self.scale = 1.0 / sqrt(Float(config.headDim))
        self.ropeBase = config.ropeTheta

        let hiddenSize = config.hiddenSize
        self._qProj.wrappedValue = QuantizedLinear(
            hiddenSize, numHeads * headDim, bias: false,
            groupSize: config.groupSize, bits: config.bits)
        self._kProj.wrappedValue = QuantizedLinear(
            hiddenSize, numKVHeads * headDim, bias: false,
            groupSize: config.groupSize, bits: config.bits)
        self._vProj.wrappedValue = QuantizedLinear(
            hiddenSize, numKVHeads * headDim, bias: false,
            groupSize: config.groupSize, bits: config.bits)
        self._oProj.wrappedValue = QuantizedLinear(
            numHeads * headDim, hiddenSize, bias: false,
            groupSize: config.groupSize, bits: config.bits)
        self._qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self._kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        attentionMask: MLXArray? = nil,
        cache: (MLXArray, MLXArray)? = nil
    ) -> (MLXArray, (MLXArray, MLXArray)) {
        let (batch, seqLen) = (hiddenStates.dim(0), hiddenStates.dim(1))

        var queries = qProj(hiddenStates)
        var keys = kProj(hiddenStates)
        var values = vProj(hiddenStates)

        queries = queries.reshaped(batch, seqLen, numHeads, headDim)
        keys = keys.reshaped(batch, seqLen, numKVHeads, headDim)
        values = values.reshaped(batch, seqLen, numKVHeads, headDim)

        queries = qNorm(queries)
        keys = kNorm(keys)

        queries = queries.transposed(0, 2, 1, 3)
        keys = keys.transposed(0, 2, 1, 3)
        values = values.transposed(0, 2, 1, 3)

        let offset = cache?.0.dim(2) ?? 0
        queries = applyBatchSafeRoPE(queries, offset: offset, headDim: headDim, base: ropeBase)
        keys = applyBatchSafeRoPE(keys, offset: offset, headDim: headDim, base: ropeBase)

        var cachedKeys = keys
        var cachedValues = values
        if let (prevKeys, prevValues) = cache {
            cachedKeys = concatenated([prevKeys, keys], axis: 2)
            cachedValues = concatenated([prevValues, values], axis: 2)
        }

        let merged = SDPA.attendAndMerge(
            qHeads: queries, kHeads: cachedKeys, vHeads: cachedValues,
            scale: scale, mask: attentionMask)
        return (oProj(merged), (cachedKeys, cachedValues))
    }
}

final class PinyinTextLayer: Module {
    @ModuleInfo var selfAttn: PinyinTextAttention
    @ModuleInfo var mlp: QuantizedMLP
    @ModuleInfo var inputLayerNorm: RMSNorm
    @ModuleInfo var postAttentionLayerNorm: RMSNorm

    init(config: TextDecoderConfig) {
        self._selfAttn.wrappedValue = PinyinTextAttention(config: config)
        self._mlp.wrappedValue = QuantizedMLP(
            hiddenSize: config.hiddenSize, intermediateSize: config.intermediateSize,
            groupSize: config.groupSize, bits: config.bits)
        self._inputLayerNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(
        _ hiddenStates: MLXArray,
        attentionMask: MLXArray? = nil,
        cache: (MLXArray, MLXArray)? = nil
    ) -> (MLXArray, (MLXArray, MLXArray)) {
        let residual = hiddenStates
        var hidden = inputLayerNorm(hiddenStates)
        let (attnOutput, newCache) = selfAttn(hidden, attentionMask: attentionMask, cache: cache)
        hidden = residual + attnOutput
        let residual2 = hidden
        hidden = postAttentionLayerNorm(hidden)
        hidden = mlp(hidden)
        return (residual2 + hidden, newCache)
    }
}

final class PinyinTextModel: Module {
    let config: TextDecoderConfig

    @ModuleInfo var embedTokens: PreQuantizedEmbedding
    @ModuleInfo var layers: [PinyinTextLayer]
    @ModuleInfo var norm: RMSNorm

    init(config: TextDecoderConfig) {
        self.config = config
        self._embedTokens.wrappedValue = PreQuantizedEmbedding(
            embeddingCount: config.vocabSize,
            dimensions: config.hiddenSize,
            groupSize: config.groupSize,
            bits: config.bits)
        self._layers.wrappedValue = (0 ..< config.numLayers).map { _ in
            PinyinTextLayer(config: config)
        }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(
        inputIds: MLXArray,
        cache: [(MLXArray, MLXArray)]? = nil
    ) -> (MLXArray, [(MLXArray, MLXArray)]) {
        var hiddenStates = embedTokens(inputIds)
        let seqLen = hiddenStates.dim(1)

        // seq=1 的自回归步可看全部缓存位置，无需 mask；prefill 造因果 mask
        var mask: MLXArray?
        if seqLen > 1 {
            let cacheLen = cache?.first?.0.dim(2) ?? 0
            let rows = (MLXArray(0 ..< Int32(seqLen)) + Int32(cacheLen)).expandedDimensions(axis: 1)
            let cols = MLXArray(0 ..< Int32(seqLen + cacheLen)).expandedDimensions(axis: 0)
            mask = MLX.where(cols .> rows, MLXArray(Float(-1e9)), MLXArray(Float(0)))
                .expandedDimensions(axes: [0, 1])
                .asType(hiddenStates.dtype)
        }

        var newCache: [(MLXArray, MLXArray)] = []
        newCache.reserveCapacity(layers.count)
        for (i, layer) in layers.enumerated() {
            let (output, updated) = layer(hiddenStates, attentionMask: mask, cache: cache?[i])
            hiddenStates = output
            newCache.append(updated)
        }
        return (norm(hiddenStates), newCache)
    }
}

/// mlx-community/Qwen3-0.6B-4bit 权重装载（model.* 前缀 → 组件），
/// 用 qwen3-asr-swift 公开的 CommonWeightLoader helper 逐 shard 应用。
enum PinyinDecoderLoader {
    static func load(into model: PinyinTextModel, from directory: URL) throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !files.isEmpty else {
            throw NSError(domain: "aime-llm", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "目录内无 safetensors: \(directory.path)",
            ])
        }
        for file in files {
            let raw = try MLX.loadArrays(url: file)
            var weights: [String: MLXArray] = [:]
            for (key, value) in raw where key.hasPrefix("model.") {
                weights[String(key.dropFirst("model.".count))] = value
            }
            guard !weights.isEmpty else { continue }
            CommonWeightLoader.applyQuantizedEmbeddingWeights(
                to: model.embedTokens, prefix: "embed_tokens", from: weights)
            CommonWeightLoader.applyRMSNormWeights(to: model.norm, prefix: "norm", from: weights)
            for (index, layer) in model.layers.enumerated() {
                let prefix = "layers.\(index)"
                CommonWeightLoader.applyQuantizedLinearWeights(
                    to: layer.selfAttn.qProj, prefix: "\(prefix).self_attn.q_proj", from: weights)
                CommonWeightLoader.applyQuantizedLinearWeights(
                    to: layer.selfAttn.kProj, prefix: "\(prefix).self_attn.k_proj", from: weights)
                CommonWeightLoader.applyQuantizedLinearWeights(
                    to: layer.selfAttn.vProj, prefix: "\(prefix).self_attn.v_proj", from: weights)
                CommonWeightLoader.applyQuantizedLinearWeights(
                    to: layer.selfAttn.oProj, prefix: "\(prefix).self_attn.o_proj", from: weights)
                CommonWeightLoader.applyRMSNormWeights(
                    to: layer.selfAttn.qNorm, prefix: "\(prefix).self_attn.q_norm", from: weights)
                CommonWeightLoader.applyRMSNormWeights(
                    to: layer.selfAttn.kNorm, prefix: "\(prefix).self_attn.k_norm", from: weights)
                CommonWeightLoader.applyQuantizedLinearWeights(
                    to: layer.mlp.gateProj, prefix: "\(prefix).mlp.gate_proj", from: weights)
                CommonWeightLoader.applyQuantizedLinearWeights(
                    to: layer.mlp.upProj, prefix: "\(prefix).mlp.up_proj", from: weights)
                CommonWeightLoader.applyQuantizedLinearWeights(
                    to: layer.mlp.downProj, prefix: "\(prefix).mlp.down_proj", from: weights)
                CommonWeightLoader.applyRMSNormWeights(
                    to: layer.inputLayerNorm, prefix: "\(prefix).input_layernorm", from: weights)
                CommonWeightLoader.applyRMSNormWeights(
                    to: layer.postAttentionLayerNorm, prefix: "\(prefix).post_attention_layernorm", from: weights)
            }
        }
    }
}
