/// Configuration for the Generator's generation loop.
public struct GeneratorConfig {
    public let contextLength: Int
    public let prefillBatchSize: Int
    public let stopTokens: Set<Int32>

    public init(contextLength: Int, prefillBatchSize: Int, stopTokens: Set<Int32>) {
        self.contextLength = contextLength
        self.prefillBatchSize = prefillBatchSize
        self.stopTokens = stopTokens
    }
}

/// Configuration for the model's output format.
///
/// CoreML may split the vocabulary across multiple output tensors due to size
/// limits.
public struct ModelOutputConfig {
    public let vocabSize: Int
    /// Number of output chunks the model splits logits into.
    public let logitsChunkCount: Int

    public init(vocabSize: Int, logitsChunkCount: Int) {
        self.vocabSize = vocabSize
        self.logitsChunkCount = logitsChunkCount
    }
}
