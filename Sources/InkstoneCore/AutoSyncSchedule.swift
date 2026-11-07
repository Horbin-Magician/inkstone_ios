import Foundation

/// Timing only: the UI owner must also gate on foreground, saved configuration,
/// an idle vault, and a closed editor before starting a transfer.
public struct AutoSyncSchedule: Sendable {
    public private(set) var nextAttempt: Date
    public private(set) var retryAfter: Date?
    public private(set) var lastAttempt: Date?
    public private(set) var failures = 0

    public init(now: Date = Date()) { nextAttempt = now.addingTimeInterval(3) }

    public mutating func requestChange(now: Date = Date()) {
        // Coalesce a burst of writes into one transfer.
        nextAttempt = now.addingTimeInterval(3)
    }

    public mutating func requestForeground(now: Date = Date()) {
        nextAttempt = min(nextAttempt, now.addingTimeInterval(3))
    }

    public func isDue(now: Date = Date()) -> Bool {
        now >= nextAttempt
            && now >= (retryAfter ?? .distantPast)
            && now >= (lastAttempt?.addingTimeInterval(30) ?? .distantPast)
    }

    public mutating func started(now: Date = Date()) { lastAttempt = now }

    public mutating func completed(success: Bool, now: Date = Date()) {
        if success {
            failures = 0
            retryAfter = nil
            nextAttempt = now.addingTimeInterval(120)
        } else {
            failures = min(failures + 1, 6)
            let delay = min(30 * pow(2, Double(failures - 1)), 900)
            let retry = now.addingTimeInterval(delay)
            retryAfter = retry
            nextAttempt = retry
        }
    }
}
