import Foundation
import Testing

@testable import PredictionsServer

@Suite
struct PredictEditsModelsTests {
    @Test
    func requestDecodesWithoutOptionalFields() throws {
        let json = """
            {
                "model": "test",
                "prompt": "some prompt"
            }
            """

        let request = try JSONDecoder().decode(CompletionRequest.self, from: Data(json.utf8))

        #expect(request.model == "test")
        #expect(request.maxTokens == nil)
        #expect(request.stop == nil)
    }

    @Test
    func requestRequiresBothModelAndPrompt() {
        let missingPrompt = """
            {
                "model": "test"
            }
            """

        let missingModel = """
            {
                "prompt": "some prompt"
            }
            """

        let decoder = JSONDecoder()

        #expect(throws: Error.self) {
            try decoder.decode(CompletionRequest.self, from: Data(missingPrompt.utf8))
        }

        #expect(throws: Error.self) {
            try decoder.decode(CompletionRequest.self, from: Data(missingModel.utf8))
        }
    }

    @Test
    func extractsEventsFromPrompt() {
        let events = "User edited \"test.swift\":\n```diff\n+ new line\n```"
        let excerpt = "```test.swift\nfunc example() {}\n```"
        let request = CompletionRequest(
            model: "test",
            prompt: makePrompt(events: events, excerpt: excerpt),
            maxTokens: nil,
            stop: nil
        )

        #expect(request.inputEvents == events)
    }

    @Test
    func extractsExcerptFromPrompt() {
        let events = "User edited \"test.swift\""
        let excerpt =
            "```test.swift\nfunc example() {}\n<|editable_region_start|>\nlet x = 1\n<|editable_region_end|>\n```"
        let request = CompletionRequest(
            model: "test",
            prompt: makePrompt(events: events, excerpt: excerpt),
            maxTokens: nil,
            stop: nil
        )

        #expect(request.inputExcerpt == excerpt)
    }

    @Test
    func returnsNilForMalformedPrompt() {
        let request = CompletionRequest(
            model: "test",
            prompt: "no sections here",
            maxTokens: nil,
            stop: nil
        )

        #expect(request.inputEvents == nil)
        #expect(request.inputExcerpt == nil)
    }

    @Test
    func handlesEmptyEventsSection() {
        let request = CompletionRequest(
            model: "test",
            prompt: makePrompt(events: "", excerpt: "```test.swift\nfunc example() {}\n```"),
            maxTokens: nil,
            stop: nil
        )

        #expect(request.inputEvents == "")
    }

    @Test
    func responseHasCorrectStructure() {
        let response = CompletionResponse(model: "test", text: "predicted code")

        #expect(response.object == "text_completion")
        #expect(response.model == "test")
        #expect(response.choices.count == 1)
        #expect(response.choices[0].text == "predicted code")
        #expect(response.choices[0].index == 0)
        #expect(response.choices[0].finishReason == "stop")
        #expect(!response.id.isEmpty)
        #expect(response.id.hasPrefix("cmpl-"))
        #expect(response.created > 0)
    }

    @Test
    func responseRoundTrip() throws {
        let original = CompletionResponse(
            model: "test",
            text: "<|editable_region_start|>\nlet x = 42\n"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.object == original.object)
        #expect(decoded.model == original.model)
        #expect(decoded.choices[0].text == original.choices[0].text)
    }
}
