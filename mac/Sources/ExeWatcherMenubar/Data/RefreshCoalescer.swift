import Foundation

/// Coalesces a stream of filesystem-change events into a bounded sequence of refreshes.
///
/// Replaces the previous "throttle" whose cooldown was stamped when a refresh STARTED,
/// with a window shorter than the refresh itself and no in-flight guard — that produced
/// back-to-back full refreshes under sustained write load. This machine instead:
///   * never starts a refresh while one is in flight (in-flight guard), and
///   * measures the cooldown from refresh COMPLETION, so a busy directory yields at most
///     one refresh per (minInterval + refresh duration) rather than continuous refreshes.
///
/// Pure and clock-injected: `evaluate(now:)` is the only decision point, so behaviour is
/// deterministic and unit-testable without real timers. Not Sendable; intended to be used
/// on a single (main) actor only.
final class RefreshCoalescer {
    struct Config: Equatable {
        /// Minimum quiet gap between one refresh FINISHING and the next STARTING.
        var minIntervalSeconds: TimeInterval
        /// Short delay to batch a burst of events into one refresh (throttle, not debounce:
        /// anchored to the FIRST event of a batch so it cannot be pushed out indefinitely).
        var batchDelaySeconds: TimeInterval
        init(minIntervalSeconds: TimeInterval = 15, batchDelaySeconds: TimeInterval = 2) {
            self.minIntervalSeconds = minIntervalSeconds
            self.batchDelaySeconds = batchDelaySeconds
        }
    }

    enum Decision: Equatable {
        case idle
        case fireNow
        case wait(until: Date)
    }

    private let config: Config
    private var pendingSince: Date?
    private var refreshing = false
    private var lastFinishedAt: Date

    init(config: Config = .init(), startClock: Date = .distantPast) {
        self.config = config
        self.lastFinishedAt = startClock
    }

    /// Record filesystem activity. Cheap; call on every FSEvents callback. Anchors the batch
    /// window to the first unserviced event.
    func noteEvent(now: Date) {
        if pendingSince == nil { pendingSince = now }
    }

    /// Decide what to do at `now`. On `.fireNow` the machine transitions to in-flight and the
    /// caller MUST run the refresh and call `refreshDidFinish` when done. On `.wait(until:)`,
    /// re-invoke `evaluate` at or after the returned deadline. `.idle` means nothing to do
    /// (no pending events, or a refresh is already in flight).
    func evaluate(now: Date) -> Decision {
        if refreshing { return .idle }
        guard let pendingSince else { return .idle }
        let batchReadyAt = pendingSince.addingTimeInterval(config.batchDelaySeconds)
        let cooldownClearedAt = lastFinishedAt.addingTimeInterval(config.minIntervalSeconds)
        let readyAt = max(batchReadyAt, cooldownClearedAt)
        if now >= readyAt {
            self.pendingSince = nil
            refreshing = true
            return .fireNow
        }
        return .wait(until: readyAt)
    }

    /// Mark the current refresh complete; anchors the cooldown at COMPLETION time.
    func refreshDidFinish(now: Date) {
        refreshing = false
        lastFinishedAt = now
    }

    var isRefreshing: Bool { refreshing }
    var hasPending: Bool { pendingSince != nil }
}
