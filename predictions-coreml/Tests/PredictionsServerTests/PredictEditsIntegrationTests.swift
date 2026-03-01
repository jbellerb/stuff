import Foundation
import Logging
import MockPredictionsBackend
import NIOCore
import NIOPosix
import PredictionsBackends
import Testing

@testable import PredictionsServer

@Suite
struct PredictEditsIntegrationTests {
    @Test
    func endToEndSuccessfulPrediction() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .success(output: "let x = 7"))

        try await withServer(backend: mockBackend) { port in
            let response = try await makeRequest(
                port: port,
                path: "/v1/edits",
                method: "POST",
                body: makeRequestJSON(
                    events: "User edited \"test.swift\"",
                    excerpt: makeExcerpt("let x = 1")
                )
            )

            #expect(response.statusCode == 200)
            #expect(response.headers["Content-Type"]?.contains("application/json") == true)

            let decoded = try JSONDecoder()
                .decode(CompletionResponse.self, from: Data(response.body.utf8))

            #expect(decoded.choices[0].text.contains("<|editable_region_start|>"))
            #expect(decoded.choices[0].text.contains("let x = 7"))
            #expect(!decoded.choices[0].text.contains("<|editable_region_end|>"))
            #expect(!decoded.id.isEmpty)
        }
    }

    @Test
    func endToEndNoChangePrediction() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)

        try await withServer(backend: mockBackend) { port in
            let response = try await makeRequest(
                port: port,
                path: "/v1/edits",
                method: "POST",
                body: makeRequestJSON(
                    events: "User edited \"test.swift\"",
                    excerpt: makeExcerpt("let x = 1")
                )
            )

            #expect(response.statusCode == 200)
            #expect(response.headers["Content-Type"]?.contains("application/json") == true)

            let decoded = try JSONDecoder()
                .decode(CompletionResponse.self, from: Data(response.body.utf8))

            #expect(!decoded.id.isEmpty)
            #expect(decoded.choices[0].text.contains("<|editable_region_start|>"))
        }
    }

    @Test
    func endToEndMalformedJSON() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)

        try await withServer(backend: mockBackend) { port in
            let response = try await makeRequest(
                port: port,
                path: "/v1/edits",
                method: "POST",
                body: "{ this is not valid json }"
            )

            #expect(response.statusCode == 400)
            #expect(response.headers["Content-Type"]?.contains("application/json") == true)
            #expect(response.body.contains("error"))
            #expect(response.body.contains("Invalid request format"))
        }
    }

    @Test
    func endToEndMissingRequiredFields() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)

        try await withServer(backend: mockBackend) { port in
            let response = try await makeRequest(
                port: port,
                path: "/v1/edits",
                method: "POST",
                body: #"{"model": "test"}"#
            )

            #expect(response.statusCode == 400)
            #expect(response.headers["Content-Type"]?.contains("application/json") == true)
            #expect(response.body.contains("error"))
        }
    }

    @Test
    func endToEndMalformedPrompt() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)

        try await withServer(backend: mockBackend) { port in
            let response = try await makeRequest(
                port: port,
                path: "/v1/edits",
                method: "POST",
                body: #"{"model": "test", "prompt": "no sections here"}"#
            )

            #expect(response.statusCode == 400)
            #expect(response.headers["Content-Type"]?.contains("application/json") == true)
            #expect(response.body.contains("error"))
            #expect(response.body.contains("Invalid prompt format"))
        }
    }

    @Test
    func endToEndPredictionBackendError() async throws {
        let mockBackend = MockPredictionsBackend(
            behavior: .error(MockBackendError(message: "Service failed"))
        )

        try await withServer(backend: mockBackend) { port in
            let response = try await makeRequest(
                port: port,
                path: "/v1/edits",
                method: "POST",
                body: makeRequestJSON(
                    events: "User edited \"test.swift\"",
                    excerpt: makeExcerpt("let x = 1")
                )
            )

            #expect(response.statusCode == 500)
            #expect(response.headers["Content-Type"]?.contains("application/json") == true)
            #expect(response.body.contains("error"))
        }
    }

    @Test
    func endToEndMethodNotAllowed() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)

        try await withServer(backend: mockBackend) { port in
            let response = try await makeRequest(
                port: port,
                path: "/v1/edits",
                method: "GET",
                body: nil
            )

            #expect(response.statusCode == 405)
            #expect(response.headers["Allow"]?.contains("POST") == true)
        }
    }

    @Test
    func endToEndUnknownPath() async throws {
        let mockBackend = MockPredictionsBackend(behavior: .noChange)

        try await withServer(backend: mockBackend) { port in
            let response = try await makeRequest(
                port: port,
                path: "/unknown",
                method: "POST",
                body: "{}"
            )

            #expect(response.statusCode == 404)
        }
    }

    private func withServer(backend: any PredictionsBackend, operation: (Int) async throws -> Void)
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let router = buildRouter(logger: Logger(label: "test"), predictionsBackend: backend)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline()
                    .flatMap {
                        channel.pipeline.addHandler(
                            HTTPHandler(router: router, logger: Logger(label: "test"))
                        )
                    }
            }

        // Bind to port 0 so the OS assigns a free port, then read it back.
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let assignedPort = channel.localAddress!.port!

        do { try await operation(assignedPort) } catch {
            channel.close(promise: nil)
            throw error
        }

        channel.close(promise: nil)
        try await channel.closeFuture.get()
    }

    private func makeRequest(port: Int, path: String, method: String, body: String?) async throws
        -> HTTPResponse
    {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method

        if let body = body {
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }

        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private struct HTTPResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: String
    }
}
