import Foundation

/// Manages the cache directory for CoreML models.
public struct ModelCache: Sendable {
    public let directory: URL

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
    public init(directory: URL? = nil) {
        if let directory = directory {
            self.directory = directory
        } else if let envPath = ProcessInfo.processInfo.environment[Self.environmentKey] {
            self.directory = URL(fileURLWithPath: envPath, isDirectory: true)
        } else {
            self.directory = Self.defaultDirectory
        }
    }

    /// Returns the path for a model package with the given name.
    public func modelPath(for modelName: String) -> URL {
        directory.appendingPathComponent("\(modelName).mlmodelc", isDirectory: true)
    }

    /// Returns the directory containing tokenizer files for a model.
    public func tokenizerDirectory(for modelName: String) -> URL {
        directory.appendingPathComponent(modelName, isDirectory: true)
    }

    /// Checks if a model exists in the cache.
    public func modelExists(_ modelName: String) -> Bool {
        let path = modelPath(for: modelName)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
