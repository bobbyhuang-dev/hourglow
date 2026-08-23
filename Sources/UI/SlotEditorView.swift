import SwiftUI

/// 单个时段的编辑页：触发条件 + 壁纸 + 启用 + 删除。
///
/// 所有改动都即时生效（没有「保存」按钮）。时刻与偏移是连续变化的控件，
/// 交给 `AppModel` 去抖后再落盘，免得拖一次滑块写十几次 `schedule.json`。
struct SlotPage: View {
    @Environment(AppModel.self) private var model
    let slotID: UUID
    var open: (Page) -> Void

    /// 删除要点两下：面板里弹确认框太重，就地把按钮换成「再点一次」。
    @State private var confirmingDelete = false
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "时段", back: { open(.timeline) })
            Divider()

            if let slot = model.slot(slotID) {
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
                .frame(height: min(contentHeight, Panel.height))
            } else {
                Spacer()
                Text("这个时段已经不在了").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - 触发

    private func trigger(_ slot: Slot) -> some View {
        PanelSection(title: "触发") {
            Picker("", selection: kindBinding(slot)) {
                Text("固定时刻").tag(TriggerKind.clock)
                Text("日出").tag(TriggerKind.sunrise)
                Text("日落").tag(TriggerKind.sunset)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch slot.trigger {
            case .clock:
                HStack {
                    Text("每天").font(.system(size: 12))
                    Spacer()
                    DatePicker("", selection: clockBinding(slot),
                               displayedComponents: .hourAndMinute)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                        .frame(width: 92)
                }
            case .solar(let event, let offset):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(offsetLabel(event: event, offset: offset))
                            .font(.system(size: 12))
                        Spacer()
                        Stepper("", value: offsetBinding(slot), in: -240...240, step: 5)
                            .labelsHidden()
                    }
                    Text(todayLine(slot))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func offsetLabel(event: SolarEvent, offset: Int) -> String {
        let name = event == .sunrise ? "日出" : "日落"
        if offset == 0 { return "正好在\(name)" }
        return offset > 0 ? "\(name)后 \(offset) 分钟" : "\(name)前 \(-offset) 分钟"
    }

    /// 偏移是相对量，光看「日落前 30 分」不知道今天几点。把算出来的时刻写在下面。
    private func todayLine(_ slot: Slot) -> String {
        guard let coordinate = model.schedule.effectiveCoordinate else {
            return "缺少坐标，这一段会被跳过"
        }
        guard let date = slot.trigger.fireDate(on: Date(),
                                               coordinate: coordinate,
                                               calendar: .current) else {
            return "今天是极昼或极夜，这一段会被跳过"
        }
        return "今天是 \(Clock.string(date))"
    }

    // MARK: - 壁纸

    private func wallpaper(_ slot: Slot) -> some View {
        PanelSection(title: "壁纸") {
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
                    Text("更换…").font(.system(size: 11)).foregroundStyle(.secondary)
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
            guard let asset = model.catalog.first(where: { $0.id == id }) else { return "系统动态壁纸" }
            let categories = asset.categories.map(Category.localized).joined(separator: " · ")
            return asset.isDownloaded ? categories : "\(categories) · 未下载"
        case .image(let path):
            return (path as NSString).deletingLastPathComponent
        }
    }

    // MARK: - 启用 / 删除

    private func enabled(_ slot: Slot) -> some View {
        PanelSection(title: "状态") {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("启用这个时段").font(.system(size: 12))
                    Text("停用后求值会跳过它，配置仍然留着")
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

    private var delete: some View {
        Button(confirmingDelete ? "再点一次以删除" : "删除这个时段") {
            if confirmingDelete {
                model.delete(slotID)
                open(.timeline)
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

    // MARK: - 绑定

    private enum TriggerKind: Hashable { case clock, sunrise, sunset }

    private func write(_ slot: Slot, _ transform: (inout Slot) -> Void, debounced: Bool = false) {
        var updated = slot
        transform(&updated)
        model.update(updated, debounced: debounced)
    }

    private func kindBinding(_ slot: Slot) -> Binding<TriggerKind> {
        Binding {
            switch slot.trigger {
            case .clock: return .clock
            case .solar(let event, _): return event == .sunrise ? .sunrise : .sunset
            }
        } set: { kind in
            write(slot) { updated in
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
            write(slot, { $0.trigger = .clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0) },
                  debounced: true)
        }
    }

    private func offsetBinding(_ slot: Slot) -> Binding<Int> {
        Binding {
            if case .solar(_, let offset) = slot.trigger { return offset }
            return 0
        } set: { value in
            guard case .solar(let event, _) = slot.trigger else { return }
            write(slot, { $0.trigger = .solar(event: event, offsetMinutes: value) }, debounced: true)
        }
    }

    private func enabledBinding(_ slot: Slot) -> Binding<Bool> {
        Binding { slot.enabled } set: { value in write(slot) { $0.enabled = value } }
    }
}
