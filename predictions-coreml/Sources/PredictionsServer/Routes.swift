import Logging

func buildRouter(logger: Logger? = nil) -> Router {
    let homeController = HomeController(logger: logger)
    let healthController = HealthController(logger: logger)

    let routes: [(Router.Route, Router.Handler)] = [
        (Router.Route(method: .GET, path: "/"), homeController.get),
        (Router.Route(method: .GET, path: "/health"), healthController.get),
    ]

    var middlewares: [Middleware] = []
    if let logger = logger { middlewares.append(LoggingMiddleware(logger: logger)) }

    return Router(routes: routes, middlewares: middlewares)
}
