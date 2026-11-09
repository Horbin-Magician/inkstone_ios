import Foundation
import Testing
@testable import InkstoneCore

struct EditorSessionTests {
    @Test func notificationsDoNotAcknowledgeUnsnapshottedEdits() {
        var session = EditorSession()
        session.changed(version: 4, composing: false)
        #expect(session.hasPendingSnapshot)
        #expect(!session.canNavigate(textIsDirty: false))
        let accepted1 = session.acceptSnapshot(version: 3, composing: false)
        #expect(accepted1)
        #expect(session.hasPendingSnapshot)
        #expect(!session.canNavigate(textIsDirty: false))
        let accepted2 = session.acceptSnapshot(version: 4, composing: false)
        #expect(accepted2)
        let accepted3 = session.acceptSnapshot(version: 3, composing: false)
        #expect(!accepted3)
        #expect(session.canNavigate(textIsDirty: false))
        #expect(!session.canNavigate(textIsDirty: true))
    }
    @Test func compositionAndEditsDuringSavingKeepNavigationBlocked() {
        var session = EditorSession()
        session.changed(version: 1, composing: true)
        let accepted4 = session.acceptSnapshot(version: 1, composing: true)
        #expect(accepted4)
        #expect(!session.canNavigate(textIsDirty: false))
        session.composing = false
        session.savePhase = .saving
        session.changed(version: 2, composing: false)
        #expect(!session.canNavigate(textIsDirty: false))
        session.savePhase = .idle
        #expect(!session.canNavigate(textIsDirty: false))
        let accepted5 = session.acceptSnapshot(version: 2, composing: false)
        #expect(accepted5)
        #expect(session.canNavigate(textIsDirty: false))
    }
    @Test func snapshotFailureRequiresExplicitRecoveryAndOldEventsCannotRollBackComposition() {
        var session = EditorSession()
        session.changed(version: 3, composing: true)
        session.changed(version: 2, composing: false)
        #expect(session.composing)
        session.snapshotFailure = "WebKit failed"
        let accepted6 = session.acceptSnapshot(version: 3, composing: false)
        #expect(!accepted6)
        #expect(!session.canNavigate(textIsDirty: false))
        session.useLastSnapshot()
        #expect(session.canNavigate(textIsDirty: false))
        session.savePhase = .failed("disk full")
        #expect(!session.canNavigate(textIsDirty: false))
    }
}

extension EditorSessionTests {
    @Test func compositionSnapshotCannotBecomeSaveableBecauseANewerCommitNotificationArrives() {
        var session = EditorSession()
        session.changed(version: 2, composing: false)
        let accepted7 = session.acceptSnapshot(version: 1, composing: true)
        #expect(accepted7)
        #expect(!session.composing && session.snapshotComposing)
        #expect(!session.canNavigate(textIsDirty: false))
        let accepted8 = session.acceptSnapshot(version: 2, composing: false)
        #expect(accepted8)
        #expect(!session.snapshotComposing)
        #expect(session.canNavigate(textIsDirty: false))
    }
}
