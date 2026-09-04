import SwiftUI

/// 单个时段的编辑页：触发条件 + 壁纸 + 启用 + 删除。
///
/// **改动不即时生效**：页面上的每一次改动只落在 `AppModel` 的草稿里，界面立刻跟手，
/// 但 `schedule.json` 与壁纸都不动 —— 要点底部的「应用」才写下去。
/// 草稿放在 model 里而不是这里的 `@State`：选壁纸是另一页，这个视图会被卸下来重建。
struct SlotPage: View {
    @Environment(AppModel.self) private var model
    let slotID: UUID
    var open: (Page) -> Void

    /// 删除要点两下：面板里弹确认框太重，就地把按钮换成「再点一次」。
    @State private var confirmingDelete = false
    @State private var contentHeight: CGFloat = 320
    /// 这一段本来的天光参数。切成固定时刻之后「天光」那一档就不该消失 ——
    /// 消失了就再也切不回来，草稿还没应用也回不去。
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
                    .padding(Panel.inset)
                    .measureHeight(into: $contentHeight)
                }
                .frame(height: min(contentHeight, Panel.height - Panel.footerHeight))
                Divider()
                footer
            } else {
                Spacer()
                Text(L10n.t("slot.gone")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        // 页面每次出现都认领一次草稿。从选壁纸页返回时也会走到这里，
        // 但 `beginEditing` 认得同一个 id，不会把半路的改动冲掉。
        .onAppear {
            model.beginEditing(slotID)
            if case .solarPhase(let phase, let index, let count) = model.editing(slotID)?.trigger {
                originalPhase = (phase, index, count)
            }
        }
    }

    // MARK: - 触发

    private func trigger(_ slot: Slot) -> some View {
        PanelSection(title: L10n.t("slot.section.trigger")) {
            Picker("", selection: kindBinding(slot)) {
                if originalPhase != nil {
                    Text(L10n.t("slot.kind.phase")).tag(TriggerKind.phase)
                }
                Text(L10n.t("slot.kind.clock")).tag(TriggerKind.clock)
                // 与「固定时刻」并排的是按钮标题，不是句子里的一个词 ——
                // 英文里前者要大写、后者不要，中文两处同形。
                Text(L10n.t("slot.kind.sunrise")).tag(TriggerKind.sunrise)
                Text(L10n.t("slot.kind.sunset")).tag(TriggerKind.sunset)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch slot.trigger {
            case .clock:
                HStack {
                    Text(L10n.t("slot.everyDay")).font(.system(size: 12))
                    Spacer()
                    // 底色与留白在 `TimeField` 里，这里只负责摆位置。
                    TimeField(date: clockBinding(slot))
                }
            case .solarPhase(let phase, let index, let count):
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("slot.phase.position", phase.name, index + 1, count))
                        .font(.system(size: 12))
                    Text(todayLine(slot))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(L10n.t("slot.phase.note"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .solar(let event, let offset):
                // 与固定时刻那一栏同构：一行里左边是控件、右边是算出来的时刻。
                // 弹出菜单只有一百四十来点宽，单独占一行右边全是空的；而「今天是 18:16」
                // 本来就是这个控件的注脚，摆在同一行既填满了宽度又省下一行高度。
                HStack(spacing: 8) {
                    // 偏移是从一串预设里挑，不是一分钟一分钟地步进：步进器要按十几下才能
                    // 从「正好」走到「一小时后」，而这个值本来就没人会调到 37 分。
                    Picker("", selection: offsetBinding(slot)) {
                        ForEach(offsetChoices(including: offset), id: \.self) { value in
                            Text(offsetLabel(event: event, offset: value)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    // 宽度交给控件自己：`NSPopUpButton` 按最宽的那一项定宽（给它
                    // `frame(width:)` 也不认），所以换档时它不会跟着字数忽宽忽窄。
                    .fixedSize()

                    Spacer(minLength: 4)

                    Text(todayLine(slot))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 预设的偏移档位：一小时以内按 15 分一档，再往外拉开到半小时、一小时。
    private static let offsetLadder = [-120, -90, -60, -45, -30, -15, 0,
                                       15, 30, 45, 60, 90, 120]

    /// 手改过 `schedule.json` 的值可能不在档位上（旧版的步进器也能走出 5 的倍数）。
    /// 那就把它插进去，不然菜单选不中当前值，会显示成空白。
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
        return offset > 0 ? L10n.t("slot.offset.after", name, offset)
                          : L10n.t("slot.offset.before", name, -offset)
    }

    /// 偏移是相对量，光看「日落前 30 分」不知道今天几点。把算出来的时刻摆在同一行的右端。
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

    // MARK: - 壁纸

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
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Text(kindLine(slot.wallpaper))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(L10n.t("slot.change")).font(.system(size: 11)).foregroundStyle(.secondary)
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

    // MARK: - 启用 / 删除

    private func enabled(_ slot: Slot) -> some View {
        PanelSection(title: L10n.t("slot.section.state")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("slot.enable")).font(.system(size: 12))
                    Text(L10n.t("slot.enable.note"))
                        .font(.system(size: 11))
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

    /// 新时段还没进过配置，「删除」没有对象可删，那一栏整个不出现 ——
    /// 放弃它走底部的「取消」。
    @ViewBuilder
    private var delete: some View {
        if !model.draftIsNew {
            Button(L10n.t(confirmingDelete ? "slot.delete.confirm" : "slot.delete")) {
                if confirmingDelete {
                    if model.delete(slotID) { open(.timeline) }
                } else {
                    confirmingDelete = true
                    // 误触之后不该一直红着等下一次点击。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmingDelete = false }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: confirmingDelete ? .semibold : .regular))
            .foregroundStyle(.red)
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
    }

    // MARK: - 底部：应用 / 撤销

    /// 删除是即时的（本来就要点两下确认），其余改动全都攒在这里等一次「应用」。
    private var footer: some View {
        HStack(spacing: 8) {
            Text(statusLine)
                .font(.system(size: 11))
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
                // 落盘之后草稿就不「新」了，先记下来再应用。
                let wasNew = model.draftIsNew
                guard model.applyDraft() else { return }
                // 新时段加完直接回时间轴，能看见它排在哪一格。
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

    // MARK: - 绑定

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
                    // 从日出/日落切过来时，用它今天算出来的那个时刻当起点，
                    // 比统一给个 08:00 更接近用户本来的意图。
                    let date = slot.trigger.fireDate(on: Date(),
                                                     coordinate: model.schedule.effectiveCoordinate,
                                                     calendar: .current) ?? Date()
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    updated.trigger = .clock(hour: parts.hour ?? 8, minute: parts.minute ?? 0)
                case .sunrise, .sunset:
                    // 在日出与日落之间来回切时保留已经调好的偏移。
                    let offset: Int = { if case .solar(_, let value) = slot.trigger { return value } else { return 0 } }()
                    updated.trigger = .solar(event: kind == .sunrise ? .sunrise : .sunset,
                                             offsetMinutes: offset)
                case .phase:
                    // 回到天光：天光段的参数（第几张 / 共几张）是导入时定的，
                    // 用户在这一页改不出来，所以只能还原成进来时的那一组。
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
            // 拖时间选择器一秒钟能变几十次 —— 但这些只改内存里的草稿，不落盘，
            // 原来的 0.35 秒去抖也就没有必要了。
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
