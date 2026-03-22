import CoreML
import Foundation
import Logging

/// Manages the cache directory for CoreML models.
public struct ModelCache: Sendable {
    public let directory: URL
    private let logger: Logger

    public static let environmentKey = "PREDICTIONS_CACHE_DIR"

    /// Default cache directory: ~/.cache/predictions-coreml/models/
    public static var defaultDirectory: URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("predictions-coreml", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Creates a model cache, using the specified directory or falling back to
    /// defaults.
    public init(directory: URL? = nil, logger: Logger) {
        if let directory = directory {
            self.directory = directory
        } else if let envPath = ProcessInfo.processInfo.environment[Self.environmentKey] {
            self.directory = URL(fileURLWithPath: envPath, isDirectory: true)
        } else {
            self.directory = Self.defaultDirectory
        }
        self.logger = logger
    }

    /// Returns the compiled model URL for a model, compiling from an mlpackage
    /// if necessary. The compiled result is saved next to the source package so
    /// subsequent calls skip recompilation.
    public func compiledModelURL(for modelName: String) async throws -> URL {
        let compiledURL = directory.appendingPathComponent(
            "\(modelName).mlmodelc",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: compiledURL.path) { return compiledURL }

        let packageURL = directory.appendingPathComponent(
            "\(modelName).mlpackage",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ModelCacheError.modelNotFound(modelName)
        }

        logger.info(
            "compiling model",
            metadata: ["model.name": "\(modelName)", "model_cache.path": "\(directory)"]
        )
        let tempURL = try await MLModel.compileModel(at: packageURL)
        _ = try FileManager.default.replaceItemAt(compiledURL, withItemAt: tempURL)
        return compiledURL
    }

    /// Returns the directory containing tokenizer files for a model.
    public func tokenizerDirectory(for modelName: String) -> URL {
        directory.appendingPathComponent(modelName, isDirectory: true)
    }
}

public enum ModelCacheError: Error { case modelNotFound(String) }
