/// Packs two token IDs into a single UInt64 key.
private func bpePack(_ left: Int, _ right: Int) -> UInt64 {
    (UInt64(bitPattern: Int64(left)) << 32) | UInt64(bitPattern: Int64(right))
}

/// Returns if a pair of tokens form a valid BPE encoding.
///
/// Pairs are valid when they would not be merged by BPE. This is a direct
/// translation of is_valid_token_pair from rust-gems/bpe/byte_pair_encoding.rs.
private func bpeIsValidTokenPair(
    pairLookup: [UInt64: Int],
    splitTable: [(left: Int, right: Int)],
    token1 initialToken1: Int,
    token2 initialToken2: Int
) -> Bool {
    var token1 = initialToken1
    var token2 = initialToken2
    var limit = Int.max
    while true {
        let key = bpePack(token1, token2)
        if let combined = pairLookup[key] { if combined < limit { return false } }
        if token1 > token2 {
            limit = token1
            token1 = splitTable[token1].right
            if token1 == limit {
                limit = token2 + 1
                token2 = splitTable[token2].left
                if token2 + 1 == limit { return true }
            }
        } else {
            limit = token2 + 1
            token2 = splitTable[token2].left
            if token2 + 1 == limit {
                limit = token1
                token1 = splitTable[token1].right
                if token1 == limit { return true }
            }
        }
    }
}

/// A vocabulary for encoding and decoding BPE sequences.
///
/// This is a port of the backtracking algorithm from the Rust bpe crate to
/// Swift. See the crate README for an explanation of the algorithm:
/// https://github.com/github/rust-gems/blob/main/crates/bpe/README.md
public struct BPEDictionary {
    /// Bytes for each token, indexed by token ID.
    private let tokenVocab: [[UInt8]]

    /// The (left, right) token IDs each pair was merged from.
    ///
    /// Base tokens have splitTable[id] == (id, id).
    private let splitTable: [(left: Int, right: Int)]

    /// Maps a packed (left, right) pair of token IDs to the merged token ID.
    private let pairLookup: [UInt64: Int]

    /// Leftmost-longest Aho-Corasick automaton over the vocabulary.
    ///
    /// Used to find the first token match in any byte slice in O(match length)
    /// time, enabling the backtracking encoder to avoid re-scanning. Also used
    /// to walk the proper-prefix-token chain via nextPrefixPattern(after:).
    private let ac: AhoCorasick

    public init(_ orderedTokens: [[UInt8]]) {
        tokenVocab = orderedTokens

        var bytesToToken: [ArraySlice<UInt8>: Int] = [:]
        for (id, bytes) in orderedTokens.enumerated() { bytesToToken[bytes[...]] = id }

        let ac = AhoCorasick(orderedPatterns: orderedTokens)

        // build the split table and pair lookup by walking the AC prefix-token
        // chain
        var splitTable: [(left: Int, right: Int)] = []
        var pairLookup: [UInt64: Int] = [:]

        for id in 0..<orderedTokens.count {
            let token = orderedTokens[id]
            var token1: Int? = ac.nextPrefixPattern(after: id)
            var foundSplit = false

            while let t1 = token1 {
                guard t1 < id else {
                    token1 = ac.nextPrefixPattern(after: t1)
                    continue
                }
                let prefixLen = orderedTokens[t1].count
                let suffixSlice: ArraySlice<UInt8> = token[prefixLen...]
                if let token2 = bytesToToken[suffixSlice], token2 < id {
                    if bpeIsValidTokenPair(
                        pairLookup: pairLookup,
                        splitTable: splitTable,
                        token1: t1,
                        token2: token2
                    ) {
                        pairLookup[bpePack(t1, token2)] = id
                        splitTable.append((left: t1, right: token2))
                        foundSplit = true
                        break
                    }
                }
                token1 = ac.nextPrefixPattern(after: t1)
            }

            if !foundSplit { splitTable.append((left: id, right: id)) }
        }

        self.ac = ac
        self.splitTable = splitTable
        self.pairLookup = pairLookup
    }

    public var tokenCount: Int { tokenVocab.count }

    public func tokenBytes(_ id: Int) -> [UInt8]? {
        guard id >= 0, id < tokenVocab.count else { return nil }
        return tokenVocab[id]
    }

    public func isValidTokenPair(_ left: Int, _ right: Int) -> Bool {
        bpeIsValidTokenPair(
            pairLookup: pairLookup,
            splitTable: splitTable,
            token1: left,
            token2: right
        )
    }

    public func encode(_ bytes: [UInt8]) -> [Int] { return encodeWithBacktracking(bytes) }

    public func count(_ bytes: [UInt8]) -> Int { encode(bytes).count }

    public func decode(_ tokens: [Int]) -> [UInt8] {
        var result: [UInt8] = []
        for token in tokens {
            if token >= 0, token < tokenVocab.count { result.append(contentsOf: tokenVocab[token]) }
        }
        return result
    }

    /// Encode bytes using the backtracking algorithm.
    ///
    /// This is a lazy variant of the DP table approach. Rather than filling in
    /// the full last-token table, it greedily places the longest match at each
    /// position, then backtracks when the resulting partial encoding cannot be
    /// extended to a valid full encoding.
    ///
    /// This is a direct translation of BacktrackEncoder in
    /// rust-gems/bpe/src/backtrack_encoder.rs.
    public func encodeWithBacktracking(_ bytes: [UInt8]) -> [Int] {
        guard !bytes.isEmpty else { return [] }

        // dead[pos] = true means we've proven that no valid complete encoding
        // exists when the next token starts at pos
        var dead = [Bool](repeating: false, count: bytes.count + 1)
        var tokens: [Int] = []
        var pos = 0
        var nextTok: Int? = nextMatch(in: bytes, from: pos)

        while let tok = nextTok {
            var token = tok
            // capture before any mutation so we have the right token to undo
            let last = tokens.last

            while true {
                let tokenLen = tokenVocab[token].count
                let endPos = pos + tokenLen

                let validPair = last == nil || isValidTokenPair(last!, token)
                if !dead[endPos] && validPair {
                    // place this token and advance
                    tokens.append(token)
                    pos = endPos
                    nextTok = nextMatch(in: bytes, from: pos)
                    break
                } else if let shorter = nextPrefixOf(token) {
                    // try the next shorter prefix of this token
                    token = shorter
                } else {
                    dead[pos] = true
                    if let lastTok = last {
                        tokens.removeLast()
                        pos -= tokenVocab[lastTok].count
                        nextTok = lastTok
                    } else {
                        nextTok = nil
                    }
                    break
                }
            }
        }

        return tokens
    }

    /// Returns the first leftmost-longest token match at or after pos.
    private func nextMatch(in bytes: [UInt8], from pos: Int) -> Int? {
        guard pos < bytes.count else { return nil }
        var it = ac.leftmostLongestFind(in: bytes[pos...])
        return it.next()?.patternID
    }

    /// Returns the longest proper prefix token of tokenID, or nil if none.
    private func nextPrefixOf(_ tokenID: Int) -> Int? { ac.nextPrefixPattern(after: tokenID) }
}
