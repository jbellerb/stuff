import Foundation
import Testing

@testable import PredictionsBackends

@Suite
struct EditEventParserTests {
    @Test
    func parsesEmptyEvents() throws {
        #expect(try EditEvent.parseAll("").isEmpty)
        #expect(try EditEvent.parseAll("   \n  ").isEmpty)
    }

    @Test
    func parsesSingleEvent() throws {
        let input = """
            User edited Sources/test.swift:
            ```diff
            -old line
            +new line
            ```
            """
        let events = try EditEvent.parseAll(input)
        #expect(events.count == 1)
        #expect(events[0].path == "Sources/test.swift")
        #expect(events[0].diff.hunks.count == 1)
        #expect(events[0].diff.hunks[0].lines == [.deletion("old line"), .addition("new line")])
    }

    @Test
    func parsesMultipleEvents() throws {
        let input = """
            User edited file1.swift:
            ```diff
            @@ -1 +1 @@
            -old1
            +new1
            ```

            User renamed file2.txt to bar.txt


            User edited file2.py:
            ```diff
            @@ -5 +5 @@
            -old2
            +new2
            ```
            """
        let events = try EditEvent.parseAll(input)
        #expect(events.count == 2)
        #expect(events[0].path == "file1.swift")
        #expect(events[1].path == "file2.py")
    }

    @Test
    func throwsOnMalformedHeader() {
        let input = "User edited :\n```diff\n-a\n+b\n```"
        // path is empty but otherwise valid
        #expect(throws: Never.self) { try EditEvent.parseAll(input) }
    }

    @Test
    func throwsOnUnclosedFence() {
        let input = "User edited test.swift:\n```diff\n-old\n+new\n"
        #expect(throws: ZetaParseError.self) { try EditEvent.parseAll(input) }
    }
}

@Suite
struct ExcerptParserTests {
    @Test
    func parsesBasicExcerpt() throws {
        let input = """
            ```Sources/test.swift
            <|editable_region_start|>
            fn foo() {}
            <|editable_region_end|>
            ```
            """
        let excerpt = try Excerpt.parse(input)
        #expect(excerpt.path == "Sources/test.swift")
        #expect(excerpt.beforeContext == "")
        #expect(excerpt.editableRegion == "fn foo() {}\n")
        #expect(excerpt.afterContext == "")
        #expect(excerpt.cursorOffset == nil)
    }

    @Test
    func parsesExcerptWithBeforeAndAfterContext() throws {
        let input = """
            ```Sources/test.swift
            <|start_of_file|>
            func before() {}
            <|editable_region_start|>
            func foo() {
                let x = 1

            <|editable_region_end|>}
            func after() {}
            ```
            """
        let excerpt = try Excerpt.parse(input)
        #expect(excerpt.path == "Sources/test.swift")
        #expect(excerpt.beforeContext == "func before() {}\n")
        #expect(excerpt.editableRegion == "func foo() {\n    let x = 1\n\n")
        #expect(excerpt.afterContext == "}\nfunc after() {}")
        #expect(excerpt.cursorOffset == nil)
    }

    @Test
    func parsesStartOfFileMarker() throws {
        let withMarker =
            "```test.swift\n<|start_of_file|>\n<|editable_region_start|>\ncode\n<|editable_region_end|>\n```"
        let withoutMarker =
            "```test.swift\n<|editable_region_start|>\ncode\n<|editable_region_end|>\n```"
        let a = try Excerpt.parse(withMarker)
        let b = try Excerpt.parse(withoutMarker)
        #expect(a.beforeContext == b.beforeContext)
        #expect(a.editableRegion == b.editableRegion)
    }

    @Test
    func parsesCursorMarker() throws {
        let input = """
            ```test.swift
            <|editable_region_start|>
            hello <|user_cursor_is_here|>world
            <|editable_region_end|>
            ```
            """
        let excerpt = try Excerpt.parse(input)
        #expect(excerpt.editableRegion == "hello world\n")
        // "hello " is 6 UTF-8 bytes
        #expect(excerpt.cursorOffset == 6)
    }

    @Test
    func parsesCursorOffsetWithMultibyteContent() throws {
        let input = """
            ```test.swift
            <|editable_region_start|>
            café <|user_cursor_is_here|>world
            <|editable_region_end|>
            ```
            """
        let excerpt = try Excerpt.parse(input)
        #expect(excerpt.editableRegion == "café world\n")
        // "café " is 6 bytes in UTF-8
        #expect(excerpt.cursorOffset == 6)
    }

    @Test
    func parsesEndMarkerInlineWithContent() throws {
        let input =
            "```test.swift\n<|editable_region_start|>\nfoo\n<|editable_region_end|>bar\nbaz\n```"
        let excerpt = try Excerpt.parse(input)
        #expect(excerpt.editableRegion == "foo\n")
        #expect(excerpt.afterContext == "bar\nbaz")
    }

    @Test
    func throwsOnMissingOpeningFence() {
        #expect(throws: ZetaParseError.missingOpeningFence) { try Excerpt.parse("no fence here") }
    }

    @Test
    func throwsOnMissingEditableRegionStart() {
        #expect(throws: ZetaParseError.missingEditableRegionStart) {
            try Excerpt.parse("```test.swift\nno markers\n```")
        }
    }

    @Test
    func throwsOnMissingEditableRegionEnd() {
        #expect(throws: ZetaParseError.missingEditableRegionEnd) {
            try Excerpt.parse("```test.swift\n<|editable_region_start|>\nno end\n```")
        }
    }
}
