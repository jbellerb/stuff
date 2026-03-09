import Foundation
import Testing

@testable import PredictionsInference

private let hasQwenTokenFiles = ProcessInfo.processInfo.environment["QWEN_VOCAB_JSON"] != nil

private func makeTokenizer() throws -> Qwen2Tokenizer {
    let vocabPath = ProcessInfo.processInfo.environment["QWEN_VOCAB_JSON"]!
    let mergesPath = ProcessInfo.processInfo.environment["QWEN_MERGES_TXT"]!
    return try Qwen2Tokenizer(
        vocabURL: URL(fileURLWithPath: vocabPath),
        mergesURL: URL(fileURLWithPath: mergesPath)
    )
}

// loaded once for the whole test run
private let sharedTokenizer: Result<Qwen2Tokenizer, any Error> = Result { try makeTokenizer() }

let qwen2TestCases: [(String, [Int])] = [
    ("", []), ("Hello, world!", [9707, 11, 1879, 0]),
    ("The quick brown fox", [785, 3974, 13876, 38835]), (" the", [279]), ("the", [1782]),
    ("in", [258]), ("I'm fine", [40, 2776, 6915]), ("don't", [15007, 944]),
    ("def foo(x):", [750, 15229, 2075, 1648]),
    ("def foo(x):\n    return x + 1", [750, 15229, 2075, 982, 262, 470, 856, 488, 220, 16]),
    ("1234567890", [16, 17, 18, 19, 20, 21, 22, 23, 24, 15]),
    ("3.14159", [18, 13, 16, 19, 16, 20, 24]), ("\n", [198]), ("\n\n", [271]), ("   ", [262]),
    ("foo  bar", [7975, 220, 3619]), ("foo bar", [7975, 3619]), ("café", [924, 58858]),
    ("naïve", [3376, 37572, 586]),
    (#"print("Hello, world!")"#, [1350, 445, 9707, 11, 1879, 88783]),
    (
        "The quick brown fox jumps over the lazy dog.",
        [785, 3974, 13876, 38835, 34208, 916, 279, 15678, 5562, 13]
    ), ("they're, we've, I'll, he'd", [20069, 2299, 11, 582, 3003, 11, 358, 3278, 11, 566, 4172]),
]

@Suite(.enabled(if: hasQwenTokenFiles))
struct Qwen2InitializationTests {
    @Test("Initializes without error")
    func initializesWithoutError() throws { _ = try makeTokenizer() }

    @Test("Throws when vocab file does not exist")
    func throwsOnMissingVocab() {
        let missing = URL(fileURLWithPath: "/nonexistent/vocab.json")
        let merges = URL(fileURLWithPath: "/nonexistent/merges.txt")
        #expect(throws: (any Error).self) {
            try Qwen2Tokenizer(vocabURL: missing, mergesURL: merges)
        }
    }
}

@Suite(.enabled(if: hasQwenTokenFiles))
struct Qwen2TokenizerTests {
    var tok: Qwen2Tokenizer

    init() throws { tok = try sharedTokenizer.get() }

    @Test("All expected encodings match", arguments: qwen2TestCases)
    func encodesExpectedCases(_ test: (String, [Int])) { #expect(tok.encode(test.0) == test.1) }

    @Test("All expected decodings match", arguments: qwen2TestCases)
    func decodesExpectedCases(_ test: (String, [Int])) { #expect(tok.decode(test.1) == test.0) }

    @Test("Encode then decode is identity for all test cases", arguments: qwen2TestCases)
    func encodeDecodeRoundtrip(_ test: (String, [Int])) {
        #expect(tok.decode(tok.encode(test.0)) == test.0)
    }
}
