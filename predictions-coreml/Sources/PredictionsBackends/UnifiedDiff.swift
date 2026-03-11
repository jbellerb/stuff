import Foundation

public struct UnifiedDiff {
    public let hunks: [Hunk]

    public init(hunks: [Hunk]) { self.hunks = hunks }
}

public struct Hunk {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public enum DiffLine: Equatable {
    case context(String)
    case addition(String)
    case deletion(String)
}

extension UnifiedDiff {
    /// Parse a unified diff string into a structured UnifiedDiff. Skips "---"/
    /// "+++" header lines and parses "@@" hunks.
    public static func parse(_ input: String) throws -> UnifiedDiff {
        let lines = input.components(separatedBy: "\n")
        var i = lines.startIndex

        while i < lines.endIndex && (lines[i].hasPrefix("--- ") || lines[i].hasPrefix("+++ ")) {
            i = lines.index(after: i)
        }

        var hunks: [Hunk] = []

        while i < lines.endIndex {
            let line = lines[i]

            if line.isEmpty || line.hasPrefix("---") || line.hasPrefix("+++") {
                i = lines.index(after: i)
                continue
            }

            // parse @@ header if present, otherwise start a headerless hunk
            let isHeaderless: Bool
            let hunk: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)
            if line.hasPrefix("@@") {
                isHeaderless = false
                hunk = try parseHunkHeader(line)
                i = lines.index(after: i)
            } else if line.hasPrefix("-") || line.hasPrefix("+") || line.hasPrefix(" ") {
                isHeaderless = true
                hunk = (oldStart: 1, oldCount: 0, newStart: 1, newCount: 0)
            } else {
                throw UnifiedDiffError.unexpectedLine(line)
            }

            var diffLines: [DiffLine] = []
            var oldConsumed = 0
            var newConsumed = 0

            while i < lines.endIndex
                && (isHeaderless || oldConsumed < hunk.oldCount || newConsumed < hunk.newCount)
            {
                let l = lines[i]
                if l.hasPrefix(" ") {
                    diffLines.append(.context(String(l.dropFirst())))
                    oldConsumed += 1
                    newConsumed += 1
                } else if l.hasPrefix("+") {
                    diffLines.append(.addition(String(l.dropFirst())))
                    newConsumed += 1
                } else if l.hasPrefix("-") {
                    diffLines.append(.deletion(String(l.dropFirst())))
                    oldConsumed += 1
                } else if l.isEmpty {
                    // tolerate a missing leading space on blank context lines
                    diffLines.append(.context(""))
                    oldConsumed += 1
                    newConsumed += 1
                } else {
                    break
                }
                i = lines.index(after: i)
            }

            hunks.append(
                Hunk(
                    oldStart: hunk.oldStart,
                    oldCount: isHeaderless ? oldConsumed : hunk.oldCount,
                    newStart: hunk.newStart,
                    newCount: isHeaderless ? newConsumed : hunk.newCount,
                    lines: diffLines
                )
            )
        }

        return UnifiedDiff(hunks: hunks)
    }

    private static let hunkHeaderRegex = #/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/#

    private static func parseHunkHeader(_ line: String) throws -> (
        oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    ) {
        guard let match = try hunkHeaderRegex.firstMatch(in: line) else {
            throw UnifiedDiffError.invalidHunkHeader(line)
        }

        let oldStart = Int(match.1) ?? 0
        let oldCount = match.2.flatMap { Int($0) } ?? 1
        let newStart = Int(match.3) ?? 0
        let newCount = match.4.flatMap { Int($0) } ?? 1

        return (oldStart, oldCount, newStart, newCount)
    }

    /// Render a UnifiedDiff back to a unified diff string.
    public func render() -> String {
        var out = ""
        for hunk in hunks {
            let oldCountStr = hunk.oldCount == 1 ? "" : ",\(hunk.oldCount)"
            let newCountStr = hunk.newCount == 1 ? "" : ",\(hunk.newCount)"
            out += "@@ -\(hunk.oldStart)\(oldCountStr) +\(hunk.newStart)\(newCountStr) @@\n"
            for line in hunk.lines {
                switch line {
                case .context(let s): out += " \(s)\n"
                case .addition(let s): out += "+\(s)\n"
                case .deletion(let s): out += "-\(s)\n"
                }
            }
        }
        return out
    }

    /// Apply this diff to source and return the modified text.
    public func apply(to source: String) throws -> String {
        let endsWithNewline = source.hasSuffix("\n")
        var sourceLines = source.components(separatedBy: "\n")
        if endsWithNewline { sourceLines.removeLast() }

        var output: [String] = []
        // sourcePos is 0-based, hunk oldStart is 1-based
        var sourcePos = 0

        for hunk in hunks {
            // when starting a new-file hunk, oldStart = 0. Clamp to 0 to avoid
            // going negative.
            let hunkStart = max(hunk.oldStart - 1, 0)

            guard hunkStart >= sourcePos else {
                throw UnifiedDiffError.hunkOutOfOrder(hunk.oldStart)
            }
            guard hunkStart <= sourceLines.count else {
                throw UnifiedDiffError.hunkBeyondEnd(hunk.oldStart, sourceLines.count)
            }

            // copy unchanged lines before this hunk
            output.append(contentsOf: sourceLines[sourcePos..<hunkStart])
            sourcePos = hunkStart

            // apply hunk lines
            for line in hunk.lines {
                switch line {
                case .context(let s):
                    guard sourcePos < sourceLines.count else {
                        throw UnifiedDiffError.contextMismatch(s, sourcePos)
                    }
                    guard sourceLines[sourcePos] == s else {
                        throw UnifiedDiffError.contextMismatch(s, sourcePos)
                    }
                    output.append(s)
                    sourcePos += 1
                case .deletion(let s):
                    guard sourcePos < sourceLines.count else {
                        throw UnifiedDiffError.contextMismatch(s, sourcePos)
                    }
                    guard sourceLines[sourcePos] == s else {
                        throw UnifiedDiffError.deletionMismatch(s, sourceLines[sourcePos])
                    }
                    sourcePos += 1
                case .addition(let s): output.append(s)
                }
            }
        }

        // copy any remaining lines after the last hunk
        output.append(contentsOf: sourceLines[sourcePos...])

        let joined = output.joined(separator: "\n")
        return endsWithNewline ? joined + "\n" : joined
    }
}

public enum UnifiedDiffError: Error, Equatable {
    case invalidHunkHeader(String)
    case unexpectedLine(String)
    case hunkOutOfOrder(Int)
    case hunkBeyondEnd(Int, Int)
    case contextMismatch(String, Int)
    case deletionMismatch(String, String)
}
