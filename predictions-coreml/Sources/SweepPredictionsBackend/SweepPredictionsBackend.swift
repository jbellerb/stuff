import CoreML
import Foundation
import Logging
import PredictionsBackends
import PredictionsInference

private let modelName = "sweep-next-edit-1.5B"

private let maxContextLines = 10

@available(macOS 15.0, *)
public class SweepPredictionsBackend: PredictionsBackend {
    public let name = "sweep"
    private let logger: Logger
    private let generator: Generator

    public init(_ cache: ModelCache, logger: Logger) async throws {
        let modelURL = try await cache.compiledModelURL(for: modelName)
        let tokDir = cache.tokenizerDirectory(for: modelName)

        let inferConfig = MLModelConfiguration()
        let inferModel = try MLModel(contentsOf: modelURL, configuration: inferConfig)

        let prefillConfig = MLModelConfiguration()
        prefillConfig.functionName = "prefill"
        let prefillModel = try MLModel(contentsOf: modelURL, configuration: prefillConfig)

        let tokenizer = try SweepTokenizer(
            vocabURL: tokDir.appendingPathComponent("vocab.json"),
            mergesURL: tokDir.appendingPathComponent("merges.txt")
        )

        let generatorConfig = GeneratorConfig(
            contextLength: 8192,
            prefillBatchSize: 64,
            stopTokens: [SweepTokenizer.endOfText, SweepTokenizer.imEnd, SweepTokenizer.fileSep]
        )
        let outputConfig = ModelOutputConfig(vocabSize: 43839, logitsChunkCount: 16)

        self.logger = logger
        self.generator = Generator(
            prefillModel: prefillModel,
            inferModel: inferModel,
            tokenizer: tokenizer,
            config: generatorConfig,
            outputConfig: outputConfig
        )
    }

    public func predict(events: String, excerpt: String) async throws -> String? {
        let editEvents = try EditEvent.parseAll(events)
        let parsedExcerpt = try Excerpt.parse(excerpt)

        let (prompt, editablePrefix, editableSuffix) = buildSweepPrompt(
            events: editEvents,
            excerpt: parsedExcerpt
        )

        let t0 = Date()
        let generated = try await generator.generate(prompt: prompt, maxTokens: 512)

        logger.debug(
            "generated output",
            metadata: [
                "predict.output": "\(generated)",
                "predict.duration": "\(String(format: "%.2f", -t0.timeIntervalSinceNow))s",
            ]
        )

        return String(editablePrefix) + generated + String(editableSuffix)
    }
}

func buildSweepPrompt(events: [EditEvent], excerpt: Excerpt) -> (
    prompt: String, editablePrefix: Substring, editableSuffix: Substring
) {
    let erLB = excerpt.editableRegion.lowerBound
    let erUB = excerpt.editableRegion.upperBound
    let cursorLine = excerpt.cursor.line

    // window the editable region around the cursor
    let windowStart = max(erLB, cursorLine - maxContextLines)
    let windowEnd = min(erUB, cursorLine + maxContextLines + 1)
    let editablePrefix = excerpt[lines: erLB..<windowStart]
    let editableSuffix = excerpt[lines: windowEnd..<erUB]
    let currentContent = excerpt[lines: windowStart..<windowEnd]

    // reconstruct original by reversing the most recent diff
    let originalContent = events.last(where: { $0.path == excerpt.path })
        .flatMap { try? reverseApply($0.diff, to: String(currentContent)) }

    var prompt = ""
    for event in events {
        prompt += "<|file_sep|>\(event.path).diff\n"
        prompt += "original:\n"
        prompt += extractText(from: event.diff, side: .original)
        prompt += "\nupdated:\n"
        prompt += extractText(from: event.diff, side: .updated)
        prompt += "\n"
    }
    prompt += "<|file_sep|>original/\(excerpt.path)\n"
    if let original = originalContent {
        prompt += original
    } else {
        prompt.append(contentsOf: currentContent)
    }
    prompt += "\n<|file_sep|>current/\(excerpt.path)\n"
    prompt.append(contentsOf: currentContent)
    prompt += "\n<|file_sep|>updated/\(excerpt.path)\n"

    return (prompt: prompt, editablePrefix: editablePrefix, editableSuffix: editableSuffix)
}

enum DiffSide { case original, updated }

/// Extract the "before" or "after" text from a diff.
func extractText(from diff: UnifiedDiff, side: DiffSide) -> String {
    diff.hunks
        .map { hunk in
            hunk.lines
                .compactMap { line in
                    switch (line, side) {
                    case (.context(let s), _), (.deletion(let s), .original),
                        (.addition(let s), .updated):
                        return s
                    default: return nil
                    }
                }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
}

/// Apply a diff in reverse to reconstruct the original.
func reverseApply(_ diff: UnifiedDiff, to text: String) throws -> String {
    let reversedHunks = diff.hunks.map { hunk in
        Hunk(
            oldStart: hunk.newStart,
            oldCount: hunk.newCount,
            newStart: hunk.oldStart,
            newCount: hunk.oldCount,
            lines: hunk.lines.map { line in
                switch line {
                case .addition(let s): return DiffLine.deletion(s)
                case .deletion(let s): return DiffLine.addition(s)
                case .context: return line
                }
            }
        )
    }
    return try UnifiedDiff(hunks: reversedHunks).apply(to: text)
}
