import Testing

@testable import PredictionsInference

// the "README vocabulary" from the Rust bpe crate documentation
let readmeVocab: [[UInt8]] = [
    [0x61],  // 0: "a"
    [0x62],  // 1: "b"
    [0x63],  // 2: "c"
    [0x61, 0x62],  // 3: "ab" = a(0) + b(1)
    [0x63, 0x62],  // 4: "cb" = c(2) + b(1)
    [0x61, 0x63],  // 5: "ac" = a(0) + c(2)
    [0x62, 0x62],  // 6: "bb" = b(1) + b(1)
    [0x63, 0x62, 0x62],  // 7: "cbb" = cb(4) + b(1)
    [0x61, 0x63, 0x62, 0x62],  // 8: "acbb" = a(0) + cbb(7)
]

// The split of "acbb" as a + cbb instead of ac + bb is the central
// case that distinguishes correct BPE from naive implementations. When BPE
// processes "acbb", applying rank-1 merge (c + b -> cb) before rank-2
// (a + c -> ac) means the split is actually a|cbb, not ac|bb.
//
// Expected values were derived by tracing the BPE algorithm and the
// is_valid_token_pair function from rust-gems/bpe/byte_pair_encoding.rs.

let testCases: [([UInt8], [Int])] = [
    ([0x61], [0]),  // "a" -> a
    ([0x61, 0x62], [3]),  // "ab" -> ab
    ([0x61, 0x62, 0x61, 0x63, 0x62, 0x62], [3, 8]),  // "abacbb" -> ab + acbb
    ([0x61, 0x62, 0x61, 0x63, 0x62], [3, 0, 4]),  // "abacb" -> ab + a + cb
    ([0x61, 0x63, 0x62, 0x62], [8]),  // "acbb" -> acbb
    ([0x63, 0x62, 0x62], [7]),  // "cbb" -> cbb
    ([0x62, 0x62, 0x62], [6, 1]),  // "bbb" -> bb + b
    ([0x63, 0x62, 0x62, 0x62], [4, 6]),  // "cbbb" -> cb + bb
    ([0x63, 0x62, 0x63, 0x62], [4, 4]),  // "cbcb" -> cb + cb
]

@Suite
struct BPEInitializationTests {
    @Test("Initializes from empty vocabulary")
    func initializesFromEmptyVocabulary() {
        let bpe = BPEDictionary([])
        #expect(bpe.tokenCount == 0)
    }

    @Test("Initializes from single-token vocabulary")
    func initializesFromSingleToken() {
        let bpe = BPEDictionary([[0x61]])
        #expect(bpe.tokenCount == 1)
    }

    @Test("Initializes from ordered vocabulary with correct token count")
    func initializesFromOrderedVocabulary() {
        let bpe = BPEDictionary(readmeVocab)
        #expect(bpe.tokenCount == 9)
    }

    @Test("tokenBytes returns correct bytes for each token ID")
    func tokenBytesMatchVocabulary() {
        let bpe = BPEDictionary(readmeVocab)
        for (id, expectedBytes) in readmeVocab.enumerated() {
            #expect(bpe.tokenBytes(id) == expectedBytes)
        }
    }

    @Test("tokenBytes returns nil for invalid IDs")
    func tokenBytesReturnsNilForInvalidID() {
        let bpe = BPEDictionary(readmeVocab)
        #expect(bpe.tokenBytes(-1) == nil)
        #expect(bpe.tokenBytes(9) == nil)
    }
}

@Suite
struct BPEEncodingTests {
    let bpe = BPEDictionary(readmeVocab)

    @Test("Empty input encodes to empty output")
    func encodesEmptyInput() { #expect(bpe.encode([]) == []) }

    @Test("Single byte tokens encode to their token ID")
    func encodesSingleBaseBytes() {
        #expect(bpe.encode([0x61]) == [0])  // "a" = 0
        #expect(bpe.encode([0x62]) == [1])  // "b" = 1
        #expect(bpe.encode([0x63]) == [2])  // "c" = 2
    }

    @Test("Vocabulary tokens encodes to themselves")
    func vocabTokensEncodesToSelf() {
        let bpe = BPEDictionary(readmeVocab)
        for id in 0..<readmeVocab.count {
            let bytes = readmeVocab[id]
            let tokens = bpe.encode(bytes)
            #expect(
                tokens == [id],
                "token \(id) \(bytes) should encode to [\(id)] but got \(tokens)"
            )
        }
    }

    @Test("Last token for prefixes of 'abacbb' matches README table")
    func lastTokenForEachPrefix() {
        let text: [UInt8] = [0x61, 0x62, 0x61, 0x63, 0x62, 0x62]
        let expectedLastTokens = [
            0,  // "a" -> a = 0
            3,  // "ab" -> ab = 3
            0,  // "aba" -> a = 0
            5,  // "abac" -> ac = 5
            4,  // "abacb" -> cb = 4
            8,  // "abacbb" -> acbb = 8
        ]
        for (i, expectedLast) in expectedLastTokens.enumerated() {
            let prefix = Array(text[0...i])
            let tokens = bpe.encode(prefix)
            #expect(
                tokens.last == expectedLast,
                """
                prefix[0...\(i)]: expected last token \(expectedLast), got \
                \(String(describing: tokens.last))
                """
            )
        }
    }

    @Test("Encodes 'abacbb' to [ab, acbb]")
    func encodesReadmeExample() {
        let input: [UInt8] = [0x61, 0x62, 0x61, 0x63, 0x62, 0x62]
        #expect(bpe.encode(input) == [3, 8])
        #expect(bpe.encode(input) != [3, 0, 7])  // not the greedy [ab, a, cbb]
    }

    @Test("All expected encodings match", arguments: testCases)
    func encodesExpectedCases(_ test: ([UInt8], [Int])) { #expect(bpe.encode(test.0) == test.1) }
}

@Suite
struct BPETokenPairTests {
    let bpe = BPEDictionary(readmeVocab)

    @Test("Direct merge pairs are not valid adjacent tokens")
    func directMergePairsAreInvalid() {
        #expect(!bpe.isValidTokenPair(0, 1))  // a + b -> ab = 3
        #expect(!bpe.isValidTokenPair(2, 1))  // c + b -> cb = 4
        #expect(!bpe.isValidTokenPair(0, 2))  // a + c -> ac = 5
        #expect(!bpe.isValidTokenPair(1, 1))  // b + b -> bb = 6
        #expect(!bpe.isValidTokenPair(4, 1))  // cb + b -> cbb = 7
        #expect(!bpe.isValidTokenPair(0, 7))  // a + cbb -> acbb = 8
    }

    @Test("Pairs with no applicable merge are valid adjacent tokens")
    func noMergePairsAreValid() {
        #expect(bpe.isValidTokenPair(3, 0))  // ab + a: "aba" not in vocab
        #expect(bpe.isValidTokenPair(3, 8))  // ab + acbb: the adjacent pair in encode("abacbb")
        #expect(bpe.isValidTokenPair(3, 4))  // ab + cb: "abcb" not in vocab
        #expect(bpe.isValidTokenPair(2, 0))  // c + a: "ca" not in vocab
        #expect(bpe.isValidTokenPair(6, 1))  // bb + b: "bbb" not in vocab
        #expect(bpe.isValidTokenPair(4, 6))  // cb + bb: "cbbb" not in vocab
    }

    @Test("ac + bb is not a valid adjacent pair")
    func acPlusBbIsInvalidPair() {
        // ac + bb looks like a natural split of "acbb", but it's invalid. ac
        // splits as a + c, and bb splits as b + b. When we split both and check
        // the sub-pairs, we find c + b -> cb = 4 with rank 4 < limit = 5. This
        // means BPE would merge across the ac|bb boundary. Therefore, "acbb"
        // must encodes to a single token.
        #expect(!bpe.isValidTokenPair(5, 6))
    }

    @Test("Token pair validity is asymmetric")
    func pairValidityIsAsymmetric() {
        #expect(!bpe.isValidTokenPair(0, 1))  // a + b merges
        #expect(bpe.isValidTokenPair(1, 0))  // b + a doesn't merge
    }

    @Test("Adjacent pairs in encodings are stable", arguments: testCases)
    func allEncodingsAreStable(_ test: ([UInt8], [Int])) {
        let tokens = bpe.encode(test.0)
        for i in 0..<tokens.count - 1 {
            #expect(
                bpe.isValidTokenPair(tokens[i], tokens[i + 1]),
                """
                pair at index \(i) in encoding of \
                \(String(validating: test.0, as: UTF8.self)) is not stable
                """
            )
        }
    }
}

@Suite
struct BPECountTests {
    let bpe = BPEDictionary(readmeVocab)

    @Test("Count of empty input is zero")
    func countEmptyInput() { #expect(bpe.count([]) == 0) }

    @Test("All expected encoding lengths match their counts", arguments: testCases)
    func countMatchesEncodeLength(_ test: ([UInt8], [Int])) {
        #expect(bpe.count(test.0) == test.1.count)
    }
}

@Suite
struct BPEDecodeTests {
    let bpe = BPEDictionary(readmeVocab)

    @Test("Empty sequence decodes to empty bytes")
    func decodesEmptySequence() { #expect(bpe.decode([]) == []) }

    @Test("Individual token IDs decode to their vocabulary bytes")
    func decodesIndividualTokens() {
        for (id, expectedBytes) in readmeVocab.enumerated() {
            #expect(bpe.decode([id]) == expectedBytes)
        }
    }

    @Test("All expected decodings match", arguments: testCases)
    func decodesExpectedCases(_ test: ([UInt8], [Int])) { #expect(bpe.decode(test.1) == test.0) }

    @Test("Encode then decode is identity for all test cases", arguments: testCases)
    func encodeDecodeRoundtrip(_ test: ([UInt8], [Int])) {
        #expect(bpe.decode(bpe.encode(test.0)) == test.0)
    }
}
