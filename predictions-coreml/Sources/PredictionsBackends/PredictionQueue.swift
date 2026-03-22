/// Serializes prediction requests to a backend.
///
/// Generator holds mutable KV cache state and can only process one request at
/// a time. Wrapping the backend in this actor ensures concurrent HTTP requests
/// are queued rather than running in parallel.
public actor PredictionQueue: PredictionsBackend {
    public let name: String
    private let backend: any PredictionsBackend

    public init(_ backend: any PredictionsBackend) {
        self.name = backend.name
        self.backend = backend
    }

    public func predict(events: String, excerpt: String) async throws -> String? {
        try await backend.predict(events: events, excerpt: excerpt)
    }
}
