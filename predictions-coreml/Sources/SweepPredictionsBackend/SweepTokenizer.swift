import Foundation
import PredictionsBackends
import PredictionsInference

/// Qwen2 tokenizer with Sweep special token handling.
struct SweepTokenizer: Tokenizer {
    private let inner: Qwen2Tokenizer

    static let endOfText: Int32 = 43816
    static let imStart: Int32 = 43817
    static let imEnd: Int32 = 43818
    static let fileSep: Int32 = 43837

    // special tokens extracted before BPE encoding. Longest-first for
    // unambiguous prefix matching.
    private static let specialTokenMap: [(text: String, id: Int32)] = [
        ("<|endoftext|>", endOfText), ("<|im_start|>", imStart), ("<|im_end|>", imEnd),
        ("<|file_sep|>", fileSep),
    ]

    init(vocabURL: URL, mergesURL: URL) throws {
        self.inner = try Qwen2Tokenizer(vocabURL: vocabURL, mergesURL: mergesURL)
    }

    func encode(_ text: String) -> [Int32] {
        var result: [Int32] = []
        var remaining = text

        while !remaining.isEmpty {
            var matched = false
            for (tokenText, tokenId) in Self.specialTokenMap {
                if remaining.hasPrefix(tokenText) {
                    result.append(tokenId)
                    remaining = String(remaining.dropFirst(tokenText.count))
                    matched = true
                    break
                }
            }
            if matched { continue }

            // BPE-encode the text up to the next special token
            var nextSpecial = remaining.endIndex
            for (tokenText, _) in Self.specialTokenMap {
                if let range = remaining.range(of: tokenText), range.lowerBound < nextSpecial {
                    nextSpecial = range.lowerBound
                }
            }

            let chunk = String(remaining[..<nextSpecial])
            if !chunk.isEmpty { result.append(contentsOf: inner.encode(chunk)) }
            remaining = String(remaining[nextSpecial...])
        }

        return result
    }

    func decode(_ tokenIds: [Int32]) -> String {
        let filtered = tokenIds.filter { id in
            id != Self.endOfText && id != Self.imStart && id != Self.imEnd && id != Self.fileSep
        }
        return inner.decode(filtered)
    }
}
