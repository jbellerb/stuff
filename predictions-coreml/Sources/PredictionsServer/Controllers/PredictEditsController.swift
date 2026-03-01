import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import PredictionsBackends

/// OpenAI-compatible completions request.
struct CompletionRequest: Codable, Sendable {
    let model: String
    let prompt: String
    let maxTokens: Int?
    let stop: [String]?

    enum CodingKeys: String, CodingKey {
        case model, prompt, stop
        case maxTokens = "max_tokens"
    }

    var inputEvents: String? {
        guard let start = prompt.range(of: "### User Edits:\n\n"),
            let end = prompt.range(
                of: "\n\n### User Excerpt:",
                range: start.upperBound..<prompt.endIndex
            )
        else { return nil }
        return String(prompt[start.upperBound..<end.lowerBound])
    }

    var inputExcerpt: String? {
        guard let start = prompt.range(of: "### User Excerpt:\n\n"),
            let end = prompt.range(
                of: "\n\n### Response:",
                range: start.upperBound..<prompt.endIndex
            )
        else { return nil }
        return String(prompt[start.upperBound..<end.lowerBound])
    }
}

struct CompletionChoice: Codable, Sendable {
    let text: String
    let index: Int
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case text, index
        case finishReason = "finish_reason"
    }
}

/// OpenAI-compatible completions response.
struct CompletionResponse: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [CompletionChoice]

    init(model: String, text: String) {
        self.id = "cmpl-\(UUID().uuidString)"
        self.object = "text_completion"
        self.created = Int(Date().timeIntervalSince1970)
        self.model = model
        self.choices = [CompletionChoice(text: text, index: 0, finishReason: "stop")]
    }
}

/// Controller for the OpenAI-compatible completions endpoint.
///
/// Parses the Zeta-structured prompt, extracts the user edits and excerpt
/// sections, calls the prediction backend, and returns the result in OpenAI
/// completions response format.
struct PredictEditsController: Sendable {
    let logger: Logger?
    let backend: any PredictionsBackend

    func post(request: HTTPRequestHead, body: ByteBuffer?) async throws -> Router.Response {
        guard var bodyBuffer = body else {
            logger?.warning("missing request body", metadata: ["http.path": "\(request.uri)"])
            return .json(status: .badRequest, body: #"{"error":"Missing request body"}"#)
        }

        let completionRequest: CompletionRequest
        do {
            guard let data = bodyBuffer.readData(length: bodyBuffer.readableBytes) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Unable to read request body"
                    )
                )
            }
            completionRequest = try JSONDecoder().decode(CompletionRequest.self, from: data)
        } catch {
            logger?
                .warning(
                    "failed to parse request",
                    metadata: [
                        "http.path": "\(request.uri)", "exception": "\(error)",
                        "exception.type": "\(type(of: error))",
                    ]
                )
            return .json(status: .badRequest, body: #"{"error":"Invalid request format"}"#)
        }

        guard let events = completionRequest.inputEvents,
            let excerpt = completionRequest.inputExcerpt
        else {
            logger?
                .warning(
                    "failed to parse prompt sections",
                    metadata: ["http.path": "\(request.uri)"]
                )
            return .json(status: .badRequest, body: #"{"error":"Invalid prompt format"}"#)
        }

        let prediction: String?
        do { prediction = try await backend.predict(events: events, excerpt: excerpt) } catch {
            logger?
                .error(
                    "prediction backend error",
                    metadata: [
                        "http.path": "\(request.uri)", "exception": "\(error)",
                        "exception.type": "\(type(of: error))",
                    ]
                )
            return .json(
                status: .internalServerError,
                body: #"{"error":"Prediction service error"}"#
            )
        }

        // the stop token is "<|editable_region_end|>", so the model is expected
        // to generate from "<|editable_region_start|>" up to (but not
        // including) the end marker
        let responseText: String
        if let prediction = prediction {
            responseText = "<|editable_region_start|>\n\(prediction)\n"
        } else if let regionStart = excerpt.range(of: "<|editable_region_start|>"),
            let regionEnd = excerpt.range(
                of: "<|editable_region_end|>",
                range: regionStart.upperBound..<excerpt.endIndex
            )
        {
            responseText = String(excerpt[regionStart.lowerBound..<regionEnd.lowerBound])
        } else {
            responseText = ""
        }

        let completionResponse = CompletionResponse(
            model: completionRequest.model,
            text: responseText
        )

        do {
            let responseData = try JSONEncoder().encode(completionResponse)
            guard let responseBody = String(data: responseData, encoding: .utf8) else {
                throw EncodingError.invalidValue(
                    completionResponse,
                    EncodingError.Context(
                        codingPath: [],
                        debugDescription: "Unable to encode response as UTF-8"
                    )
                )
            }
            return .json(status: .ok, body: responseBody)
        } catch {
            logger?
                .error(
                    "failed to encode response",
                    metadata: [
                        "http.path": "\(request.uri)", "exception": "\(error)",
                        "exception.type": "\(type(of: error))",
                    ]
                )
            return .json(
                status: .internalServerError,
                body: #"{"error":"Failed to encode response"}"#
            )
        }
    }
}
