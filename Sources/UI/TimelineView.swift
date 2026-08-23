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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if model.schedule.paused {
                Label("已暂停", systemImage: "pause.fill")
                    .font(.system(size: 10, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, Panel.inset)
        .padding(.top, 10)
    }

    /// 当前生效的那一段。缩略图 + 名字 + 下次切换，一眼看完。
    private var status: some View {
        HStack(spacing: 10) {
            Thumbnail(url: model.resolution.flatMap { model.thumbnailURL(for: $0.active.wallpaper) },
                      size: CGSize(width: 56, height: 35))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.resolution.map { model.name(for: $0.active.wallpaper) } ?? "没有生效的时段")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Panel.inset)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        if model.schedule.paused { return "暂停中 · 到点不会切换" }
        guard let next = model.resolution?.next else {
            return model.resolution == nil ? "添加一个时段就能开始" : "只有这一段，不会再切换"
        }
        return "\(Clock.string(next.at)) 切换到 \(model.name(for: next.slot.wallpaper))"
            + " · \(Clock.remaining(until: next.at))"
    }

    @ViewBuilder
    private var notices: some View {
        if let message = model.message {
            PanelNotice(symbol: "arrow.triangle.2.circlepath", text: message)
        } else if model.needsCoordinate {
            PanelNotice(symbol: "exclamationmark.triangle.fill",
                        text: "缺少坐标，日出日落的时段会被跳过", tint: .orange)
        } else if model.isManuallyOverridden {
            PanelNotice(symbol: "hand.raised.fill",
                        text: "壁纸被手动换过 · 下一个触发点接管", tint: .secondary)
        } else if model.isFollower {
            PanelNotice(symbol: "bolt.horizontal.circle",
                        text: "由后台守护进程排程，这里只负责编辑", tint: .secondary)
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
                    HStack(spacing: 5) {
                        Text(Clock.string(entry.time))
                            .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(isActive ? Color.accentColor : .primary)
                        // 固定时刻的规则就是左边那个时间本身，不必再说一遍。
                        if case .solar = slot.trigger {
                            Text(slot.trigger.description)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        if !slot.enabled {
                            Text("已停用")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(model.name(for: slot.wallpaper))
                        .font(.system(size: 11))
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
        }
        .buttonStyle(PanelRowStyle(tinted: isActive))
    }

    private var addRow: some View {
        Button {
            open(.slot(model.addSlot()))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 44, height: 28)
                    .foregroundStyle(.secondary)
                Text("添加时段")
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
        .buttonStyle(PanelRowStyle())
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button("立即应用") { model.applyNow() }
                .buttonStyle(.borderedProminent)

            Button(model.schedule.paused ? "继续" : "暂停") {
                model.setPaused(!model.schedule.paused)
            }

            Spacer(minLength: 0)

            Menu {
                Button("在访达中显示配置…") { model.revealConfigInFinder() }
                Divider()
                Button("退出 HourGlow") { NSApplication.shared.terminate(nil) }
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
