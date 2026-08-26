import SwiftUI

/// 设置页：开机自启 + 更新 + 地区入口。地区本身在「选择地区」那一页。
///
/// 这两件事都不是「每天要动」的，所以不占时间轴的版面，收在 ⋯ 里；但它们又都会影响
/// 调度对不对（没坐标日出日落整段被跳过、不自启就得每次自己开），所以也不能藏太深 ——
/// 缺坐标时时间轴上那条提示条本身就是进来的入口。
///
/// 与时段页不同，这里的改动**即时生效**：一个开关、一个坐标，都是单次的动作，
/// 没有「一组改动一起应用」的语义，草稿反而多此一举。
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    var open: (Page) -> Void

    @State private var contentHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "设置", back: { open(.timeline) })
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    startup
                    updates
                    location
                    sceneImport
                    help
                    about
                }
                .padding(Panel.inset)
                .measureHeight(into: $contentHeight)
            }
            .frame(height: min(contentHeight, Panel.height))
        }
        .onAppear { model.refreshSettings() }
    }

    // MARK: - 更新

    private var updates: some View {
        PanelSection(title: "更新") {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("自动更新").font(.system(size: 12))
                    Text("每天检查，验证发布包后自动安装并重启")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { model.automaticUpdatesEnabled },
                                         set: { model.setAutomaticUpdates($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!model.canUpdate)
            }

            Divider()

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("当前版本 \(model.currentVersion)")
                        .font(.system(size: 12)).monospacedDigit()
                    Text(updateDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(updateFailed ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)

                if model.updateState.isBusy {
                    ProgressView().controlSize(.small)
                } else if model.availableUpdate != nil {
                    Button("更新并重启") { model.installAvailableUpdate() }
                        .controlSize(.small)
                } else {
                    Button("检查更新") { model.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!model.canUpdate)
                }
            }

            if model.availableUpdate != nil || updateFailed {
                Button("查看 GitHub 发布页…") { model.openReleasesPage() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var updateDetail: String {
        switch model.updateState {
        case .idle:
            return model.canUpdate ? "从 GitHub Releases 获取正式版" : "请从 HourGlow.app 启动"
        case .checking: return "正在检查…"
        case .upToDate: return "已经是最新版本"
        case .available(let release):
            let size = ByteCountFormatter.string(fromByteCount: release.byteCount,
                                                 countStyle: .file)
            return "新版本 \(release.version) · \(size)"
        case .downloading(let release): return "正在下载并验证 \(release.version)…"
        case .failed(let reason): return reason
        }
    }

    private var updateFailed: Bool {
        if case .failed = model.updateState { return true }
        return false
    }

    // MARK: - 启动

    private var startup: some View {
        PanelSection(title: "启动") {
            if model.canLaunchAtLogin {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("开机自启").font(.system(size: 12))
                        Text("登录后自动回到菜单栏").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(get: { model.launchAtLogin == .enabled },
                                             set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }

                if let note = model.launchAtLoginNote {
                    HStack(spacing: 6) {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("打开设置…") { model.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }

                if let warning = model.launchAtLoginPathWarning {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // 从 build/ 里直接跑的裸二进制没有可注册的 bundle。
                Text("当前不是从 HourGlow.app 启动的，开机自启不可用")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // M2 那条 LaunchAgent 与 app 自启是两份常驻，同时开着不出错但没必要。
            if model.agentInstalled {
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("后台守护进程正在运行").font(.system(size: 12))
                        Text("hourglow-cli 装的 LaunchAgent · 与开机自启重复")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("卸载") { model.uninstallAgent() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 地区

    /// 地区是单独一页。设置里只留一行入口：现在在哪儿、今天日出日落几点。
    private var location: some View {
        PanelSection(title: "地区") {
            Button { open(.place) } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.placeLabel)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Text(solarLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .contentShape(.rect)
            }
            .buttonStyle(PanelRowStyle())
        }
    }

    private var solarLine: String {
        guard model.schedule.effectiveCoordinate != nil else {
            return "日出日落的时段会被跳过"
        }
        guard let times = model.solarToday else { return "今天是极昼或极夜" }
        return "今天 日出 \(Clock.string(times.sunrise)) · 日落 \(Clock.string(times.sunset))"
    }

    // MARK: - 壁纸组

    private var sceneImport: some View {
        PanelSection(title: "壁纸组") {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("导入 24 小时壁纸").font(.system(size: 12))
                    Text("文件夹、一组图片，或 .sundialScene")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(model.importingScene ? "导入中…" : "导入…") { model.importSceneFromPanel() }
                    .controlSize(.small)
                    .disabled(model.importingScene)
            }
        }
    }

    // MARK: - 帮助

    /// 新手指引是一扇独立的窗（理由见 `OnboardingView`），它只在全新安装时自动出现 ——
    /// 老用户和后悔跳过的人得有个地方找回来，就是这一行。
    private var help: some View {
        PanelSection(title: "帮助") {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("新手指引").font(.system(size: 12))
                    Text("五步：入口在哪儿、位置、常驻、时间轴")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("打开") { OnboardingWindow.shared.present() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 关于

    private var about: some View {
        HStack(spacing: 6) {
            Text("HourGlow \(Bundle.main.shortVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Button("在访达中显示配置…") { model.revealConfigInFinder() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

extension Bundle {
    /// 裸二进制（panelshot）没有 Info.plist，给个占位，别在界面上留空。
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
