import SwiftUI

/// Editor for one slot: trigger, wallpaper, enabled state, and deletion.
///
/// **Changes are not immediate:** edits update an `AppModel` draft so the interface responds at once,
/// but neither `schedule.json` nor the wallpaper changes until Apply is clicked in the footer.
/// The model owns the draft, not local `@State`, because navigating to the picker destroys and recreates this view.
struct SlotPage: View {
    @Environment(AppModel.self) private var model
    let slotID: UUID
    var open: (Page) -> Void

    /// Delete takes two clicks: replace the button in place with a confirmation rather than opening a heavy dialog.
    @State private var confirmingDelete = false
    @State private var contentHeight: CGFloat = 320
    /// The slot's original daylight parameters. Keep the daylight option after switching to a fixed time,
    /// or users cannot switch back even before applying the draft.
    @State private var originalPhase: (phase: DayPhase, index: Int, count: Int)?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: L10n.t(model.draftIsNew ? "slot.title.new" : "slot.title"),
                        back: { open(.timeline) })
            Divider()

            if let slot = model.editing(slotID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        trigger(slot)
                        wallpaper(slot)
                        enabled(slot)
                        delete
                    }
                    .padding(.horizontal, Panel.scrollInset)
                    .padding(.vertical, Panel.inset)
                    .measureHeight(into: $contentHeight)
                    .background(VerticalOnlyScroll())
                }
                .frame(height: min(contentHeight, Panel.height - Panel.footerHeight))
                Divider()
                footer
            } else {
                Spacer()
                Text(L10n.t("slot.gone")).font(Panel.Font.control).foregroundStyle(.secondary)
                Spacer()
            }
        }
        // Claim the draft on every appearance, including returning from the picker.
        // `beginEditing` recognizes the same id and preserves unfinished edits.
        .onAppear {
            model.beginEditing(slotID)
            if case .solarPhase(let phase, let index, let count) = model.editing(slotID)?.trigger {
                originalPhase = (phase, index, count)
            }
        }
    }

    // MARK: - Trigger

    private func trigger(_ slot: Slot) -> some View {
        PanelSection(title: L10n.t("slot.section.trigger")) {
            Picker("", selection: kindBinding(slot)) {
                if originalPhase != nil {
                    Text(L10n.t("slot.kind.phase")).tag(TriggerKind.phase)
                }
                Text(L10n.t("slot.kind.clock")).tag(TriggerKind.clock)
                // These are button titles alongside the fixed-time option, not words inside a sentence.
                // English capitalizes the former but not the latter; Chinese uses the same form for both.
                Text(L10n.t("slot.kind.sunrise")).tag(TriggerKind.sunrise)
                Text(L10n.t("slot.kind.sunset")).tag(TriggerKind.sunset)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch slot.trigger {
            case .clock:
                HStack {
                    Text(L10n.t("slot.everyDay")).font(Panel.Font.control)
                    Spacer()
                    // `TimeField` owns background and padding; this view only positions it.
                    TimeField(date: clockBinding(slot))
                }
            case .solarPhase(let phase, let index, let count):
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("slot.phase.position", phase.name, index + 1, count))
                        .font(Panel.Font.control)
                    Text(todayLine(slot))
                        .font(Panel.Font.secondary)
                        .foregroundStyle(.secondary)
                    Text(L10n.t("slot.phase.note"))
                        .font(Panel.Font.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .solar(let event, let offset):
                // Match the fixed-time row: control on the left, calculated time on the right.
                // The popup is only about 140 pt wide, leaving wasted space if placed on its own row.
                // Today's time is its annotation anyway; keeping them together saves a row of height.
                HStack(spacing: 8) {
                    // Choose from preset offsets rather than stepping minute by minute: reaching an hour
                    // after the event takes too many clicks, and users rarely need exactly 37 minutes.
                    Picker("", selection: offsetBinding(slot)) {
                        ForEach(offsetChoices(including: offset), id: \.self) { value in
                            Text(offsetLabel(event: event, offset: value)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    // Let `NSPopUpButton` size to its widest item (it ignores `frame(width:)`),
                    // keeping its width stable when the selection changes.
                    .fixedSize()

                    Spacer(minLength: 4)

                    Text(todayLine(slot))
                        .font(Panel.Font.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Preset offsets: 15-minute steps within an hour, then wider half-hour and hour intervals.
    private static let offsetLadder = [-120, -90, -60, -45, -30, -15, 0,
                                       15, 30, 45, 60, 90, 120]

    /// Manual `schedule.json` edits may fall between presets; the old stepper also allowed multiples of 5.
    /// Insert the current value so the menu can select it instead of appearing blank.
    private func offsetChoices(including current: Int) -> [Int] {
        var values = Self.offsetLadder
        if !values.contains(current) {
            values.append(current)
            values.sort()
        }
        return values
    }

    private func offsetLabel(event: SolarEvent, offset: Int) -> String {
        let name = L10n.t("sun.\(event.rawValue)")
        if offset == 0 { return L10n.t("slot.offset.exact", name) }
        return offset > 0 ? L10n.t("slot.offset.after", name, String(offset.magnitude))
                          : L10n.t("slot.offset.before", name, String(offset.magnitude))
    }

    /// "30 minutes before sunset" is relative; show today's calculated clock time at the row's trailing edge.
    private func todayLine(_ slot: Slot) -> String {
        guard let coordinate = model.schedule.effectiveCoordinate else {
            return L10n.t("slot.today.noCoordinate")
        }
        guard let date = slot.trigger.fireDate(on: AppModel.now(),
                                               coordinate: coordinate,
                                               calendar: .current) else {
            return L10n.t("slot.today.polar")
        }
        return L10n.t("slot.today", Clock.string(date))
    }

    // MARK: - Wallpaper

    private func wallpaper(_ slot: Slot) -> some View {
        PanelSection(title: L10n.t("slot.section.wallpaper")) {
            Button {
                open(.picker(slotID))
            } label: {
                HStack(spacing: 10) {
                    Thumbnail(url: model.thumbnailURL(for: slot.wallpaper),
                              size: CGSize(width: 56, height: 35))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name(for: slot.wallpaper))
                            .font(Panel.Font.body)
                            .lineLimit(1)
                        Text(kindLine(slot.wallpaper))
                            .font(Panel.Font.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(L10n.t("slot.change")).font(Panel.Font.secondary).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(4)
                .contentShape(.rect)
            }
            .buttonStyle(PanelRowStyle())
        }
    }

    private func kindLine(_ wallpaper: Wallpaper) -> String {
        switch wallpaper {
        case .aerial(let id):
            guard let asset = model.catalog.first(where: { $0.id == id }) else {
                return L10n.t("slot.wallpaper.aerial")
            }
            let categories = asset.categories.map(Category.localized).joined(separator: " · ")
            return asset.isDownloaded ? categories
                                      : L10n.t("slot.wallpaper.notDownloaded", categories)
        case .image(let path):
            return (path as NSString).deletingLastPathComponent
        }
    }

    // MARK: - Enable / Delete

    private func enabled(_ slot: Slot) -> some View {
        PanelSection(title: L10n.t("slot.section.state")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("slot.enable")).font(Panel.Font.control)
                    Text(L10n.t("slot.enable.note"))
                        .font(Panel.Font.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: enabledBinding(slot))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    /// A new slot is not in the configuration yet, so there is nothing to delete; omit this section.
    /// Use Cancel in the footer to abandon it.
    ///
    /// Use a full-width row matching the section cards; bare red text below them looks unfinished.
    /// A red background marks confirmation, since font weight alone does not communicate "click again."
    @ViewBuilder
    private var delete: some View {
        if !model.draftIsNew {
            Button {
                if confirmingDelete {
                    if model.delete(slotID) { open(.timeline) }
                } else {
                    confirmingDelete = true
                    // Do not leave an accidental click armed in red indefinitely.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmingDelete = false }
                }
            } label: {
                Text(L10n.t(confirmingDelete ? "slot.delete.confirm" : "slot.delete"))
                    .font(Panel.Font.control.weight(confirmingDelete ? .semibold : .regular))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(confirmingDelete ? Color.red.opacity(0.10) : Panel.cardFill,
                                in: RoundedRectangle(cornerRadius: Panel.cardCorner, style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(PanelRowStyle())
            .animation(Panel.animation, value: confirmingDelete)
        }
    }

    // MARK: - Footer: Apply / Discard

    /// Deletion is immediate after its two-click confirmation; all other edits wait here for Apply.
    private var footer: some View {
        HStack(spacing: 8) {
            // Add an orange dot for unapplied changes; a text-color change alone is too subtle among gray labels.
            if model.draftIsDirty {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
            }
            Text(statusLine)
                .font(Panel.Font.secondary)
                .foregroundStyle(model.draftIsDirty ? Color.orange : Color.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if model.draftIsNew {
                Button(L10n.t("common.cancel")) {
                    model.endEditing()
                    open(.timeline)
                }
            } else {
                Button(L10n.t("slot.discard")) { model.discardDraft() }
                    .disabled(!model.draftCanDiscard)
            }

            Button(L10n.t(model.draftIsNew ? "slot.add" : "slot.apply")) {
                // Saving makes the draft no longer new, so capture that state before applying.
                let wasNew = model.draftIsNew
                guard model.applyDraft() else { return }
                // Return to the timeline after adding a slot so its position is visible.
                if wasNew { open(.timeline) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.draftCanApply)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, Panel.inset)
        .padding(.vertical, 9)
    }

    private var statusLine: String {
        if model.draftHasConflict { return L10n.t("slot.status.conflict") }
        if model.draftIsNew { return L10n.t("slot.status.new") }
        return L10n.t(model.draftIsDirty ? "slot.status.dirty" : "slot.status.clean")
    }

    // MARK: - Bindings

    private enum TriggerKind: Hashable { case clock, sunrise, sunset, phase }

    private func kindBinding(_ slot: Slot) -> Binding<TriggerKind> {
        Binding {
            switch slot.trigger {
            case .clock: return .clock
            case .solar(let event, _): return event == .sunrise ? .sunrise : .sunset
            case .solarPhase: return .phase
            }
        } set: { kind in
            model.editDraft { updated in
                switch kind {
                case .clock:
                    // When switching from sunrise/sunset, start from today's calculated trigger time.
                    // This preserves intent better than assigning 08:00 to every slot.
                    let date = slot.trigger.fireDate(on: Date(),
                                                     coordinate: model.schedule.effectiveCoordinate,
                                                     calendar: .current) ?? Date()
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    updated.trigger = .clock(hour: parts.hour ?? 8, minute: parts.minute ?? 0)
                case .sunrise, .sunset:
                    // Preserve the chosen offset when switching between sunrise and sunset.
                    let offset: Int = { if case .solar(_, let value) = slot.trigger { return value } else { return 0 } }()
                    updated.trigger = .solar(event: kind == .sunrise ? .sunrise : .sunset,
                                             offsetMinutes: offset)
                case .phase:
                    // Restore daylight parameters (image index / total count) from entry into this page.
                    // They are established on import and cannot be edited here.
                    if let originalPhase {
                        updated.trigger = .solarPhase(phase: originalPhase.phase,
                                                      index: originalPhase.index,
                                                      count: originalPhase.count)
                    }
                }
            }
        }
    }

    private func clockBinding(_ slot: Slot) -> Binding<Date> {
        Binding {
            guard case .clock(let hour, let minute) = slot.trigger else { return Date() }
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0,
                                         of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            // Dragging the time picker can emit dozens of changes per second, but they only update
            // the in-memory draft, not disk; the old 0.35-second debounce is no longer needed.
            model.editDraft { $0.trigger = .clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0) }
        }
    }

    private func offsetBinding(_ slot: Slot) -> Binding<Int> {
        Binding {
            if case .solar(_, let offset) = slot.trigger { return offset }
            return 0
        } set: { value in
            guard case .solar(let event, _) = slot.trigger else { return }
            model.editDraft { $0.trigger = .solar(event: event, offsetMinutes: value) }
        }
    }

    private func enabledBinding(_ slot: Slot) -> Binding<Bool> {
        Binding { slot.enabled } set: { value in model.editDraft { $0.enabled = value } }
    }
}
