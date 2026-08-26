import AppKit
import SwiftUI

/// 新手指引：五步，一步一件事，每一步都能当场做完再走。
///
/// **为什么它是一扇独立的窗，而不是面板里的第六页**：HourGlow 是 `LSUIElement`，
/// 首次启动后屏幕上什么都不会出现 —— 唯一的入口是菜单栏上一个 16 pt 的沙漏，
/// 而 `MenuBarExtra` 没有「替用户点开」的 API。指引要是长在面板里，就只有已经
/// 找到入口的人才看得见，正好把最需要它的人挡在外面。所以第一步的头一件事就是
/// 告诉用户入口在哪儿，这件事必须发生在面板之外。
///
/// 除此之外仍守面板那套：版式固定（度量全在 `PanelKit` 的 `Guide` 里）、贴原生、
/// 一次只讲一件事。
///
/// 每一步的文案在 `App/Onboarding.swift`，不在这里 —— 说什么是内容，靶子要能查。
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    /// 关掉这扇窗。跳过与「开始使用」都走这里，标记「看过了」由窗口那边统一做。
    var finish: () -> Void

    @State private var flow: OnboardingFlow
    /// 推进还是后退，决定转场从哪一侧进来。和面板同一套语言。
    @State private var forward = true
    @State private var query = ""
    @State private var finder = CitySearch()

    /// `initialStep` 只有 `panelshot` 会用：五步各画一张对照图，
    /// 否则永远只能拍到第一步。正常打开都是从头讲起。
    init(initialStep: OnboardingStep = .welcome, finish: @escaping () -> Void) {
        self.finish = finish
        var flow = OnboardingFlow()
        flow.jump(to: initialStep)
        _flow = State(initialValue: flow)
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            content
            Divider()
            footer
        }
        .frame(width: Guide.width, height: Guide.height)
        .background(Color(nsColor: .windowBackgroundColor))
        // 开机自启的状态要问系统，不能每次重绘都问；进来一次、翻一页问一次就够。
        .onAppear { model.refreshSettings() }
        .onChange(of: flow.index) { model.refreshSettings() }
    }

    // MARK: - 顶部插图

    /// 五步共用同一片天光渐变，只换上面那张图 —— 翻页时背景不闪，像同一扇窗在往前走。
    private var hero: some View {
        ZStack {
            Guide.sky
            art
                .transition(.opacity)
                .id(flow.step)
        }
        .frame(height: Guide.heroHeight)
        .clipped()
        .animation(Panel.animation, value: flow.index)
    }

    @ViewBuilder
    private var art: some View {
        switch flow.step {
        case .welcome:  MenuBarArt(badge: nil)
        case .place:    SunArcArt(sunrise: model.solarToday?.sunrise,
                                  sunset: model.solarToday?.sunset)
        case .resident: MenuBarArt(badge: "checkmark")
        case .timeline: FilmstripArt(frames: filmstrip)
        case .done:     DoneArt()
        }
    }

    /// 第四步那条胶片：用户自己时间轴的前五段。
    private var filmstrip: [FilmstripArt.Frame] {
        let active = model.resolution?.active.id
        return model.entries.prefix(5).map { entry in
            FilmstripArt.Frame(id: entry.slot.id,
                               url: model.thumbnailURL(for: entry.slot.wallpaper),
                               time: entry.time,
                               isActive: entry.slot.id == active)
        }
    }

    // MARK: - 正文

    private var content: some View {
        // ZStack 而不是直接摆：左右推进的那一瞬两页同时在场，
        // 摞在一起才不会把这一栏的高度顶成两倍。
        ZStack {
            page
                .id(flow.step)
                .transition(slide)
        }
        .frame(width: Guide.width, height: Guide.contentHeight)
        .clipped()
        .animation(Panel.animation, value: flow.index)
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(flow.caption)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(flow.step.title)
                        .font(.system(size: 19, weight: .semibold))
                    Text(flow.step.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detail
            }
            .padding(.horizontal, Guide.inset)
            .padding(.vertical, 18)
            .frame(width: Guide.width, alignment: .leading)
        }
        .frame(width: Guide.width, height: Guide.contentHeight)
    }

    @ViewBuilder
    private var detail: some View {
        switch flow.step {
        case .welcome:  welcomeDetail
        case .place:    placeDetail
        case .resident: residentDetail
        case .timeline: timelineDetail
        case .done:     doneDetail
        }
    }

    // MARK: - 第一步：它住在哪儿

    private var welcomeDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("cursorarrow.rays", "点那个沙漏，面板就挂下来",
                   "再点一下收起。点到别处它也会自己收起来 —— 这是菜单栏应用的常态，不是出错。")
            bullet("clock.arrow.circlepath", "剩下的时间它在后台算下一次切换",
                   "不轮询、几乎不耗电。合盖睡过了某个时刻，醒来会把那一次补上。")
            bullet("hand.raised", "你自己换的壁纸，它不抢",
                   "在系统设置里挑了别的，那张会一直留到下一个切换点。")
            Text("接下来三步，大概一分钟。随时可以点左下角跳过。")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 第二步：位置（唯一要点「允许」的权限）

    private var placeDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.placeLabel)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text(sunLine)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.locating == .requesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("使用当前位置") { model.requestPreciseLocation() }
                            .controlSize(.small)
                    }
                }

                // 权限要说在按钮旁边：点下去会发生什么、系统会问什么、该按哪个。
                Text("点它会弹出系统的定位授权对话框，选「允许」。只取一次坐标，"
                     + "算完就存在本机，不上传。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.locating == .denied {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Text("定位权限被拒了。系统不会再问第二次 —— 要么去"
                             + "「隐私与安全性 › 定位服务」里把 HourGlow 打开，"
                             + "要么在下面搜一个城市，效果一样够用。")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("打开设置…") { PreciseLocation.openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
                if case .failed(let reason) = model.locating {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("不想给定位？搜个城市就行")
                    .font(.system(size: 12, weight: .medium))
                citySearchField
                cityResults
            }

            Text("以后随时能改：面板右上角那颗地点胶囊。中国全境同一个时区，"
                 + "不选城市就一直按上海算 —— 深圳的日出差二十来分钟。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sunLine: String {
        guard model.schedule.effectiveCoordinate != nil else {
            return "还没有坐标，日出日落的时段会被跳过"
        }
        guard let times = model.solarToday else { return "今天是极昼或极夜" }
        return "今天 日出 \(Clock.string(times.sunrise)) · 日落 \(Clock.string(times.sunset))"
    }

    private var citySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("城市名，中英文或拼音", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if finder.searching {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onChange(of: query) { _, _ in finder.update(query: query) }
    }

    /// 只在真的搜了之后才出结果，而且最多四条。
    ///
    /// 空搜时 `Cities.search` 会给一份常用城市，地点页那种满屏列表放得下，这里放不下 ——
    /// 一屏就这么高，默认列表会把「搜」这个动作本身挤到屏幕外。挑不到就去面板里慢慢挑。
    @ViewBuilder
    private var cityResults: some View {
        let typed = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hits = typed ? Array(finder.results(for: query).prefix(4)) : []
        if hits.isEmpty {
            if typed, !finder.searching {
                Text("找不到这个地方")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        } else {
            VStack(spacing: 1) {
                ForEach(hits) { city in
                    Button { model.setPlace(city) } label: {
                        HStack(spacing: 6) {
                            Text(city.name)
                                .font(.system(size: 12))
                            Text(city.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if isCurrent(city) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                    }
                    .buttonStyle(PanelRowStyle())
                }
            }
        }
    }

    private func isCurrent(_ city: City) -> Bool {
        guard let current = model.schedule.location else { return false }
        return abs(current.latitude - city.coordinate.latitude) < 0.02
            && abs(current.longitude - city.coordinate.longitude) < 0.02
    }

    // MARK: - 第三步：常驻

    private var residentDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                if model.canLaunchAtLogin {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自启")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("登录后自动回到菜单栏")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Toggle("", isOn: Binding(get: { model.launchAtLogin == .enabled },
                                                 set: { model.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }

                    if let note = model.launchAtLoginNote {
                        HStack(alignment: .top, spacing: 8) {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("打开设置…") { model.openLoginItemsSettings() }
                                .controlSize(.small)
                        }
                    }

                    // 登录项记的是 bundle 的路径。在「下载」里开了自启，
                    // 之后一拖进「应用程序」，那条登录项就指向一个不存在的 app。
                    if !model.runsFromApplicationsFolder {
                        Divider()
                        Text("现在从「\(model.enclosingFolderName)」运行。登录项记的是路径，"
                             + "app 一挪就失效 —— 建议先把 HourGlow 拖进「应用程序」，"
                             + "再回来打开这个开关。")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("当前不是从 HourGlow.app 启动的，开机自启不可用。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            bullet("menubar.arrow.up.rectangle", "系统问「是否允许在菜单栏中显示」时，选「允许」",
                   "不允许的话菜单栏上不会出现沙漏，你就没有入口了。"
                   + "改：系统设置 › 控制中心 › 菜单栏。")
            bullet("bolt.slash", "退出了就不切了",
                   "⋯ 菜单里的「退出 HourGlow」是真的退出。想临时停一会儿，用「暂停」。")
        }
    }

    // MARK: - 第四步：时间轴

    private var timelineDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("hand.tap", "点一行 → 改时刻，或者换一张壁纸",
                   "改完点底部的「应用」才算数。不点就什么都没变 —— 试错不用真的换过去。")
            bullet("plus", "「添加时段」→ 一天想切几次都行",
                   "固定时刻，或者「日落前 30 分」这种跟着太阳走的；后者每天自己漂移。")
            bullet("photo.stack", "「导入…」→ 一整套 24 小时壁纸",
                   "选一个装满静帧的文件夹，自动按当天的日出日落均分成一天。"
                   + "会替换整条时间轴，动手前会问一句。")
            bullet("pause.circle", "「暂停」→ 临时不切",
                   "菜单栏图标会变成半满的沙漏，一眼看得出调度停了。")
        }
    }

    // MARK: - 第五步：清单

    private var doneDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                checklist(done: model.schedule.location != nil,
                          title: "位置",
                          detail: model.schedule.location != nil
                              ? model.placeLabel
                              : (model.schedule.effectiveCoordinate != nil
                                 ? "\(model.placeLabel) · 按时区估的，选个城市更准"
                                 : "还没有坐标，日出日落的时段会被跳过"))
                Divider()
                checklist(done: model.launchAtLogin == .enabled,
                          title: "开机自启",
                          detail: model.canLaunchAtLogin
                              ? (model.launchAtLogin == .enabled ? "已打开" : "还没开，设置里随时能补")
                              : "当前不是从 HourGlow.app 启动的")
                Divider()
                checklist(done: !model.schedule.slots.isEmpty,
                          title: "时间轴",
                          detail: "\(model.schedule.slots.count) 个时段，"
                              + (model.resolution.map { "现在这一段是 \(model.name(for: $0.active.wallpaper))" }
                                 ?? "还没有能生效的时段"))
            }

            bullet("menubar.rectangle", "入口在菜单栏右上角那个沙漏",
                   "点一下打开，再点一下收起。")
            bullet("questionmark.circle", "想再看一遍这套指引",
                   "面板底部的 ⋯ 菜单 › 新手指引。")
        }
    }

    private func checklist(done: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 13))
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        ZStack {
            dots
            HStack(spacing: 8) {
                if !flow.isLast {
                    Button("跳过指引") { finish() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !flow.isFirst {
                    Button("上一步") {
                        forward = false
                        flow.back()
                    }
                    .controlSize(.regular)
                }
                Button(flow.isLast ? "开始使用" : "继续") {
                    if flow.isLast {
                        finish()
                    } else {
                        forward = true
                        flow.advance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Guide.inset)
        }
        .frame(height: Guide.footerHeight)
    }

    /// 进度点。五颗，走到哪儿哪颗实心 —— 让人知道还剩几步，跳过的决定才有依据。
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0..<flow.count, id: \.self) { index in
                Circle()
                    .fill(index == flow.index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
        .animation(Panel.animation, value: flow.index)
    }

    // MARK: - 零件

    /// 正文里的一条：图标 + 一句话 + 一行补充。整套指引都靠这些条讲。
    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// 能当场动手的那一块，和设置页的分组卡片一个样子。
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
}

// MARK: - 插图

extension Guide {
    /// 夜 → 晨光。和应用图标同一条渐变，指引与图标看上去是同一件东西。
    static var sky: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.13, green: 0.16, blue: 0.32),
                Color(red: 0.33, green: 0.30, blue: 0.47),
                Color(red: 0.78, green: 0.47, blue: 0.33),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 一台假的 Mac：屏幕顶上有菜单栏，沙漏在右边被圈出来。
///
/// 第一步要说的就是「入口在那儿」，而这句话用画的比用写的快得多。
/// 第三步复用同一张图，只在沙漏上多一枚对勾 —— 讲的是「登录之后它自己回来」，
/// 换一张陌生的图反而要重新读一遍。
private struct MenuBarArt: View {
    var badge: String?

    /// 这台假 Mac 的度量。菜单栏那一条在这儿比真机夸张得多 —— 图要讲的就是它，
    /// 按真实比例画出来只剩两三个像素高，沙漏根本认不出来。
    private static let screen = CGSize(width: 344, height: 88)
    private static let barHeight: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.11, blue: 0.23),
                                          Color(red: 0.31, green: 0.22, blue: 0.28)],
                                 startPoint: .top, endPoint: .bottom))
            // 屏幕里也得有张壁纸 —— 空着一块深色矩形看着像图没加载出来。
            .overlay(alignment: .bottom) { wallpaper }
            .overlay(alignment: .top) { menuBar }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .frame(width: Self.screen.width, height: Self.screen.height)
    }

    /// 屏幕里那张示意用的壁纸：只留一层从中间往下慢慢亮起来的地光。
    /// 原先中间还画了一颗带光晕的太阳，去掉了 —— 这一步讲的是「入口在菜单栏」，
    /// 屏幕正中多一团发亮的东西，只会把视线从右上角那颗沙漏那儿拽走。
    private var wallpaper: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.13)],
                       startPoint: .center, endPoint: .bottom)
            .frame(height: Self.screen.height - Self.barHeight)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9,
                                              style: .continuous))
    }

    private var menuBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo")
            Text("Finder").font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "wifi")
            Image(systemName: "switch.2")
            hourglass
            Text("9:41").font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 11)
        .frame(height: Self.barHeight)
        .background(.white.opacity(0.14))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9,
                                          style: .continuous))
    }

    /// 圈出来的那一颗。虚线圈是「看这里」最通用的记号，不必再配一句话。
    private var hourglass: some View {
        Image(systemName: "hourglass")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 21, height: 21)
            .background(.white.opacity(0.22), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(.white,
                                  style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                    .frame(width: 27, height: 27)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 7.5, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 11, height: 11)
                        .background(Color.green, in: Circle())
                        .offset(x: 6, y: 5)
                }
            }
    }
}

/// 今天的太阳走到哪儿了：地平线、一道弧、弧上一颗按当前时刻落位的太阳。
///
/// 位置是真算出来的，不是摆好看的 —— 第二步在讲「日出日落按你的位置算」，
/// 一张对得上今天的图比一句承诺有说服力。没坐标时太阳压在地平线上并且发灰。
private struct SunArcArt: View {
    var sunrise: Date?
    var sunset: Date?

    /// 0 = 日出，1 = 日落。没坐标时给 nil。
    private var progress: Double? {
        guard let sunrise, let sunset else { return nil }
        let total = sunset.timeIntervalSince(sunrise)
        guard total > 0 else { return nil }
        return min(max(Date().timeIntervalSince(sunrise) / total, 0), 1)
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let base = size.height - 22
                let radius = min(size.width / 2 - 26, base - 10)
                let center = CGPoint(x: size.width / 2, y: base)

                var arc = Path()
                arc.addArc(center: center, radius: radius,
                           startAngle: .degrees(180), endAngle: .degrees(360),
                           clockwise: false)
                context.stroke(arc, with: .color(.white.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))

                var horizon = Path()
                horizon.move(to: CGPoint(x: center.x - radius - 16, y: base))
                horizon.addLine(to: CGPoint(x: center.x + radius + 16, y: base))
                context.stroke(horizon, with: .color(.white.opacity(0.55)), lineWidth: 1)

                let t = progress ?? 0.0
                let sun = CGPoint(x: center.x - radius * cos(.pi * t),
                                  y: base - radius * sin(.pi * t))
                let known = progress != nil
                let glow = CGRect(x: sun.x - 11, y: sun.y - 11, width: 22, height: 22)
                context.fill(Path(ellipseIn: glow),
                             with: .color(.white.opacity(known ? 0.22 : 0.1)))
                let disc = CGRect(x: sun.x - 6, y: sun.y - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: disc),
                             with: .color(known
                                          ? Color(red: 1, green: 0.85, blue: 0.45)
                                          : .white.opacity(0.4)))
            }
            .frame(width: 300, height: 104)
        }
        .frame(width: 300, height: 104)
        .overlay(alignment: .bottomLeading) { label("日出", sunrise) }
        .overlay(alignment: .bottomTrailing) { label("日落", sunset) }
    }

    private func label(_ name: String, _ date: Date?) -> some View {
        Text("\(name) \(Clock.string(date))")
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }
}

/// 用户自己那条时间轴的胶片条：几张缩略图 + 今天的实际时刻，当前那一格描一圈。
///
/// 第四步讲「面板中间那张表就是一天」，摆一张假的示意图不如直接把他自己的那几张
/// 排出来 —— 等他真打开面板，看到的就是同一批图。
private struct FilmstripArt: View {
    struct Frame: Identifiable {
        let id: UUID
        let url: URL?
        let time: Date?
        let isActive: Bool
    }

    var frames: [Frame]

    var body: some View {
        HStack(spacing: 8) {
            if frames.isEmpty {
                Text("时间轴还是空的")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ForEach(frames) { frame in
                    VStack(spacing: 5) {
                        Thumbnail(url: frame.url, size: CGSize(width: 66, height: 41))
                            .overlay {
                                if frame.isActive {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(.white, lineWidth: 1.5)
                                }
                            }
                        Text(Clock.string(frame.time))
                            .font(.system(size: 9, weight: frame.isActive ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(frame.isActive ? 1 : 0.7))
                    }
                }
            }
        }
        .frame(height: 104)
    }
}

/// 收尾：沙漏 + 一枚对勾。
private struct DoneArt: View {
    var body: some View {
        Image(systemName: "hourglass")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(.white)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, Color.green)
                    .offset(x: 12, y: 4)
            }
            .frame(height: 104)
    }
}
