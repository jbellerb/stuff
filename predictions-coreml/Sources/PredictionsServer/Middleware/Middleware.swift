/// Middleware that wraps a Router.Handler.
public protocol Middleware: Sendable {
    /// Wraps a handler with middleware logic.
    func wrap(_ next: @escaping Router.Handler) -> Router.Handler
}
