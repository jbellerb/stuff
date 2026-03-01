import Logging
import NIOCore
import NIOHTTP1

struct HealthController: Sendable {
    let logger: Logger?

    func get(request: HTTPRequestHead, body: ByteBuffer?) async throws -> Router.Response {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")

        return Router.Response(status: .ok, headers: headers, body: "OK")
    }
}
