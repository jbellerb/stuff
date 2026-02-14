import Logging
import NIOCore
import NIOHTTP1

final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router

    private let logger: Logger?

    init(router: Router, logger: Logger? = nil) {
        self.router = router
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        let remoteAddress = context.remoteAddress?.description ?? "unknown"
        logger?.debug("channel connected", metadata: ["conn.addr": "\(remoteAddress)"])
    }

    func channelInactive(context: ChannelHandlerContext) {
        let remoteAddress = context.remoteAddress?.description ?? "unknown"
        logger?.debug("channel disconnected", metadata: ["conn.addr": "\(remoteAddress)"])
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = self.unwrapInboundIn(data)

        guard case .head(let head) = requestPart else { return }

        context.eventLoop.makeFutureWithTask { try await self.router.handle(head) }
            .whenComplete { result in
                switch result {
                case .success(let response):
                    self.writeResponse(context: context, head: head, response: response)
                case .failure(let error):
                    let remoteAddress = context.remoteAddress?.description ?? "unknown"
                    self.logger?
                        .error(
                            "handler error",
                            metadata: [
                                "exception": "\(error)", "exception.type": "\(type(of: error))",
                                "http.method": "\(head.method)", "http.path": "\(head.uri)",
                                "conn.addr": "\(remoteAddress)",
                            ]
                        )
                    self.writeErrorResponse(context: context, head: head)
                }
            }
    }

    private func writeResponse(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        response: Router.Response
    ) {
        var headers = response.headers
        headers.add(name: "Content-Length", value: "\(response.body.utf8.count)")

        let responseHead = HTTPResponseHead(
            version: head.version,
            status: response.status,
            headers: headers
        )

        var buffer = context.channel.allocator.buffer(capacity: response.body.utf8.count)
        buffer.writeString(response.body)

        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
            .whenComplete { _ in context.close(promise: nil) }
    }

    private func writeErrorResponse(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let body = "Internal Server Error"
        let bodyLength = body.utf8.count

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(bodyLength)")

        let responseHead = HTTPResponseHead(
            version: head.version,
            status: .internalServerError,
            headers: headers
        )

        var buffer = context.channel.allocator.buffer(capacity: bodyLength)
        buffer.writeString(body)

        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
            .whenComplete { _ in context.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let remoteAddress = context.remoteAddress?.description ?? "unknown"
        let channelActive = context.channel.isActive

        logger?
            .error(
                "channel error caught",
                metadata: [
                    "exception": "\(error)", "exception.type": "\(type(of: error))",
                    "conn.addr": "\(remoteAddress)", "conn.channel.active": "\(channelActive)",
                ]
            )
        context.close(promise: nil)
    }
}
