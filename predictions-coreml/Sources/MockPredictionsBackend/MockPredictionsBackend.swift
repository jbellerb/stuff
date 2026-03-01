import Foundation
import PredictionsBackends

/// Mock implementation of CoreMLBackend for testing.
public struct MockPredictionsBackend: PredictionsBackend {
    public let name: String

    public enum Behavior: Sendable {
        case success(output: String)
        case noChange
        case error(Error)
    }

    private let behavior: Behavior

    public init(name: String = "mock", behavior: Behavior = .noChange) {
        self.name = name
        self.behavior = behavior
    }

    public func predict(events: String, excerpt: String) async throws -> String? {
        switch behavior {
        case .success(let output): return output
        case .noChange: return nil
        case .error(let error): throw error
        }
    }
}

public struct MockBackendError: Error, Sendable {
    public let message: String

    public init(message: String) { self.message = message }
}
