import Foundation

/// 一次时段编辑会话的纯状态。
///
/// 把它从 `AppModel` 拆出来，是为了把两个容易漏掉的边界写成离线测试：
/// 保存前不能冒充已经应用；编辑期间外部配置变更不能被草稿静默覆盖。
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

    /// 配置被另一个进程刷新时，把干净草稿跟上；有本地改动时保留草稿并标冲突。
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

    /// 只应在持久化成功后调用。
    mutating func markApplied() {
        original = slot
        isNew = false
        conflict = nil
    }
}
