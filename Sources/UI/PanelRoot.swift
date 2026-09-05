import SwiftUI

/// 面板里的一页。层级只有两层深：时间轴 → 时段 → 选壁纸。
/// 设置、地区与时段并排，都是从时间轴推进一层。
enum Page: Equatable {
    case timeline
    case slot(UUID)
    case picker(UUID)
    case settings
    case place

    var depth: Int {
        switch self {
        case .timeline: return 0
        case .slot:     return 1
        case .settings: return 1
        case .place:    return 1
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
    /// 地区页从时间轴或设置进来，返回要回到来的那一页。
    @State private var placeBack: Page = .timeline

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
            case .settings:
                SettingsPage(open: navigate)
                    .transition(slide)
            case .place:
                PlacePage(open: navigate, backPage: placeBack)
                    .transition(slide)
            }
        }
        // 换语言时把这一层整棵重建。`.id` 挂在页面上而不是 `PanelRoot` 自己身上，
        // 所以 `page` 留在原地 —— 在设置页改完语言，人还在设置页。
        .id(model.languageGeneration)
        // 宽度锁死；高度由各页自己决定（时间轴按时段数收，选壁纸那页固定铺满）。
        .frame(width: Panel.width)
        .animation(Panel.animation, value: page)
        .background(PanelVisibilityObserver { model.setPanelVisible($0) })
        .onAppear {
            // 面板一失焦就收起，「选本地图片」更是必定把它关掉。半路的草稿没有丢，
            // 重新打开时回到那一段继续编辑，而不是把没应用的改动无声地扔掉。
            // 若关闭期间那一段已被外部配置删除，则丢掉旧草稿，不能把它重新带回来。
            switch page {
            case .timeline:
                if let draft = model.draft {
                    if model.canContinueEditing(draft.id) {
                        navigate(.slot(draft.id))
                    } else {
                        model.endEditing()
                    }
                }
            case .slot(let id), .picker(let id):
                if !model.canContinueEditing(id) { navigate(.timeline) }
            case .settings, .place:
                break
            }
        }
        .onChange(of: model.schedule.slots.map(\.id)) {
            // 时段可能被别处删掉（手改 schedule.json、另一个进程）。
            // 停在一个已经不存在的时段上会是一片空白，退回时间轴。
            // 新时段的草稿还没进配置，`editing` 认得它，别把正在填的那一段踢掉。
            if case .slot(let id) = page, !model.canContinueEditing(id) { navigate(.timeline) }
            if case .picker(let id) = page, !model.canContinueEditing(id) { navigate(.timeline) }
        }
    }

    /// 回到时间轴就等于结束这次编辑：没点「应用」的改动到此为止。
    private func navigate(_ target: Page) {
        if target == .place {
            placeBack = page == .place ? placeBack : page
            forward = true
        } else if page == .place {
            forward = false
        } else {
            forward = target.depth > page.depth
        }
        if target == .timeline { model.endEditing() }
        page = target
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
}
