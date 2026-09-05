import AppKit
import SwiftUI

/// 主面板：顶部是「现在挂着哪张、几点换下一张」，中间是时间轴，底部是三个操作。
struct TimelinePage: View {
    @Environment(AppModel.self) private var model
    var open: (Page) -> Void

    /// 列表实际有多高。时段少的时候面板跟着收，不留一屏空白。
    @State private var listHeight: CGFloat = Panel.rowHeight

    var body: some View {
        VStack(spacing: 0) {
            title
            status
            DayBar()
                .padding(.horizontal, Panel.inset)
                .padding(.bottom, 8)
            notices
            Divider()
            list
            Divider()
            footer
        }
    }

    // MARK: - 顶部

    private var title: some View {
        HStack(spacing: 6) {
            Text("HourGlow")
                .font(Panel.Font.section)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            placeChip
        }
        .padding(.horizontal, Panel.inset)
        .padding(.top, 10)
    }

    /// 日出日落按这个点算。中国全境一个时区，不选地区就永远是上海。
    private var placeChip: some View {
        Button { open(.place) } label: {
            HStack(spacing: 3) {
                Image(systemName: "location.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(model.placeChipLabel)
                    .lineLimit(1)
            }
            .font(Panel.Font.secondary)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Panel.fieldFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.t("timeline.place.help"))
    }

    /// 当前生效的那一段。缩略图 + 名字 + 下次切换，一眼看完。
    private var status: some View {
        HStack(spacing: 10) {
            Thumbnail(url: model.resolution.flatMap { model.thumbnailURL(for: $0.active.wallpaper) },
                      size: CGSize(width: 56, height: 35))

            VStack(alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption)
                        .font(Panel.Font.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(model.resolution.map { model.name(for: $0.active.wallpaper) }
                     ?? L10n.t("timeline.noActive"))
                    .font(Panel.Font.headline)
                    .lineLimit(1)
                // 暂停时这一句本身就是「已暂停」，不另立一个标记：说的是同一件事，
                // 说两遍反而像两处状态。图标 + 橙色足够把它和「下一次切换」区分开。
                Label {
                    Text(subtitle)
                } icon: {
                    if model.schedule.paused {
                        Image(systemName: "pause.fill").font(Panel.Font.caption.weight(.semibold))
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(Panel.Font.secondary)
                .foregroundStyle(model.schedule.paused ? Color.orange : Color.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Panel.inset)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// 大图上方那行小字：说清楚下面这个名字到底是什么。
    /// 用户手动换过、或引擎还没来得及写（暂停中、缺坐标跳过），挂着的就不是这张，
    /// 那时候只能说它是「排程中的」——具体差在哪由下面的提示条负责。
    private var caption: String? {
        guard model.resolution != nil else { return nil }
        return L10n.t(model.activeIsActual ? "timeline.caption.actual"
                                          : "timeline.caption.scheduled")
    }

    private var subtitle: String {
        if model.schedule.paused { return L10n.t("timeline.subtitle.paused") }
        guard let next = model.resolution?.next else {
            return L10n.t(model.resolution == nil ? "timeline.subtitle.empty"
                                                  : "timeline.subtitle.single")
        }
        return L10n.t("timeline.subtitle.next",
                      Clock.string(next.at),
                      model.name(for: next.slot.wallpaper),
                      Clock.remaining(until: next.at))
    }

    @ViewBuilder
    private var notices: some View {
        if let message = model.message {
            PanelNotice(symbol: "arrow.triangle.2.circlepath", text: message)
        } else if model.needsCoordinate {
            // 这条提示本身就是入口：点进设置页去定位或手填经纬度。
            PanelNotice(symbol: "exclamationmark.triangle.fill",
                        text: L10n.t("timeline.notice.noCoordinate"), tint: .orange,
                        action: { open(.place) })
        } else if model.solarUnavailable {
            // 极圈的极昼极夜：坐标没问题，是今天根本没有日出日落。天光分段一段都排不上，
            // 壁纸会一直停着 —— 不说一声，看起来就像 app 坏了。
            PanelNotice(symbol: "sun.max.trianglebadge.exclamationmark.fill",
                        text: L10n.t("timeline.notice.polar"), tint: .orange,
                        action: { open(.place) })
        } else if model.isManuallyOverridden {
            PanelNotice(symbol: "hand.raised.fill",
                        text: L10n.t("timeline.notice.manual"), tint: .secondary)
        } else if model.isFollower {
            PanelNotice(symbol: "bolt.horizontal.circle",
                        text: L10n.t("timeline.notice.follower"), tint: .secondary)
        }
    }

    // MARK: - 时间轴

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.entries) { entry in
                    row(entry)
                }
                addRow
            }
            .padding(.horizontal, Panel.rowInset)
            .padding(.vertical, 6)
            .measureHeight(into: $listHeight)
        }
        .frame(height: min(listHeight, Panel.listMaxHeight))
    }

    private func row(_ entry: AppModel.Entry) -> some View {
        let slot = entry.slot
        let isActive = model.resolution?.active.id == slot.id && !model.schedule.paused

        return Button {
            open(.slot(slot.id))
        } label: {
            HStack(spacing: 10) {
                Thumbnail(url: model.thumbnailURL(for: slot.wallpaper),
                          size: CGSize(width: 44, height: 28))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(Clock.string(entry.time))
                            .font(Panel.Font.body.weight(isActive ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(isActive ? Color.accentColor : .primary)
                        // 固定时刻的规则就是左边那个时间本身，不必再说一遍。
                        if slot.trigger.dependsOnSun {
                            Text(slot.trigger.description)
                                .font(Panel.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !slot.enabled {
                            Text(L10n.t("timeline.slot.disabled"))
                                .font(Panel.Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(model.name(for: slot.wallpaper))
                        .font(Panel.Font.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: Panel.rowHeight)
            .opacity(slot.enabled ? 1 : 0.55)
            // 行首一根竖条，标「现在挂着的就是这一段」。
            // 曾经是整行铺强调色，但那是 macOS 列表里「我选中了它」的样子 ——
            // 这里的行点下去是翻到编辑页，没有选中态可言，状态得用别的记号说。
            .overlay(alignment: .leading) {
                if isActive {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: Panel.nowBar.width, height: Panel.nowBar.height)
                }
            }
        }
        .buttonStyle(PanelRowStyle())
    }

    private var addRow: some View {
        Button {
            open(.slot(model.beginNewSlot()))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 44, height: 28)
                    .foregroundStyle(.secondary)
                Text(L10n.t("timeline.addSlot"))
                    .font(Panel.Font.body)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
        .buttonStyle(PanelRowStyle())
    }

    // MARK: - 底部

    /// 只剩暂停与 ⋯。曾经还有一个「立即应用」，但它做的事引擎自己一直在做 ——
    /// 到点、唤醒、改配置都会重新求值 —— 按下去多半什么也不会变，白占一个主按钮的位置。
    private var footer: some View {
        HStack(spacing: 8) {
            Button(L10n.t(model.schedule.paused ? "timeline.resume" : "timeline.pause")) {
                model.setPaused(!model.schedule.paused)
            }

            Button(L10n.t(model.importingScene ? "timeline.importing" : "timeline.import")) {
                model.importSceneFromPanel()
            }
            .disabled(model.importingScene)

            Spacer(minLength: 0)

            Menu {
                Button(L10n.t("menu.settings")) { open(.settings) }
                    .keyboardShortcut(",")
                Button(L10n.t("menu.place")) { open(.place) }
                Button(L10n.t("menu.import")) { model.importSceneFromPanel() }
                    .disabled(model.importingScene)
                Button(L10n.t("menu.checkUpdates")) {
                    open(.settings)
                    model.checkForUpdates()
                }
                Button(L10n.t("menu.guide")) { OnboardingWindow.shared.present() }
                Button(L10n.t("menu.revealConfig")) { model.revealConfigInFinder() }
                Divider()
                Button(L10n.t("menu.quit")) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .controlSize(.small)
        .padding(.horizontal, Panel.inset)
        .padding(.vertical, 9)
    }
}
