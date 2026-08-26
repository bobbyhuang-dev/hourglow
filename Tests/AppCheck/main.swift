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

// MARK: - 新手指引

check(Onboarding.shouldPresent(seenVersion: nil, isFirstRun: true),
      "全新安装的人第一次启动就看到指引")
check(!Onboarding.shouldPresent(seenVersion: nil, isFirstRun: false),
      "配置早就在的老用户升级上来不会被指引拦一道")
check(!Onboarding.shouldPresent(seenVersion: Onboarding.version, isFirstRun: true),
      "看过当前这一版就不再自动弹，哪怕配置被清空了")
check(Onboarding.shouldPresent(seenVersion: Onboarding.version - 1, isFirstRun: false),
      "指引内容有实质更新时再请他看一次")

check(OnboardingStep.allCases.contains(.place) && OnboardingStep.allCases.contains(.resident),
      "要用户去开权限的两步（定位、常驻）都在流程里")
check(OnboardingStep.allCases.allSatisfy { !$0.title.isEmpty && $0.summary.count > 10 },
      "每一步都有标题，也都有讲得清的正文")

var guide = OnboardingFlow()
check(guide.isFirst && !guide.isLast && guide.step == .welcome,
      "指引从「入口在菜单栏」讲起")
check(guide.caption == "第 1 步 / 共 \(OnboardingStep.allCases.count) 步",
      "进度按人的数法从 1 数起")
guide.back()
check(guide.index == 0, "第一步没有上一步可退")
for _ in 0..<(OnboardingStep.allCases.count * 2) { guide.advance() }
check(guide.isLast && guide.step == .done, "一路点「继续」停在最后一步，不会越界")
guide.back()
check(!guide.isLast && guide.step == .timeline, "「上一步」退回时间轴那页")
guide.jump(to: .place)
check(guide.index == 1 && !guide.isFirst, "panelshot 能直接跳到任意一步")

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) 项应用状态测试失败\n".utf8))
    exit(1)
}
print("\n全部应用状态测试通过")
