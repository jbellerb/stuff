import Foundation

/// Protocol for CoreML prediction backends.
public protocol PredictionsBackend: Sendable {
    var name: String { get }

    /// Generates a prediction based on the provided events and code excerpt.
    func predict(events: String, excerpt: String) async throws -> String?
}
