import SwiftUI

/// 面板里的一页。层级只有两层深：时间轴 → 时段 → 选壁纸。
enum Page: Equatable {
    case timeline
    case slot(UUID)
    case picker(UUID)

    var depth: Int {
        switch self {
        case .timeline: return 0
        case .slot:     return 1
        case .picker:   return 2
        }
    }
}

/// 菜单栏面板的根。
///
/// 固定 360 × 470，三页在同一块画布上左右推进 —— 和「控制中心」「Wi-Fi」那类
/// 系统面板一个路子：不开新窗口，尺寸从头到尾不变。
struct PanelRoot: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = .timeline
    /// 推进还是后退，决定转场从哪一侧进来。
    @State private var forward = true

    var body: some View {
        ZStack {
            switch page {
            case .timeline:
                TimelinePage(open: navigate)
                    .transition(slide)
            case .slot(let id):
                SlotPage(slotID: id, open: navigate)
                    .transition(slide)
            case .picker(let id):
                WallpaperPicker(slotID: id, open: navigate)
                    .transition(slide)
            }
        }
        // 宽度锁死；高度由各页自己决定（时间轴按时段数收，选壁纸那页固定铺满）。
        .frame(width: Panel.width)
        .animation(Panel.animation, value: page)
        .onChange(of: model.schedule.slots.count) {
            // 时段可能被别处删掉（手改 schedule.json、另一个进程）。
            // 停在一个已经不存在的时段上会是一片空白，退回时间轴。
            if case .slot(let id) = page, model.slot(id) == nil { navigate(.timeline) }
            if case .picker(let id) = page, model.slot(id) == nil { navigate(.timeline) }
        }
    }

    private func navigate(_ target: Page) {
        forward = target.depth > page.depth
        page = target
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
}
