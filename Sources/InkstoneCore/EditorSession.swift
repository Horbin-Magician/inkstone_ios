import Foundation

/// Editing lifecycle shared by native save/navigation and the rich editor bridge.
/// Text remains owned by the editor; a version notification is not a text snapshot.
public struct EditorSession: Sendable {
    public enum SavePhase: Equatable, Sendable { case idle, saving, failed(String) }
    public var documentID = UUID()
    public var historyID = UUID()
    public private(set) var editingVersion = 0
    public private(set) var snapshotVersion = 0
    public var composing = false
    public var transitioning = false
    public private(set) var snapshotComposing = false
    public var savePhase = SavePhase.idle
    public var snapshotFailure: String?
    public init() {}
    public var hasPendingSnapshot: Bool { editingVersion > snapshotVersion || snapshotFailure != nil }
    public var isSaving: Bool { savePhase == .saving }
    public var saveBlocked: Bool { if case .failed = savePhase { return true }; return false }
    public func canNavigate(textIsDirty: Bool) -> Bool {
        !textIsDirty && !hasPendingSnapshot && !composing && !snapshotComposing && !isSaving && !saveBlocked
    }
    public mutating func changed(version: Int, composing: Bool) {
        guard version >= editingVersion else { return }
        editingVersion = version; self.composing = composing
    }
    public mutating func acceptSnapshot(version: Int, composing: Bool) -> Bool {
        guard snapshotFailure == nil, version >= snapshotVersion else { return false }
        // A new edit can arrive while a snapshot crosses the bridge. Retain that
        // newer version/composition state; accepting the snapshot never clears it.
        if version >= editingVersion { editingVersion = version; self.composing = composing }
        snapshotVersion = version; snapshotComposing = composing
        return true
    }
    public mutating func resetTransportVersions() { editingVersion = 0; snapshotVersion = 0; snapshotComposing = false }
    /// Explicit recovery action after a missing/failed WebKit snapshot.
    public mutating func useLastSnapshot() {
        snapshotFailure = nil; composing = false; savePhase = .idle
        documentID = UUID() // invalidate messages from the discarded WebKit instance
        resetTransportVersions()
    }
}
