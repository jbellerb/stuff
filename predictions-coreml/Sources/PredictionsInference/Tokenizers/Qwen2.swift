import Foundation

// regex from huggingface/transformers/models/qwen2/tokenization_qwen2.py
let pretokenizerRE =
    #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

public struct Qwen2Tokenizer: Tokenizer {
    private let bpe: BPEDictionary
    private let pretokenizer: NSRegularExpression

    public init(vocabURL: URL, mergesURL: URL) throws {
        // build GPT-2 byte encoder table: printable bytes map to themselves,
        // all others are offset to U+0100+.
        var bs: [Int] = []
        bs += Array(0x21...0x7E)
        bs += Array(0xA1...0xAC)
        bs += Array(0xAE...0xFF)

        var cs: [Int] = bs
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }

        var charToByteTemp: [Character: UInt8] = [:]
        for (b, c) in zip(bs, cs) { charToByteTemp[Character(Unicode.Scalar(c)!)] = UInt8(b) }

        let vocabData = try Data(contentsOf: vocabURL)
        guard let vocabJSON = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int]
        else { throw Qwen2TokenizerError.invalidVocab }
        let sortedVocab = vocabJSON.sorted { $0.value < $1.value }

        // for each token string, decode from GPT-2 byte encoding to [UInt8]
        var orderedTokens: [[UInt8]] = []
        for (tokenStr, _) in sortedVocab {
            var bytes: [UInt8] = []
            for char in tokenStr { if let byte = charToByteTemp[char] { bytes.append(byte) } }
            orderedTokens.append(bytes)
        }
        self.bpe = BPEDictionary(orderedTokens)

        self.pretokenizer = try NSRegularExpression(pattern: pretokenizerRE, options: [])
    }

    public func encode(_ text: String) -> [Int32] {
        guard !text.isEmpty else { return [] }

        let nsText = text as NSString
        let matches = pretokenizer.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )

        var result: [Int32] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let piece = String(text[range])

            // get the raw UTF-8 bytes of this pretoken piece, then BPE encode
            // them. The BPE vocab is stored as raw UTF-8 bytes (after GPT-2
            // byte decoding during init), so we encode the UTF-8 bytes of each
            // piece directly.
            let bytes = Array(piece.utf8)

            result.append(contentsOf: bpe.encode(bytes).map { Int32($0) })
        }

        return result
    }

    public func decode(_ tokens: [Int32]) -> String {
        guard !tokens.isEmpty else { return "" }

        var allBytes: [UInt8] = []
        for tokenId in tokens {
            if let bytes = bpe.tokenBytes(Int(tokenId)) { allBytes.append(contentsOf: bytes) }
        }

        return String(decoding: allBytes, as: UTF8.self)
    }
}

public enum Qwen2TokenizerError: Error { case invalidVocab }
