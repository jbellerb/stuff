import Foundation
import PredictionsBackends
import PredictionsInference
import Testing

@testable import SweepPredictionsBackend

@Suite
struct SweepPromptBuilderTests {
    @Test
    func buildsPromptWithNoEvents() throws {
        let excerpt = try Excerpt.parse(
            "```Sources/test.swift\n<|editable_region_start|>\nfunc foo() {}\n<|editable_region_end|>\n```"
        )
        let prompt = buildSweepPrompt(events: [], excerpt: excerpt).prompt
        #expect(prompt.contains("<|file_sep|>original/Sources/test.swift"))
        #expect(prompt.contains("<|file_sep|>current/Sources/test.swift"))
        #expect(prompt.contains("<|file_sep|>updated/Sources/test.swift"))
        #expect(!prompt.contains(".diff"))
    }

    @Test
    func buildsPromptWithEvent() throws {
        let events = try EditEvent.parseAll(
            "User edited Sources/lib.swift:\n```diff\n@@ -1 +1 @@\n-func old() {}\n+func new() {}\n```"
        )
        let excerpt = try Excerpt.parse(
            "```Sources/test.swift\n<|editable_region_start|>\nfunc foo() {}\n<|editable_region_end|>\n```"
        )
        let prompt = buildSweepPrompt(events: events, excerpt: excerpt).prompt
        #expect(prompt.contains("<|file_sep|>Sources/lib.swift.diff"))
        #expect(prompt.contains("original:"))
        #expect(prompt.contains("updated:"))
        #expect(prompt.contains("func old() {}"))
        #expect(prompt.contains("func new() {}"))
    }

    @Test
    func promptEndsWithUpdatedMarker() throws {
        let excerpt = try Excerpt.parse(
            "```Sources/test.swift\n<|editable_region_start|>\ncode\n<|editable_region_end|>\n```"
        )
        let prompt = buildSweepPrompt(events: [], excerpt: excerpt).prompt
        #expect(prompt.hasSuffix("<|file_sep|>updated/Sources/test.swift\n"))
    }

    @Test
    func currentContentIsEditableWindow() throws {
        let excerpt = try Excerpt.parse(
            "```Sources/test.swift\nbefore line\n<|editable_region_start|>\neditable\n<|editable_region_end|>\nafter line\n```"
        )
        let prompt = buildSweepPrompt(events: [], excerpt: excerpt).prompt
        // current section should contain only the editable window, not surrounding context
        let currentMarker = "<|file_sep|>current/Sources/test.swift\n"
        guard let currentStart = prompt.range(of: currentMarker) else {
            Issue.record("missing current marker")
            return
        }
        let afterCurrent = String(prompt[currentStart.upperBound...])
        #expect(afterCurrent.hasPrefix("editable\n"))
        #expect(!afterCurrent.contains("before line"))
        #expect(!afterCurrent.contains("after line"))
    }

    @Test
    func trimsEditableRegionToWindowAroundCursor() throws {
        // 25 editable lines, cursor at the start — window covers the first 11
        let manyLines = (1...25).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let excerpt = Excerpt(
            path: "test.swift",
            beforeContext: "",
            editableRegion: manyLines,
            afterContext: "",
            cursorOffset: nil
        )
        let (prompt, _, editableSuffix) = buildSweepPrompt(events: [], excerpt: excerpt)
        let currentMarker = "<|file_sep|>current/test.swift\n"
        guard let range = prompt.range(of: currentMarker) else {
            Issue.record("missing current marker")
            return
        }
        let current = String(prompt[range.upperBound...])
        // window starts at line 1 and covers 11 lines (cursor ± maxContextLines)
        #expect(current.hasPrefix("line 1\n"))
        #expect(!current.contains("line 12\n"))
        // lines beyond the window are in the suffix, not the prompt
        #expect(editableSuffix.contains("line 12"))
    }

    @Test
    func originalEqualsCurrentWhenNoMatchingEvent() throws {
        let events = try EditEvent.parseAll(
            "User edited other.swift:\n```diff\n@@ -1 +1 @@\n-old\n+new\n```"
        )
        let excerpt = try Excerpt.parse(
            "```Sources/test.swift\n<|editable_region_start|>\ncontent\n<|editable_region_end|>\n```"
        )
        let prompt = buildSweepPrompt(events: events, excerpt: excerpt).prompt
        let origMarker = "<|file_sep|>original/Sources/test.swift\n"
        let currMarker = "<|file_sep|>current/Sources/test.swift\n"
        guard let origRange = prompt.range(of: origMarker),
            let currRange = prompt.range(of: currMarker)
        else {
            Issue.record("missing markers")
            return
        }
        let origContent = String(prompt[origRange.upperBound..<currRange.lowerBound])
        let afterCurr = String(
            prompt[currRange.upperBound..<prompt.range(of: "<|file_sep|>updated/")!.lowerBound]
        )
        #expect(origContent == afterCurr)
    }
}

@Suite
struct DiffTextExtractionTests {
    @Test
    func extractsOriginalText() throws {
        let diff = try UnifiedDiff.parse("@@ -1,3 +1,3 @@\n context\n-removed\n+added\n context2\n")
        let original = extractText(from: diff, side: .original)
        #expect(original == "context\nremoved\ncontext2")
    }

    @Test
    func extractsUpdatedText() throws {
        let diff = try UnifiedDiff.parse("@@ -1,3 +1,3 @@\n context\n-removed\n+added\n context2\n")
        let updated = extractText(from: diff, side: .updated)
        #expect(updated == "context\nadded\ncontext2")
    }
}

@Suite
struct SweepEndToEndTests {
    /// Full pipeline: parse zeta1 input, build sweep prompt, simulate model output,
    /// stitch editable prefix/suffix back.
    @Test
    func endToEndWithSimulatedOutput() throws {
        let events = """
            User edited Sources/lib.swift:
            ```diff
            @@ -3,1 +3,1 @@
             // lib
            -func compute() -> Int { return 7 }
            +func compute_value() -> Int { return 7 }
            ```
            """

        let excerpt = """
            ```Sources/test.swift
            // comment
            <|editable_region_start|>
            func main() {
                let x = <|user_cursor_is_here|>compute()
            }
            <|editable_region_end|>
            ```
            """

        let editEvents = try EditEvent.parseAll(events)
        let parsedExcerpt = try Excerpt.parse(excerpt)

        let (prompt, editablePrefix, editableSuffix) = buildSweepPrompt(
            events: editEvents,
            excerpt: parsedExcerpt
        )

        #expect(prompt.contains("<|file_sep|>Sources/lib.swift.diff"))
        #expect(prompt.contains("<|file_sep|>current/Sources/test.swift"))
        #expect(prompt.contains("<|file_sep|>updated/Sources/test.swift"))
        #expect(prompt.hasSuffix("<|file_sep|>updated/Sources/test.swift\n"))

        // simulate model output: just the rewritten editable window
        let simulatedOutput = "func main() {\n    let x = compute_value()\n}\n"
        let result = String(editablePrefix) + simulatedOutput + String(editableSuffix)
        #expect(result == simulatedOutput)
    }

    @Test
    func endToEndNoChange() throws {
        let excerpt = """
            ```Sources/test.swift
            func before() {}
            <|editable_region_start|>
            func unchanged() {}
            <|editable_region_end|>
            func after() {}
            ```
            """

        let parsedExcerpt = try Excerpt.parse(excerpt)
        let (_, editablePrefix, editableSuffix) = buildSweepPrompt(
            events: [],
            excerpt: parsedExcerpt
        )

        // simulate model returning the window unchanged
        let simulatedOutput = String(parsedExcerpt.editableContent)
        let result = String(editablePrefix) + simulatedOutput + String(editableSuffix)
        #expect(result == String(parsedExcerpt.editableContent))
    }
}
