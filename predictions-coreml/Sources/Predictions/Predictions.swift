import ArgumentParser
import Foundation
import Logging
import PredictionsLog
import PredictionsServer

@main
public struct Predictions: AsyncParsableCommand {
    private nonisolated(unsafe) static var loggingBootstrapped = false

    private static let debug: Bool = ProcessInfo.processInfo.environment["PREDICTIONS_DEBUG"] != nil

    public static let configuration = CommandConfiguration(
        commandName: "predictions",
        abstract: "Local editor predictions backend for Zed",
        version: ReleaseVersion.versionLine(name: "predictions"),
        subcommands: [ServeCommand.self]
    )

    public init() { Self.bootstrapLogging() }

    private static func bootstrapLogging() {
        guard !loggingBootstrapped else { return }
        loggingBootstrapped = true

        let logLevel: Logger.Level = debug ? .debug : .info
        LoggingSystem.bootstrap { label in
            var handler = JSONLogHandler(label: label)
            handler.logLevel = logLevel
            return handler
        }
    }
}

extension ReleaseVersion {
    public static func versionLine(name: String) -> String {
        var buildData: [String] = []
        let commitID = shortCommit.appending(isDirty ? "-dirty" : "")

        let releaseVersion = "\(tag ?? "0.0.0")-\(commitID)"
        if let change = shortChangeID { buildData.append(change) }

        var iso8601 = Date.ISO8601FormatStyle().year().month().day()
        iso8601.timeZone = .current
        buildData.append(iso8601.format(commitDate))

        return "\(name) \(releaseVersion) (\(buildData.joined(separator: " ")))"
    }
}
