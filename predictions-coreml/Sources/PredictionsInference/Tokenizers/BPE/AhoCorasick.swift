/// Noncontiguous NFA Aho-Corasick automaton with leftmost-longest match
/// semantics.
///
/// Search is O(n) amortized in the length of the haystack.
public struct AhoCorasick {
    private static let rootID = 0
    private static let deadID = 1

    private struct State {
        var children: [UInt8: Int] = [:]
        var fail: Int = AhoCorasick.rootID
        var output: (patternID: Int, length: Int)? = nil
        /// Nearest trie-path ancestor state that carries an output. Used to
        /// walk the proper-prefix-token chain.
        var prefixOutput: Int? = nil
    }

    private let states: [State]
    /// Final trie state for each pattern ID (-1 for empty/skipped patterns).
    private let patternStates: [Int]

    /// Builds the automaton from ordered byte patterns.
    ///
    /// Each pattern's index in the array is its pattern ID. Empty patterns are
    /// silently skipped. If two patterns have identical byte sequences, the one
    /// with the lower index wins.
    public init(orderedPatterns: [[UInt8]]) {
        var states = [State(), State()]  // root = 0, dead = 1
        var patternStates = [Int](repeating: -1, count: orderedPatterns.count)

        // build the trie
        for (id, bytes) in orderedPatterns.enumerated() {
            guard !bytes.isEmpty else { continue }

            var current = AhoCorasick.rootID
            for byte in bytes {
                if let next = states[current].children[byte] {
                    current = next
                } else {
                    let newID = states.count
                    states.append(State())
                    states[current].children[byte] = newID
                    current = newID
                }
            }
            // first pattern with these bytes wins
            if states[current].output == nil {
                states[current].output = (patternID: id, length: bytes.count)
            }
            patternStates[id] = current
        }

        // BFS to compute failure links with leftmost-longest semantics
        var queue: [Int] = []
        for childID in states[AhoCorasick.rootID].children.values {
            states[childID].fail = AhoCorasick.rootID
            queue.append(childID)
        }

        var qi = 0
        while qi < queue.count {
            let stateID = queue[qi]
            qi += 1

            // any state that has an output gets fail = deadID. This forces a
            // pattern boundary after every complete match and gives us the
            // leftmost-longest property. Once we enter a match state we should
            // not be able to traverse the failure chain to start an overlapping
            // earlier match.
            if states[stateID].output != nil { states[stateID].fail = AhoCorasick.deadID }

            let parentFail = states[stateID].fail

            for (label, childID) in states[stateID].children {
                // if the parent fails to dead, all its children do too. Dead
                // states propagates downward through the trie.
                let newFail: Int
                if parentFail == AhoCorasick.deadID {
                    newFail = AhoCorasick.deadID
                } else {
                    // walk the parent's failure chain to find the longest
                    // proper suffix of (parentPath + label) that is a prefix
                    // of some pattern
                    var f = parentFail
                    var found = AhoCorasick.rootID
                    while true {
                        if let next = states[f].children[label] {
                            found = next
                            break
                        }
                        if f == AhoCorasick.rootID {
                            // root has no edge for this label so fail stays
                            break
                        }
                        let nextF = states[f].fail
                        if nextF == AhoCorasick.deadID {
                            // the suffix we'd follow is itself an output state.
                            // Propagate dead to enforce the pattern boundary.
                            found = AhoCorasick.deadID
                            break
                        }
                        f = nextF
                    }
                    newFail = found
                }
                states[childID].fail = newFail
                // prefixOutput stores the nearest trie-path ancestor with an
                // output. stateID is the trie parent of childID, so
                // states[stateID].prefixOutput is already finalized here.
                states[childID].prefixOutput =
                    states[stateID].output != nil ? stateID : states[stateID].prefixOutput
                queue.append(childID)
            }
        }

        self.states = states
        self.patternStates = patternStates
    }

    /// Returns the pattern ID of the longest proper prefix of patternID that
    /// is itself a pattern, or nil if none exists.
    public func nextPrefixPattern(after patternID: Int) -> Int? {
        let stateID = patternStates[patternID]
        guard stateID >= 0, let prefixStateID = states[stateID].prefixOutput else { return nil }
        return states[prefixStateID].output?.patternID
    }

    public struct Match {
        public let start: Int
        public let end: Int
        public let patternID: Int
        public var length: Int { end - start }
    }

    /// Returns an iterator over non-overlapping leftmost-longest matches.
    public func leftmostLongestFind(in haystack: [UInt8]) -> MatchIterator {
        MatchIterator(automaton: self, haystack: haystack[...])
    }

    /// Returns an iterator over non-overlapping leftmost-longest matches in a
    /// slice.
    public func leftmostLongestFind(in haystack: ArraySlice<UInt8>) -> MatchIterator {
        MatchIterator(automaton: self, haystack: haystack)
    }

    /// Follows one byte from stateID using leftmost-longest failure semantics.
    ///
    /// This follows the standard Aho-Corasick failure chain, but short-circuits
    /// to root when a dead failure link is encountered.
    private func nextStateLeftmost(_ stateID: Int, _ byte: UInt8) -> Int {
        var state = stateID
        while true {
            if let next = states[state].children[byte] { return next }
            if state == AhoCorasick.rootID { return AhoCorasick.rootID }
            let f = states[state].fail
            if f == AhoCorasick.deadID { return AhoCorasick.rootID }
            state = f
        }
    }

    public struct MatchIterator: IteratorProtocol, Sequence {
        private let automaton: AhoCorasick
        private let haystack: ArraySlice<UInt8>
        /// Start of the current search window.
        private var searchStart: Int = 0

        fileprivate init(automaton: AhoCorasick, haystack: ArraySlice<UInt8>) {
            self.automaton = automaton
            self.haystack = haystack
        }

        /// Returns the next leftmost-longest match, or nil when exhausted.
        ///
        /// Match positions (start, end) are relative to the slice start.
        public mutating func next() -> Match? {
            var state = AhoCorasick.rootID
            var lastMatch: Match? = nil

            var pos = searchStart
            while haystack.startIndex + pos < haystack.endIndex {
                let byte = haystack[haystack.startIndex + pos]
                let nextState = automaton.nextStateLeftmost(state, byte)

                if nextState == AhoCorasick.rootID {
                    if let m = lastMatch {
                        // searchStart was already set to m.end when the match
                        // was recorded, so the boundary-triggering byte will be
                        // re-examined at the start of the next call
                        return m
                    }

                    // no pending match: stay at root and continue scanning
                }

                state = nextState

                if let output = automaton.states[state].output {
                    // record the longest match ending at this position. A later
                    // output (longer match) from the same search start would
                    // overwrite this. The final value is the longest.
                    lastMatch = Match(
                        start: pos + 1 - output.length,
                        end: pos + 1,
                        patternID: output.patternID
                    )
                    searchStart = pos + 1
                }

                pos += 1
            }

            // end of haystack: emit any pending match
            if let m = lastMatch {
                searchStart = m.end
                return m
            }
            return nil
        }
    }
}
