import CoreML
import Foundation

/// Text generation orchestrator.
@available(macOS 15.0, *)
public class Generator: Sendable {
    private let config: GeneratorConfig
    private let outputConfig: ModelOutputConfig

    private let prefillModel: MLModel
    private let inferModel: MLModel

    private let tokenizer: any Tokenizer
    private let sampler: Sampler

    private var state: MLState

    public init(
        prefillModel: MLModel,
        inferModel: MLModel,
        tokenizer: any Tokenizer,
        config: GeneratorConfig,
        outputConfig: ModelOutputConfig,
        samplerStrategy: Sampler.Strategy = .greedy
    ) {
        self.prefillModel = prefillModel
        self.inferModel = inferModel
        self.tokenizer = tokenizer
        self.config = config
        self.outputConfig = outputConfig
        self.sampler = Sampler(strategy: samplerStrategy)
        self.state = inferModel.makeState()
    }

    /// Generates text from a prompt.
    public func generate(prompt: String, maxTokens: Int = 256) async throws -> String {
        let inputTokens = tokenizer.encode(prompt)
        guard !inputTokens.isEmpty else { throw GeneratorError.emptyPrompt }

        // clear KV cache
        state = inferModel.makeState()

        // prefill to produce the first output token
        var lastToken = try await prefill(tokens: MLTensor(inputTokens))

        var generated: [Int32] = []
        for step in 0..<min(maxTokens, config.contextLength - inputTokens.count) {
            let token = await lastToken.shapedArray(of: Int32.self).scalars[0]
            if config.stopTokens.contains(token) { break }
            generated.append(token)

            let output = try await inferSingleToken(
                token: lastToken,
                position: Int32(inputTokens.count + step)
            )
            let logits = try combineChunks(from: output)
            lastToken = sampler.sample(from: logits)
        }

        return tokenizer.decode(generated)
    }

    private func prefill(tokens: MLTensor) async throws -> MLTensor {
        let numTokens = tokens.shape[0]
        guard numTokens <= config.contextLength else {
            throw GeneratorError.promptTooLong(numTokens, config.contextLength)
        }

        let batchSize = config.prefillBatchSize
        var pos = 0

        // TODO: use batching prefill model
        while pos < numTokens - 1 {
            _ = try await inferSingleToken(token: tokens[pos], position: Int32(pos))
            pos += 1
        }
        let output = try await inferSingleToken(
            token: tokens[numTokens - 1],
            position: Int32(numTokens - 1)
        )
        let logits = try combineChunks(from: output)
        return sampler.sample(from: logits)
    }

    private func inferSingleToken(token: MLTensor, position: Int32) async throws -> [String:
        MLTensor]
    {
        // input_ids: [1, 1] (single token)
        let inputIds = token.reshaped(to: [1, 1])

        // current_pos: [1] (current position in sequence)
        let currentPos = MLTensor([position])

        // position_ids: [1] (single position)
        let positionIds = MLTensor([position])

        // causal_mask: [1, 1, 1, contextLength] (attend all previous positions)
        let causalMask = createCausalMask(
            queryLength: 1,
            startPosition: position,
            validTokens: position + 1
        )

        let input: [String: MLTensor] = [
            "input_ids": inputIds, "current_pos": currentPos, "position_ids": positionIds,
            "causal_mask": causalMask,
        ]

        return try await inferModel.prediction(from: input, using: state, )
    }

    /// Reassembles chunked logit outputs into a single logits tensor.
    ///
    /// CoreML splits the vocab across multiple output tensors due to output
    /// tensor size limits.
    private func combineChunks(from output: [String: MLTensor], position: Int? = nil) throws
        -> MLTensor
    {
        let numChunks = outputConfig.logitsChunkCount
        let vocabSize = outputConfig.vocabSize

        var chunks = [MLTensor]()
        chunks.reserveCapacity(numChunks)

        let baseChunkSize = vocabSize / numChunks
        let remainder = vocabSize % numChunks

        for i in 1...numChunks {
            let expectedChunkSize = baseChunkSize + (i <= remainder ? 1 : 0)
            let featureName = "logits\(i)"
            guard let tensor = output[featureName] else {
                throw GeneratorError.missingLogitsChunk(featureName)
            }

            let shape = tensor.shape
            guard shape.count == 3 else {
                throw GeneratorError.invalidLogitsShape(featureName, shape)
            }

            let batchSize = shape[0]
            let seqLen = shape[1]
            let chunkVocabSize = shape[2]
            guard batchSize == 1, chunkVocabSize == expectedChunkSize else {
                throw GeneratorError.unexpectedLogitsDimensions(
                    featureName,
                    batchSize,
                    chunkVocabSize
                )
            }

            let lastPos = position ?? (seqLen - 1)
            chunks.append(tensor[0, lastPos])
        }

        return MLTensor(concatenating: chunks, alongAxis: 0)
    }

    private func createCausalMask(queryLength: Int32, startPosition: Int32, validTokens: Int32)
        -> MLTensor
    {
        let contextLength = Int32(config.contextLength)

        let columns = MLTensor(rangeFrom: startPosition, to: startPosition + queryLength, by: 1)
            .expandingShape(at: 1)
        let rows = MLTensor(rangeFrom: 0, to: contextLength, by: 1).expandingShape(at: 0)
        let mask = rows .>= validTokens .| rows .> columns

        return MLTensor(zeros: [Int(queryLength), Int(contextLength)], scalarType: Float.self)
            .replacing(with: -Float.infinity, where: mask).expandingShape(at: 0, 1)
    }
}

enum GeneratorError: Error {
    case emptyPrompt
    case promptTooLong(Int, Int)
    case missingLogitsChunk(String)
    case invalidLogitsShape(String, [Int])
    case unexpectedLogitsDimensions(String, Int, Int)
}
