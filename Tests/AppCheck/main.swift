import Foundation

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("✓ \(message)")
    } else {
        FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
        failures += 1
    }
}

private let original = Slot(
    trigger: .clock(hour: 9, minute: 0),
    wallpaper: .image(path: "/original.jpg"))

var existing = SlotDraft(existing: original)
check(!existing.isNew && !existing.isDirty && !existing.canApply,
      "已有时段刚打开时是干净草稿")
existing.edit { $0.enabled = false }
check(existing.isDirty && existing.canApply, "本地编辑后可以应用")
existing.reconcile(with: original)
check(existing.conflict == nil && existing.slot.enabled == false,
      "外部配置未变化时保留本地编辑")

var external = original
external.wallpaper = .image(path: "/external.jpg")
existing.reconcile(with: external)
check(existing.conflict == .modified && !existing.canApply,
      "外部修改不会被本地草稿静默覆盖")
check(existing.slot.enabled == false, "发现冲突时仍保留本地草稿供用户查看")

var clean = SlotDraft(existing: original)
clean.reconcile(with: external)
check(clean.slot == external && !clean.isDirty && clean.conflict == nil,
      "没有本地改动时自动跟上外部配置")

var deleted = SlotDraft(existing: original)
deleted.edit { $0.enabled = false }
deleted.reconcile(with: nil)
check(!deleted.isNew && deleted.conflict == .deleted && !deleted.canApply,
      "外部删除不会把已有草稿误认成新时段")

let newSlot = Slot(trigger: .clock(hour: 10, minute: 0),
                   wallpaper: .image(path: "/new.jpg"))
var created = SlotDraft(new: newSlot)
created.reconcile(with: nil)
check(created.isNew && created.isDirty && created.canApply,
      "未落盘的新时段不受外部配置刷新影响")
created.markApplied()
check(!created.isNew && !created.isDirty && !created.canApply,
      "只有保存成功后新时段才变成已应用")

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项应用状态测试失败\n".utf8))
    exit(1)
}
print("\n全部应用状态测试通过")
