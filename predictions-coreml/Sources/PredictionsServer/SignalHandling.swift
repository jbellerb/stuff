import Foundation

/// Creates an AsyncStream that yields signal numbers when Unix signals are
/// received.
public func makeSignalStream(for signals: [Int32]) -> AsyncStream<Int32> {
    AsyncStream { continuation in
        // prevent default signal handling
        for sig in signals { signal(sig, SIG_IGN) }

        let sources: [DispatchSourceSignal] = signals.map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { continuation.yield(sig) }
            source.resume()
            return source
        }

        continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
    }
}
