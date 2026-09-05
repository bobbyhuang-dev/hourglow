import Foundation

/// Pure state for a single slot-editing session.
///
/// Extracted from `AppModel` to test two easily missed boundaries offline:
/// drafts must not appear applied before saving, or silently overwrite external changes made during editing.
struct SlotDraft {
    enum Conflict: Equatable {
        case modified
        case deleted
    }

    private(set) var slot: Slot
    private(set) var original: Slot?
    private(set) var isNew: Bool
    private(set) var conflict: Conflict?

    init(existing slot: Slot) {
        self.slot = slot
        original = slot
        isNew = false
    }

    init(new slot: Slot) {
        self.slot = slot
        original = nil
        isNew = true
    }

    var isDirty: Bool {
        guard let original else { return true }
        return slot != original
    }

    var canApply: Bool { isDirty && conflict == nil }

    mutating func edit(_ transform: (inout Slot) -> Void) {
        transform(&slot)
    }

    /// Follow external configuration changes for clean drafts; preserve local edits and flag conflicts otherwise.
    mutating func reconcile(with current: Slot?) {
        guard !isNew else { return }
        guard let current else {
            conflict = .deleted
            return
        }

        if !isDirty {
            reset(to: current)
        } else if current == original {
            conflict = nil
        } else {
            conflict = .modified
        }
    }

    mutating func reset(to current: Slot) {
        slot = current
        original = current
        isNew = false
        conflict = nil
    }

    /// Call only after persistence succeeds.
    mutating func markApplied() {
        original = slot
        isNew = false
        conflict = nil
    }
}
