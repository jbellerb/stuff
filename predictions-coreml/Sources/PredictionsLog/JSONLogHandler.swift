import Foundation
import Logging

/// Basic log handler outputting JSON to stderr.
public struct JSONLogHandler: LogHandler {
    public var logLevel: Logger.Level = .info
    public var metadata: Logger.Metadata = [:]

    private let label: String

    public init(label: String) { self.label = label }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { return metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        var jsonObject: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue.uppercased(), "svc.name": label, "message": message.description,
        ]

        var mergedMetadata = self.metadata
        if let metadata = metadata { mergedMetadata.merge(metadata) { _, new in new } }
        if !mergedMetadata.isEmpty { appendMetadataToJSON(&jsonObject, metadata: mergedMetadata) }

        if let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: []),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            fputs(jsonString + "\n", stderr)
            fflush(stderr)
        }
    }

    private func appendMetadataToJSON(_ jsonObject: inout [String: Any], metadata: Logger.Metadata)
    { for (key, value) in metadata { jsonObject[key] = convertMetadataValueToJSON(value) } }

    private func convertMetadataValueToJSON(_ value: Logger.Metadata.Value) -> Any {
        switch value {
        case .string(let str): return str
        case .stringConvertible(let convertible): return convertible.description
        case .dictionary(let dict):
            var result: [String: Any] = [:]
            appendMetadataToJSON(&result, metadata: dict)
            return result
        case .array(let array): return array.map { convertMetadataValueToJSON($0) }
        }
    }
}
