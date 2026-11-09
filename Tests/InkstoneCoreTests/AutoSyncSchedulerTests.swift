import Foundation
import Testing
@testable import InkstoneCore

@MainActor
private final class ControlledSyncClock {
    var dates: [Date] = []
    private var sleepers: [Int: CheckedContinuation<Void, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var returns = 0
    private var returnObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    func sleep(until date: Date) async throws {
        let index = dates.count
        dates.append(date)
        try await withCheckedThrowingContinuation { continuation in
            sleepers[index] = continuation
            let ready = observers.filter { dates.count >= $0.0 }
            observers.removeAll { dates.count >= $0.0 }
            for (_, continuation) in ready { continuation.resume() }
        }
        returns += 1
        let ready = returnObservers.filter { returns >= $0.0 }
        returnObservers.removeAll { returns >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }
    func waitForReturns(_ count: Int) async {
        if returns >= count { return }
        await withCheckedContinuation { returnObservers.append((count, $0)) }
    }
    func waitForSleeps(_ count: Int) async {
        if dates.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func wake(_ index: Int) { sleepers.removeValue(forKey: index)?.resume() }
}

struct AutoSyncSchedulerTests {
    @Test @MainActor func rescheduleIgnoresStaleWaitAndDoesNotCancelStartedWork() async {
        let clock = ControlledSyncClock()
        let scheduler = AutoSyncScheduler { try await clock.sleep(until: $0) }
        let first = Date(timeIntervalSince1970: 100)
        let second = first.addingTimeInterval(3)
        var actions: [String] = []
        scheduler.schedule(at: first) { actions.append("stale") }
        await clock.waitForSleeps(1)
        scheduler.schedule(at: second) {
            actions.append("current")
            scheduler.schedule(at: nil) {}
            #expect(!Task.isCancelled)
        }
        await clock.waitForSleeps(2)
        clock.wake(0)
        clock.wake(1)
        await clock.waitForReturns(2)
        #expect(actions == ["current"])
        #expect(scheduler.scheduledDate == nil)
        #expect(clock.dates == [first, second])
    }

    @Test @MainActor func suspensionCancelsDeadlineAndSameDeadlineDoesNotCreatePolling() async {
        let clock = ControlledSyncClock()
        let scheduler = AutoSyncScheduler { try await clock.sleep(until: $0) }
        let deadline = Date(timeIntervalSince1970: 600)
        var calls = 0
        scheduler.schedule(at: deadline) { calls += 1 }
        await clock.waitForSleeps(1)
        for _ in 0..<100 { scheduler.schedule(at: deadline) { calls += 1 } }
        scheduler.schedule(at: nil) {}
        clock.wake(0)
        await clock.waitForReturns(1)
        #expect(calls == 0)
        #expect(clock.dates == [deadline])
        scheduler.schedule(at: deadline) { calls += 1 }
        await clock.waitForSleeps(2)
        clock.wake(1)
        await clock.waitForReturns(2)
        #expect(calls == 1)
    }

    @Test func deadlineIncludesRetryAndMinimumInterval() {
        let now = Date(timeIntervalSince1970: 100)
        var schedule = AutoSyncSchedule(now: now)
        #expect(schedule.dueDate == now.addingTimeInterval(3))
        schedule.started(now: now)
        schedule.requestChange(now: now)
        #expect(schedule.dueDate == now.addingTimeInterval(30))
        schedule.completed(success: false, now: now)
        schedule.completed(success: false, now: now)
        schedule.requestForeground(now: now)
        #expect(schedule.dueDate == now.addingTimeInterval(60))
        #expect(!schedule.isDue(now: now.addingTimeInterval(59)))
    }
}
