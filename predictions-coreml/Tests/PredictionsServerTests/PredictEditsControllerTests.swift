import Foundation
import Logging
import MockPredictionsBackend
import NIOCore
import NIOHTTP1
import PredictionsBackends
import Testing

@testable import PredictionsServer

@Suite
struct PredictEditsControllerTests {
    @Test
    func handlesValidRequestWithPrediction() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .success(output: "let x = 7"))
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        var buffer = ByteBuffer()
        buffer.writeString(
            makeRequestJSON(events: "User edited \"test.swift\"", excerpt: makeExcerpt("let x = 1"))
        )

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .ok)
        #expect(response.headers["Content-Type"].first == "application/json; charset=utf-8")

        let decoded = try JSONDecoder()
            .decode(CompletionResponse.self, from: Data(response.body.utf8))

        #expect(decoded.choices[0].text.contains("<|editable_region_start|>"))
        #expect(decoded.choices[0].text.contains("let x = 7"))
        #expect(!decoded.choices[0].text.contains("<|editable_region_end|>"))
        #expect(!decoded.id.isEmpty)
    }

    @Test
    func handlesValidRequestWithNoChange() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        let editableContent = "let x = 1"
        var buffer = ByteBuffer()
        buffer.writeString(
            makeRequestJSON(
                events: "User edited \"test.swift\"",
                excerpt: makeExcerpt(editableContent)
            )
        )

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .ok)

        let decoded = try JSONDecoder()
            .decode(CompletionResponse.self, from: Data(response.body.utf8))

        // echoes back the original editable region (without the end marker).
        #expect(decoded.choices[0].text.contains("<|editable_region_start|>"))
        #expect(decoded.choices[0].text.contains(editableContent))
        #expect(!decoded.choices[0].text.contains("<|editable_region_end|>"))
        #expect(!decoded.id.isEmpty)
    }

    @Test
    func returnsBadRequestWhenBodyIsMissing() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: nil)

        #expect(response.status == .badRequest)
        #expect(response.headers["Content-Type"].first == "application/json; charset=utf-8")
        #expect(response.body.contains("error"))
        #expect(response.body.contains("Missing request body"))
    }

    @Test
    func returnsBadRequestWhenJSONIsInvalid() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        var buffer = ByteBuffer()
        buffer.writeString("{ this is not valid json }")

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .badRequest)
        #expect(response.headers["Content-Type"].first == "application/json; charset=utf-8")
        #expect(response.body.contains("error"))
        #expect(response.body.contains("Invalid request format"))
    }

    @Test
    func returnsBadRequestWhenRequiredFieldsAreMissing() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        // missing "prompt" field
        var buffer = ByteBuffer()
        buffer.writeString(#"{"model": "test-model"}"#)

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .badRequest)
        #expect(response.headers["Content-Type"].first == "application/json; charset=utf-8")
        #expect(response.body.contains("error"))
        #expect(response.body.contains("Invalid request format"))
    }

    @Test
    func returnsBadRequestWhenPromptIsMalformed() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        var buffer = ByteBuffer()
        buffer.writeString(#"{"model": "test-model", "prompt": "no sections here"}"#)

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .badRequest)
        #expect(response.headers["Content-Type"].first == "application/json; charset=utf-8")
        #expect(response.body.contains("error"))
        #expect(response.body.contains("Invalid prompt format"))
    }

    @Test
    func returnsInternalServerErrorWhenBackendThrows() async throws {
        let mockBackend = MockPredictionsBackend(
            behavior: .error(MockBackendError(message: "Service unavailable"))
        )
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        var buffer = ByteBuffer()
        buffer.writeString(
            makeRequestJSON(events: "User edited \"test.swift\"", excerpt: makeExcerpt("let x = 1"))
        )

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .internalServerError)
        #expect(response.headers["Content-Type"].first == "application/json; charset=utf-8")
        #expect(response.body.contains("error"))
        #expect(response.body.contains("Prediction service error"))
    }

    @Test
    func handlesEmptyEventsSection() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        var buffer = ByteBuffer()
        buffer.writeString(makeRequestJSON(events: "", excerpt: makeExcerpt("let x = 1")))

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .ok)
    }

    @Test
    func handlesLargeRequestBody() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        let largeContent = String(repeating: "let x = 7\n", count: 500)
        var buffer = ByteBuffer()
        buffer.writeString(
            makeRequestJSON(
                events: "User edited \"large.swift\"",
                excerpt: makeExcerpt(largeContent)
            )
        )

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .ok)

        let decoded = try JSONDecoder()
            .decode(CompletionResponse.self, from: Data(response.body.utf8))
        #expect(!decoded.id.isEmpty)
    }

    @Test
    func handlesSpecialCharactersInRequest() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)
        let controller = PredictEditsController(logger: Logger(label: "test"), backend: mockBackend)

        let events = "User edited \"test.swift\":\n```diff\n+ line with \"quotes\" and \ttabs\n```"
        let excerpt = makeExcerpt("let emoji = \"🎉\"")
        var buffer = ByteBuffer()
        buffer.writeString(makeRequestJSON(events: events, excerpt: excerpt))

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let response = try await controller.post(request: request, body: buffer)

        #expect(response.status == .ok)

        let decoded = try JSONDecoder()
            .decode(CompletionResponse.self, from: Data(response.body.utf8))
        #expect(decoded.choices[0].text.contains("🎉"))
    }
}
