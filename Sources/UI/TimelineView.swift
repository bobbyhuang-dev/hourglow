import AppKit
import SwiftUI

/// Main panel: current wallpaper and next change at the top, timeline in the middle, three actions below.
struct TimelinePage: View {
    @Environment(AppModel.self) private var model
    var open: (Page) -> Void

    /// Actual list height. Shrink the panel for fewer slots rather than leaving a screenful of whitespace.
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

    // MARK: - Header

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

    /// Solar times use this coordinate. China has one time zone, so inference without a chosen location always picks Shanghai.
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

    /// The active slot: thumbnail, name, and next change at a glance.
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
                // While paused, the subtitle already says so; a separate badge would repeat one state as two.
                // The icon and orange tint distinguish it from the next-change message.
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

    /// The caption above the large thumbnail explains what its name represents.
    /// After a manual change, or before the engine writes (paused or missing coordinates), this is not
    /// the actual wallpaper. Call it scheduled; the notice below explains the specific discrepancy.
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
            // The notice itself links to location controls for locating or entering coordinates.
            PanelNotice(symbol: "exclamationmark.triangle.fill",
                        text: L10n.t("timeline.notice.noCoordinate"), tint: .orange,
                        action: { open(.place) })
        } else if model.solarUnavailable {
            // Polar day/night: coordinates are valid, but today has no sunrise/sunset and no daylight slots resolve.
            // The wallpaper stays unchanged; without an explanation, the app looks broken.
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

    // MARK: - Timeline

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.entries) { entry in
                    row(entry)
                }
                addRow
            }
            .padding(.horizontal, Panel.scrollInset)
            .padding(.vertical, 6)
            .measureHeight(into: $listHeight)
            .background(VerticalOnlyScroll())
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
                        // A fixed-time rule is already shown by the time on the left; do not repeat it.
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
            // A leading vertical bar marks the currently displayed slot.
            // A full-row accent background used to imply macOS list selection, but these rows
            // navigate to an editor and have no selected state; status needs a different visual cue.
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

    // MARK: - Footer

    /// Pause and ⋯ remain. The old Apply Now button duplicated automatic engine evaluation
    /// on deadlines, wake, and configuration changes; usually doing nothing, it wasted a primary action.
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

            // Grouped by what the item acts on: the schedule, the app, help, then quit.
            Menu {
                Button(L10n.t("menu.place")) { open(.place) }
                Button(L10n.t("menu.import")) { model.importSceneFromPanel() }
                    .disabled(model.importingScene)
                Divider()
                Button(L10n.t("menu.settings")) { open(.settings) }
                    .keyboardShortcut(",")
                Button(L10n.t("menu.checkUpdates")) {
                    open(.settings)
                    model.checkForUpdates()
                }
                Divider()
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
