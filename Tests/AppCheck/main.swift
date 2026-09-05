import Foundation

// Keep these scenarios independent of the system language.
// Language selection itself is covered separately by l10ncheck.
setenv("HOURGLOW_LANG", "en", 1)
L10n.invalidate()

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
      "An existing slot opens as a clean draft")
existing.edit { $0.enabled = false }
check(existing.isDirty && existing.canApply, "Local edits can be applied")
existing.reconcile(with: original)
check(existing.conflict == nil && existing.slot.enabled == false,
      "Local edits survive when the external configuration is unchanged")

var external = original
external.wallpaper = .image(path: "/external.jpg")
existing.reconcile(with: external)
check(existing.conflict == .modified && !existing.canApply,
      "A local draft cannot silently overwrite external changes")
check(existing.slot.enabled == false, "Conflicts preserve the local draft for inspection")

var clean = SlotDraft(existing: original)
clean.reconcile(with: external)
check(clean.slot == external && !clean.isDirty && clean.conflict == nil,
      "A clean draft follows external configuration changes")

var deleted = SlotDraft(existing: original)
deleted.edit { $0.enabled = false }
deleted.reconcile(with: nil)
check(!deleted.isNew && deleted.conflict == .deleted && !deleted.canApply,
      "External deletion does not turn an existing draft into a new slot")

let newSlot = Slot(trigger: .clock(hour: 10, minute: 0),
                   wallpaper: .image(path: "/new.jpg"))
var created = SlotDraft(new: newSlot)
created.reconcile(with: nil)
check(created.isNew && created.isDirty && created.canApply,
      "External configuration refreshes do not affect an unsaved new slot")
created.markApplied()
check(!created.isNew && !created.isDirty && !created.canApply,
      "A new slot becomes applied only after a successful save")

// MARK: - Onboarding

check(Onboarding.shouldPresent(seenVersion: nil, isFirstRun: true),
      "A fresh installation presents onboarding on first launch")
check(!Onboarding.shouldPresent(seenVersion: nil, isFirstRun: false),
      "Existing users are not interrupted by onboarding after upgrading")
check(!Onboarding.shouldPresent(seenVersion: Onboarding.version, isFirstRun: true),
      "The current onboarding version is not shown again even if configuration is cleared")
check(Onboarding.shouldPresent(seenVersion: Onboarding.version - 1, isFirstRun: false),
      "A substantive onboarding update is presented again")

check(OnboardingStep.allCases.contains(.place) && OnboardingStep.allCases.contains(.resident),
      "Both permission-related steps, location and residency, are in the flow")

var guide = OnboardingFlow()
check(guide.isFirst && !guide.isLast && guide.step == .welcome,
      "Onboarding starts at the welcome step")
guide.back()
check(guide.index == 0, "Going back from the first step does not move before it")
for _ in 0..<(OnboardingStep.allCases.count * 2) { guide.advance() }
check(guide.isLast && guide.step == .done, "Advancing stops at the final step without exceeding bounds")
guide.back()
check(!guide.isLast && guide.step == .timeline, "Going back returns to the timeline step")
guide.jump(to: .place)
check(guide.index == 1 && !guide.isFirst, "panelshot can jump directly to a step")

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) app state checks failed\n".utf8))
    exit(1)
}
print("\nAll app state checks passed")
