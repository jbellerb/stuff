import Foundation

/// A single edit event: a filename and its associated diff.
public struct EditEvent {
    public let path: String
    public let diff: UnifiedDiff

    public init(path: String, diff: UnifiedDiff) {
        self.path = path
        self.diff = diff
    }

    /// Parse the raw events string from the Zeta prompt into structured
    /// EditEvents.
    ///
    /// Expected format:
    /// ```
    /// User edited path/to/file.swift:
    /// ```diff
    /// <unified diff>
    /// ```
    /// ```
    public static func parseAll(_ input: String) throws -> [EditEvent] {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var events: [EditEvent] = []
        var remaining = input

        while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let headerRange = remaining.range(of: "User edited ") else { break }
            remaining = String(remaining[headerRange.upperBound...])

            guard let separatorRange = remaining.range(of: ":\n```diff\n") else {
                throw ZetaParseError.malformedEventHeader
            }
            let path = String(remaining[..<separatorRange.lowerBound])
            remaining = String(remaining[separatorRange.upperBound...])

            guard let closeRange = remaining.range(of: "\n```") else {
                throw ZetaParseError.unclosedDiffFence(path)
            }
            let diffText = String(remaining[..<closeRange.lowerBound])
            remaining = String(remaining[closeRange.upperBound...])

            let diff = try UnifiedDiff.parse(diffText)
            events.append(EditEvent(path: path, diff: diff))
        }

        return events
    }
}
