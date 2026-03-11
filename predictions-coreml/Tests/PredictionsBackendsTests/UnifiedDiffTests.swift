import Foundation
import Testing

@testable import PredictionsBackends

@Suite
struct UnifiedDiffParserTests {
    @Test
    func parsesEmptyDiff() throws {
        let diff = try UnifiedDiff.parse("")
        #expect(diff.hunks.isEmpty)
    }

    @Test
    func parsesSingleHunk() throws {
        let input = """
            @@ -1,3 +1,4 @@
             context line
            -removed line
            +added line
             context line
            +new line
            """
        let diff = try UnifiedDiff.parse(input)
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.oldStart == 1)
        #expect(hunk.oldCount == 3)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 4)
        #expect(
            hunk.lines == [
                .context("context line"), .deletion("removed line"), .addition("added line"),
                .context("context line"), .addition("new line"),
            ]
        )
    }

    @Test
    func parsesFileHeaders() throws {
        let input = """
            --- a/file.py
            +++ b/file.py
            @@ -1,2 +1,2 @@
             unchanged
            -old
            +new
            """
        let diff = try UnifiedDiff.parse(input)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines == [.context("unchanged"), .deletion("old"), .addition("new")])
    }

    @Test
    func parsesMultipleHunks() throws {
        let input = """
            @@ -1,2 +1,2 @@
             line1
            -old1
            +new1
            @@ -10,2 +10,2 @@
             line10
            -old10
            +new10
            """
        let diff = try UnifiedDiff.parse(input)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks[0].oldStart == 1)
        #expect(diff.hunks[1].oldStart == 10)
    }

    @Test
    func parsesOmittedCounts() throws {
        // when count is omitted it defaults to 1
        let input = "@@ -5 +5 @@\n-old\n+new\n"
        let diff = try UnifiedDiff.parse(input)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].oldCount == 1)
        #expect(diff.hunks[0].newCount == 1)
    }

    @Test
    func parsesPureInsertion() throws {
        let input = "@@ -3,0 +4,2 @@\n+line a\n+line b\n"
        let diff = try UnifiedDiff.parse(input)
        let hunk = diff.hunks[0]
        #expect(hunk.oldCount == 0)
        #expect(hunk.newCount == 2)
        #expect(hunk.lines == [.addition("line a"), .addition("line b")])
    }

    @Test
    func parsesPureDeletion() throws {
        let input = "@@ -3,2 +3,0 @@\n-line a\n-line b\n"
        let diff = try UnifiedDiff.parse(input)
        let hunk = diff.hunks[0]
        #expect(hunk.oldCount == 2)
        #expect(hunk.newCount == 0)
        #expect(hunk.lines == [.deletion("line a"), .deletion("line b")])
    }

    @Test
    func parsesHunkWithTrailingContext() throws {
        let input = "@@ -1,3 +1,3 @@\n-old\n+new\n unchanged\n more context\n"
        let diff = try UnifiedDiff.parse(input)
        #expect(
            diff.hunks[0].lines == [
                .deletion("old"), .addition("new"), .context("unchanged"), .context("more context"),
            ]
        )
    }
}

@Suite
struct UnifiedDiffRendererTests {
    @Test
    func rendersEmptyDiff() {
        let diff = UnifiedDiff(hunks: [])
        #expect(diff.render() == "")
    }

    @Test
    func rendersSingleHunk() {
        let hunk = Hunk(
            oldStart: 1,
            oldCount: 3,
            newStart: 1,
            newCount: 4,
            lines: [
                .context("context line"), .deletion("removed line"), .addition("added line"),
                .context("context line"), .addition("new line"),
            ]
        )
        let diff = UnifiedDiff(hunks: [hunk])
        let expected = """
            @@ -1,3 +1,4 @@
             context line
            -removed line
            +added line
             context line
            +new line

            """
        #expect(diff.render() == expected)
    }

    @Test
    func omitsCountWhenOne() {
        let hunk = Hunk(
            oldStart: 5,
            oldCount: 1,
            newStart: 5,
            newCount: 1,
            lines: [.deletion("old"), .addition("new")]
        )
        #expect(UnifiedDiff(hunks: [hunk]).render().hasPrefix("@@ -5 +5 @@"))
    }

    @Test
    func includesCountWhenNotOne() {
        let hunk = Hunk(
            oldStart: 1,
            oldCount: 3,
            newStart: 1,
            newCount: 2,
            lines: [.context("a"), .deletion("b"), .deletion("c"), .addition("d")]
        )
        #expect(UnifiedDiff(hunks: [hunk]).render().hasPrefix("@@ -1,3 +1,2 @@"))
    }

    @Test
    func roundTripsWithParser() throws {
        let input = """
            @@ -1,4 +1,3 @@
             unchanged
            -old line
             another unchanged
            -also removed
            +replacement
            @@ -10,2 +9,4 @@
             keep this
            +inserted
             keep that
            +also inserted
            """
        let original = try UnifiedDiff.parse(input)
        let rendered = try UnifiedDiff.parse(input).render()
        let reparsed = try UnifiedDiff.parse(rendered)
        #expect(reparsed.hunks.count == original.hunks.count)
        for (a, b) in zip(original.hunks, reparsed.hunks) {
            #expect(a.oldStart == b.oldStart)
            #expect(a.oldCount == b.oldCount)
            #expect(a.newStart == b.newStart)
            #expect(a.newCount == b.newCount)
            #expect(a.lines == b.lines)
        }
    }
}

@Suite
struct UnifiedDiffApplicatorTests {
    @Test
    func appliesEmptyDiffUnchanged() throws {
        let source = "hello\nworld\n"
        let result = try UnifiedDiff(hunks: []).apply(to: source)
        #expect(result == source)
    }

    @Test
    func appliesSimpleSubstitution() throws {
        let source = "line 1\nline 2\nline 3\n"
        let diff = try UnifiedDiff.parse("@@ -2,1 +2,1 @@\n-line 2\n+replaced\n")
        #expect(try diff.apply(to: source) == "line 1\nreplaced\nline 3\n")
    }

    @Test
    func appliesPureInsertion() throws {
        let source = "a\nb\nc\n"
        let diff = try UnifiedDiff.parse("@@ -3,0 +3,2 @@\n+x\n+y\n")
        #expect(try diff.apply(to: source) == "a\nb\nx\ny\nc\n")
    }

    @Test
    func appliesPureDeletion() throws {
        let source = "a\nb\nc\nd\n"
        let diff = try UnifiedDiff.parse("@@ -2,2 +2,0 @@\n-b\n-c\n")
        #expect(try diff.apply(to: source) == "a\nd\n")
    }

    @Test
    func appliesNewFile() throws {
        let source = ""
        let diff = try UnifiedDiff.parse("@@ -0,0 +1,1 @@\n+hi\n")
        #expect(try diff.apply(to: source) == "hi\n")
    }

    @Test
    func appliesMultipleHunks() throws {
        let source = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
        let diff = try UnifiedDiff.parse("@@ -2,1 +2,1 @@\n-2\n+two\n@@ -9,1 +9,1 @@\n-9\n+nine\n")
        #expect(try diff.apply(to: source) == "1\ntwo\n3\n4\n5\n6\n7\n8\nnine\n10\n")
    }

    @Test
    func appliesInsertionAtStartOfFile() throws {
        let source = "existing\n"
        let diff = try UnifiedDiff.parse("@@ -1,0 +1,1 @@\n+new first\n")
        #expect(try diff.apply(to: source) == "new first\nexisting\n")
    }

    @Test
    func appliesInsertionAtEndOfFile() throws {
        let source = "existing\n"
        let diff = try UnifiedDiff.parse("@@ -2,0 +2,1 @@\n+appended\n")
        #expect(try diff.apply(to: source) == "existing\nappended\n")
    }

    @Test
    func preservesTrailingNewline() throws {
        let source = "a\nb\n"
        let diff = try UnifiedDiff.parse("@@ -1,1 +1,1 @@\n-a\n+A\n")
        #expect(try diff.apply(to: source) == "A\nb\n")
    }

    @Test
    func preservesAbsenceOfTrailingNewline() throws {
        let source = "a\nb"
        let diff = try UnifiedDiff.parse("@@ -1,1 +1,1 @@\n-a\n+A\n")
        #expect(try diff.apply(to: source) == "A\nb")
    }

    @Test
    func throwsOnContextMismatch() throws {
        let source = "a\nb\nc\n"
        let diff = try UnifiedDiff.parse("@@ -1,1 +1,1 @@\n-wrong\n+x\n")
        #expect(throws: UnifiedDiffError.self) { try diff.apply(to: source) }
    }

    @Test
    func throwsOnDeletedLineMismatch() throws {
        let source = "a\nb\nc\n"
        let diff = try UnifiedDiff.parse("@@ -2,1 +2,0 @@\n-wrong\n")
        #expect(throws: UnifiedDiffError.self) { try diff.apply(to: source) }
    }

    @Test
    func throwsWhenHunkBeyondEnd() throws {
        let source = "a\n"
        let diff = try UnifiedDiff.parse("@@ -99,1 +99,1 @@\n-a\n+b\n")
        #expect(throws: UnifiedDiffError.self) { try diff.apply(to: source) }
    }
}
