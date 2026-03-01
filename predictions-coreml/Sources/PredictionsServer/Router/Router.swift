import NIOCore
import NIOHTTP1

public struct Router: Sendable {
    private let routes: [Route: Handler]

    private let middlewares: [Middleware]

    public struct Route: Hashable, Sendable {
        let method: HTTPMethod
        let path: String

        public init(method: HTTPMethod, path: String) {
            self.method = method
            self.path = path
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(method.rawValue)
            hasher.combine(path)
        }

        public static func == (lhs: Route, rhs: Route) -> Bool {
            lhs.method.rawValue == rhs.method.rawValue && lhs.path == rhs.path
        }
    }

    public typealias Handler = @Sendable (HTTPRequestHead, ByteBuffer?) async throws -> Response

    public struct Response: Sendable {
        public let status: HTTPResponseStatus

        public let headers: HTTPHeaders

        public let body: String

        public init(status: HTTPResponseStatus, headers: HTTPHeaders, body: String) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func json(status: HTTPResponseStatus, body: String) -> Response {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            return Response(status: status, headers: headers, body: body)
        }
    }

    public init(routes: [(Route, Handler)], middlewares: [Middleware] = []) {
        var dict: [Route: Handler] = [:]

        for (route, handler) in routes {
            // apply middlewares in reverse order so first is outermost
            let wrappedHandler = middlewares.reversed()
                .reduce(handler) { handler, middleware in middleware.wrap(handler) }
            dict[route] = wrappedHandler
        }

        self.routes = dict
        self.middlewares = middlewares
    }

    public func handle(_ request: HTTPRequestHead, body: ByteBuffer? = nil) async throws -> Response
    {
        let route = Route(method: request.method, path: request.uri)

        if let handler = routes[route] { return try await handler(request, body) }

        let matchingRoutes = routes.keys.filter { $0.path == request.uri }
        if !matchingRoutes.isEmpty {
            // 405 Method Not Allowed
            let allowedMethods = matchingRoutes.map { $0.method.rawValue }.joined(separator: ", ")

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Allow", value: allowedMethods)
            return Response(status: .methodNotAllowed, headers: headers, body: "Method Not Allowed")
        }

        // 404 Not Found
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        return Response(status: .notFound, headers: headers, body: "Not Found")
    }
}
