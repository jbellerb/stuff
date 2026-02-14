import Logging

/// Actor that coordinates graceful shutdown behavior with signal handling.
public actor ShutdownCoordinator {
    enum State {
        case running
        case shuttingDown
        case terminated
    }

    /// An action to take in response to a signal.
    public enum ShutdownAction: Equatable, Sendable {
        case graceful
        case forceQuit
        case alreadyTerminated
    }

    private var state: State = .running

    private let logger: Logger?

    public init(logger: Logger? = nil) { self.logger = logger }

    /// Handle a shutdown signal and determine appropriate action.
    public func handleSignal(signal: Int32) -> ShutdownAction {
        switch state {
        case .running:
            state = .shuttingDown
            logger?.info("starting graceful shutdown", metadata: ["shutdown.signal": "\(signal)"])
            return .graceful

        case .shuttingDown:
            state = .terminated
            logger?.error("aborting", metadata: ["shutdown.abort_signal": "\(signal)"])
            return .forceQuit

        case .terminated: return .alreadyTerminated
        }
    }
}
