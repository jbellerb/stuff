import Logging
import NIOHTTP1
import Testing

@testable import PredictionsServer

@Suite
struct RouterTests {
    @Test
    func routerReturns404ForUnknownPath() async throws {
        let router = Router(routes: [])
        let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/unknown")

        let response = try await router.handle(request)

        #expect(response.status == .notFound)
        #expect(response.headers["Content-Type"].first == "text/plain; charset=utf-8")
        #expect(response.body == "Not Found")
    }

    @Test
    func routerReturns405ForUnsupportedMethod() async throws {
        let getHandler: Router.Handler = { _ in
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            return Router.Response(status: .ok, headers: headers, body: "OK")
        }

        let router = Router(routes: [(Router.Route(method: .GET, path: "/health"), getHandler)])

        let request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/health")
        let response = try await router.handle(request)

        #expect(response.status == .methodNotAllowed)
        #expect(response.headers["Content-Type"].first == "text/plain; charset=utf-8")
        #expect(response.headers["Allow"].first?.contains("GET") == true)
        #expect(response.body == "Method Not Allowed")
    }

    @Test
    func routerRoutesToHomeController() async throws {
        let router = buildRouter(logger: Logger(label: "test"))
        let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")

        let response = try await router.handle(request)

        #expect(response.status == .ok)
        #expect(response.body == "Hello, world!")
    }

    @Test
    func routerRoutesToHealthController() async throws {
        let router = buildRouter(logger: Logger(label: "test"))
        let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")

        let response = try await router.handle(request)

        #expect(response.status == .ok)
        #expect(response.body == "OK")
    }

    @Test
    func middlewareWrapsHandler() async throws {
        actor ExecutionTracker {
            private(set) var middlewareExecuted = false
            private(set) var handlerExecuted = false

            func recordMiddleware() { middlewareExecuted = true }

            func recordHandler() { handlerExecuted = true }
        }

        let tracker = ExecutionTracker()

        struct TrackingMiddleware: Middleware {
            let tracker: ExecutionTracker

            func wrap(_ next: @escaping Router.Handler) -> Router.Handler {
                return { [tracker] request in
                    await tracker.recordMiddleware()
                    return try await next(request)
                }
            }
        }

        let handler: Router.Handler = { [tracker] _ in
            await tracker.recordHandler()
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            return Router.Response(status: .ok, headers: headers, body: "OK")
        }

        let middleware = TrackingMiddleware(tracker: tracker)
        let router = Router(
            routes: [(Router.Route(method: .GET, path: "/test"), handler)],
            middlewares: [middleware]
        )

        let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/test")
        _ = try await router.handle(request)

        let middlewareExecuted = await tracker.middlewareExecuted
        let handlerExecuted = await tracker.handlerExecuted
        #expect(middlewareExecuted, "middleware should have executed")
        #expect(handlerExecuted, "handler should have executed")
    }
}
