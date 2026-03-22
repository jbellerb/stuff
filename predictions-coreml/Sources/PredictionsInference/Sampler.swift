import CoreML

/// Sampler for output tokens.
public struct Sampler {
    public enum Strategy {
        case greedy
        case temperature(Float)
        case topK(Int, Float)
    }

    private let strategy: Strategy

    public init(strategy: Strategy = .greedy) { self.strategy = strategy }

    /// Samples the next token from logits.
    public func sample(from logits: MLTensor) -> MLTensor {
        switch strategy {
        case .greedy: return logits.argmax()
        case .temperature(let temp): return sampleWithTemperature(logits, temperature: temp)
        case .topK(let k, let temp): return sampleTopK(logits, topK: k, temperature: temp)
        }
    }

    private func sampleWithTemperature(_ logits: MLTensor, temperature: Float) -> MLTensor {
        let scaledLogits = logits / temperature
        let probs = scaledLogits.softmax()

        return sampleFromDistribution(probs)
    }

    private func sampleTopK(_ logits: MLTensor, topK: Int, temperature: Float) -> MLTensor {
        guard topK > 0, topK < logits.shape[0] else {
            return sampleWithTemperature(logits, temperature: temperature)
        }

        let (topKScores, topKIndices) = logits.topK(topK)
        let selected = sampleWithTemperature(topKScores, temperature: temperature)

        return topKIndices.gathering(atIndices: selected)
    }

    private func sampleFromDistribution(_ probs: MLTensor) -> MLTensor {
        let random = probs.sum() * Float.random(in: 0..<1)
        var accumulated = probs.cumulativeSum()
        accumulated *= accumulated .< random

        return accumulated.argmax()
    }
}
