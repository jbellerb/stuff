import Foundation

/// The excerpt surrounding the user's cursor.
public struct Excerpt {
    public let path: String
    public let beforeContext: String
    public let editableRegion: String
    public let afterContext: String
    /// Byte offset of <|user_cursor_is_here|> within editableRegion.
    public let cursorOffset: Int?

    public init(
        path: String,
        beforeContext: String,
        editableRegion: String,
        afterContext: String,
        cursorOffset: Int?
    ) {
        self.path = path
        self.beforeContext = beforeContext
        self.editableRegion = editableRegion
        self.afterContext = afterContext
        self.cursorOffset = cursorOffset
    }

    /// Parse the raw excerpt string from the Zeta prompt into a structured
    /// Excerpt.
    ///
    /// Expected format:
    /// ```
    /// ```path/to/file.swift
    /// <|start_of_file|>        (optional)
    /// <before context lines>
    /// <|editable_region_start|>
    /// <editable content>
    /// <|editable_region_end|><possibly more text on same line>
    /// <after context lines>
    /// ```
    /// ```
    public static func parse(_ input: String) throws -> Excerpt {
        var rest = input

        // strip opening code fence and extract path
        guard rest.hasPrefix("```") else { throw ZetaParseError.missingOpeningFence }
        rest = String(rest.dropFirst(3))
        guard let firstNewline = rest.firstIndex(of: "\n") else {
            throw ZetaParseError.missingOpeningFence
        }
        let path = String(rest[..<firstNewline])
        rest = String(rest[rest.index(after: firstNewline)...])

        // strip closing code fence
        if rest.hasSuffix("\n```") {
            rest = String(rest.dropLast(4))
        }

        // strip optional <|start_of_file|> marker
        let startOfFileMarker = "<|start_of_file|>\n"
        if rest.hasPrefix(startOfFileMarker) {
            rest = String(rest.dropFirst(startOfFileMarker.count))
        }

        // split on <|editable_region_start|>
        let startMarker = "<|editable_region_start|>"
        guard let startRange = rest.range(of: startMarker) else {
            throw ZetaParseError.missingEditableRegionStart
        }
        let beforeContext = String(rest[..<startRange.lowerBound])
        rest = String(rest[startRange.upperBound...])
        if rest.hasPrefix("\n") { rest = String(rest.dropFirst()) }

        // split on <|editable_region_end|>
        let endMarker = "<|editable_region_end|>"
        guard let endRange = rest.range(of: endMarker) else {
            throw ZetaParseError.missingEditableRegionEnd
        }
        let rawEditable = String(rest[..<endRange.lowerBound])
        let afterContext = String(rest[endRange.upperBound...])

        // strip <|user_cursor_is_here|> from editable content
        let cursorMarker = "<|user_cursor_is_here|>"
        let editableRegion: String
        let cursorOffset: Int?
        if let cursorRange = rawEditable.range(of: cursorMarker) {
            let utf8View = rawEditable.utf8
            let offsetIndex = cursorRange.lowerBound.samePosition(in: utf8View)!
            cursorOffset = utf8View.distance(from: utf8View.startIndex, to: offsetIndex)
            editableRegion =
                String(rawEditable[..<cursorRange.lowerBound])
                + String(rawEditable[cursorRange.upperBound...])
        } else {
            cursorOffset = nil
            editableRegion = rawEditable
        }

        return Excerpt(
            path: path,
            beforeContext: beforeContext,
            editableRegion: editableRegion,
            afterContext: afterContext,
            cursorOffset: cursorOffset
        )
    }
}

public enum ZetaParseError: Error, Equatable {
    case malformedEventHeader
    case unclosedDiffFence(String)
    case missingOpeningFence
    case missingEditableRegionStart
    case missingEditableRegionEnd
}
