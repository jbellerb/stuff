import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

public final class PredictionsServer: Sendable {
    private let addr: SocketAddress

    private let logger: Logger?

    private let eventLoopGroup: EventLoopGroup?

    public init(addr: SocketAddress, logger: Logger? = nil, eventLoopGroup: EventLoopGroup? = nil) {
        self.addr = addr
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
    }

    public func run() async throws {
        let group = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let shouldShutdownGroup = (eventLoopGroup == nil)

        let router = buildRouter(logger: logger)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline()
                    .flatMap {
                        channel.pipeline.addHandler(
                            HTTPHandler(router: router, logger: self.logger)
                        )
                    }
            }

        do {
            let channel = try await bootstrap.bind(to: addr).get()
            logger?.info("server listening", metadata: ["server.addr": "\(addr.description)"])

            try await withTaskCancellationHandler {
                try await channel.closeFuture.get()
                logger?.info("server shutting down")
            } onCancel: {
                channel.close(promise: nil)
            }
        } catch {
            logger?
                .error(
                    "failed to bind server",
                    metadata: ["server.host": "\(addr.description)", "exception": "\(error)"]
                )
            if shouldShutdownGroup { try? await group.shutdownGracefully() }
            throw error
        }

        if shouldShutdownGroup {
            do {
                try await group.shutdownGracefully()
                logger?.info("EventLoopGroup shut down successfully")
            } catch {
                logger?
                    .error("failed to shutdown EventLoopGroup", metadata: ["exception": "\(error)"])
            }
        }
    }
}
