import ArgumentParser
import Darwin
import Logging
import NIOCore

public struct ServeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the predictions HTTP server"
    )

    @Option(
        name: [.short, .long],
        help: "Address to listen on (format: [host]:port, default: :8080)"
    )
    public var listenAddr: String = ":8080"

    public init() {}

    public mutating func run() async throws {
        let logger = Logger(label: "predictions")

        let addr = try parseListenAddr(listenAddr)
        let server = PredictionsServer(addr: addr, logger: logger)

        let coordinator = ShutdownCoordinator(logger: logger)
        let signalStream = makeSignalStream(for: [SIGTERM, SIGINT])

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.run() }

            for await signal in signalStream {
                let action = await coordinator.handleSignal(signal: signal)
                if action == .forceQuit { Darwin.exit(1) }

                group.cancelAll()
                break
            }
        }
    }
}

func parseListenAddr(_ addr: String) throws -> SocketAddress {
    let parts = addr.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)

    guard parts.count == 2 else {
        throw ValidationError("Invalid listen address format. Use [host]:port")
    }

    let host = parts[0].isEmpty ? "::" : String(parts[0])
    guard let port = Int(parts[1]), port > 0, port <= 65535 else {
        throw ValidationError("Invalid port number. Must be 1-65535")
    }

    do { return try SocketAddress(ipAddress: host, port: port) } catch is SocketAddressError {
        throw ValidationError("Failed to parse IP address")
    }
}
