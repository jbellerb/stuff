import Logging
import PredictionsBackends

func buildRouter(logger: Logger? = nil, predictionsBackend: any PredictionsBackend) -> Router {
    let healthController = HealthController(logger: logger)

    let predictEditsController = PredictEditsController(logger: logger, backend: predictionsBackend)

    let routes: [(Router.Route, Router.Handler)] = [
        (Router.Route(method: .GET, path: "/health"), healthController.get),
        (Router.Route(method: .POST, path: "/v1/edits"), predictEditsController.post),
    ]

    var middlewares: [Middleware] = []
    if let logger = logger { middlewares.append(LoggingMiddleware(logger: logger)) }

    return Router(routes: routes, middlewares: middlewares)
}
