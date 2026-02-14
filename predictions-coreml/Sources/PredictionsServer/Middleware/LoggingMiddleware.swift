import Logging
import NIOHTTP1

/// Middleware that logs HTTP requests and responses with timing information.
public struct LoggingMiddleware: Middleware {
    private let logger: Logger

    public init(logger: Logger) { self.logger = logger }

    public func wrap(_ next: @escaping Router.Handler) -> Router.Handler {
        return { [logger] request in
            let startTime = ContinuousClock.now

            logger.debug(
                "incoming request",
                metadata: ["http.method": "\(request.method)", "http.path": "\(request.uri)"]
            )

            do {
                let response = try await next(request)
                let duration = ContinuousClock.now - startTime

                logger.debug(
                    "request completed",
                    metadata: [
                        "http.method": "\(request.method)", "http.path": "\(request.uri)",
                        "http.resp.status": "\(response.status.code)",
                        "http.resp.duration": "\(formatDuration(duration))",
                    ]
                )

                return response
            } catch {
                let duration = ContinuousClock.now - startTime

                logger.error(
                    "request failed",
                    metadata: [
                        "http.method": "\(request.method)", "http.path": "\(request.uri)",
                        "exception": "\(error)", "exception.type": "\(type(of: error))",
                        "http.resp.duration": "\(formatDuration(duration))",
                    ]
                )

                throw error
            }
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        let milliseconds =
            (duration.components.seconds * 1000)
            + (duration.components.attoseconds / 1_000_000_000_000_000)
        return String(milliseconds)
    }
}
