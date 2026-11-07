import Foundation
import Testing
@testable import InkstoneCore

struct AutoSyncTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func burstsDebounceAndSuccessfulSyncWaitsForPeriodicCheck() {
        var schedule = AutoSyncSchedule(now: start)
        #expect(!schedule.isDue(now: start.addingTimeInterval(2)))
        schedule.requestChange(now: start.addingTimeInterval(2))
        #expect(!schedule.isDue(now: start.addingTimeInterval(4)))
        #expect(schedule.isDue(now: start.addingTimeInterval(5)))
        schedule.started(now: start.addingTimeInterval(5))
        schedule.completed(success: true, now: start.addingTimeInterval(10))
        #expect(!schedule.isDue(now: start.addingTimeInterval(129)))
        #expect(schedule.isDue(now: start.addingTimeInterval(130)))
    }

    @Test func foregroundAndLocalChangesRespectMinimumInterval() {
        var schedule = AutoSyncSchedule(now: start)
        schedule.started(now: start)
        schedule.completed(success: true, now: start.addingTimeInterval(2))
        schedule.requestForeground(now: start.addingTimeInterval(5))
        schedule.requestChange(now: start.addingTimeInterval(6))
        #expect(!schedule.isDue(now: start.addingTimeInterval(29)))
        #expect(schedule.isDue(now: start.addingTimeInterval(30)))
    }

    @Test func failedSyncBackoffCannotBeBypassedByForegroundOrWrites() {
        var schedule = AutoSyncSchedule(now: start)
        var now = start
        for delay in [30.0, 60, 120, 240, 480, 900, 900] {
            schedule.started(now: now)
            schedule.completed(success: false, now: now)
            schedule.requestForeground(now: now)
            schedule.requestChange(now: now)
            #expect(!schedule.isDue(now: now.addingTimeInterval(delay - 1)))
            #expect(schedule.isDue(now: now.addingTimeInterval(delay)))
            now = now.addingTimeInterval(delay)
        }
        schedule.started(now: now)
        schedule.completed(success: true, now: now)
        #expect(schedule.failures == 0)
        #expect(schedule.retryAfter == nil)
        schedule.requestChange(now: now)
        #expect(schedule.isDue(now: now.addingTimeInterval(30)))
    }

    @Test func dueWorkRemainsPendingWhileOwnerIsBusy() {
        var schedule = AutoSyncSchedule(now: start)
        schedule.requestChange(now: start)
        // Deferring while an editor is open does not acknowledge or lose the request.
        #expect(schedule.isDue(now: start.addingTimeInterval(60)))
        #expect(schedule.isDue(now: start.addingTimeInterval(600)))
        schedule.started(now: start.addingTimeInterval(600))
        schedule.completed(success: true, now: start.addingTimeInterval(601))
        #expect(!schedule.isDue(now: start.addingTimeInterval(602)))
    }
}
