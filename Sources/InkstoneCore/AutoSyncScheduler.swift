import Foundation

/// Owns only a cancellable deadline wait. Transfers and file commits are owned by
/// the caller, so rescheduling cannot accidentally cancel a running transaction.
@MainActor
public final class AutoSyncScheduler {
    public typealias Sleep = @MainActor @Sendable (Date) async throws -> Void
    public private(set) var scheduledDate: Date?
    private let sleep: Sleep
    private var timer: Task<Void, Never>?
    private var generation = 0

    public init(sleep: @escaping Sleep = { date in
        try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
    }) { self.sleep = sleep }

    public func schedule(at date: Date?, action: @escaping @MainActor @Sendable () async -> Void) {
        guard scheduledDate != date else { return }
        timer?.cancel(); timer = nil
        generation &+= 1
        scheduledDate = date
        guard let date else { return }
        let expectedGeneration = generation, sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(date) } catch { return }
            guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
            // Release the timer before invoking work: busy/configuration observers
            // may reschedule from inside action without cancelling that action.
            self.timer = nil
            self.scheduledDate = nil
            await action()
        }
    }

    deinit { timer?.cancel() }
}
