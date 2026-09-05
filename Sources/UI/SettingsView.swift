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
            PanelHeader(title: L10n.t("settings.title"), back: { open(.timeline) })
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 语言排第一：看不懂当前语言的人，要找的就是这一栏。
                    language
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

    // MARK: - 语言

    /// 选项里的语言名永远按母语显示（「简体中文」「English」），不跟着当前界面语言翻译 ——
    /// 会来动这一栏的人，多半正看不懂界面上的字。
    private var language: some View {
        PanelSection(title: L10n.t("settings.section.language")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.section.language")).font(.system(size: 12))
                    Text(L10n.t("settings.language.note"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker("", selection: Binding(get: { model.languagePreference },
                                              set: { model.setLanguage($0) })) {
                    Text(L10n.t("settings.language.system")).tag(L10n.Preference.system)
                    Divider()
                    ForEach(L10n.catalogs, id: \.code) { catalog in
                        Text(catalog.name).tag(L10n.Preference.fixed(catalog.code))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                // `NSPopUpButton` 按最宽的那一项定宽，换语言时它不会忽宽忽窄。
                .fixedSize()
            }
        }
    }

    // MARK: - 更新

    private var updates: some View {
        PanelSection(title: L10n.t("settings.section.update")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.update.auto")).font(.system(size: 12))
                    Text(L10n.t("settings.update.auto.note"))
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
                    Text(L10n.t("settings.update.version", model.currentVersion))
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
                    Button(L10n.t("settings.update.install")) { model.installAvailableUpdate() }
                        .controlSize(.small)
                } else {
                    Button(L10n.t("settings.update.check")) { model.checkForUpdates() }
                        .disabled(!model.canUpdate)
                        .controlSize(.small)
                        .disabled(!model.canUpdate)
                }
            }

            if model.availableUpdate != nil || updateFailed {
                Button(L10n.t("settings.update.releases")) { model.openReleasesPage() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var updateDetail: String {
        switch model.updateState {
        case .idle:
            return model.updateUnavailableReason ?? L10n.t("settings.update.idle")
        case .checking: return L10n.t("settings.update.checking")
        case .upToDate: return L10n.t("settings.update.upToDate")
        case .available(let release):
            let size = ByteCountFormatter.string(fromByteCount: release.byteCount,
                                                 countStyle: .file)
            return L10n.t("settings.update.available", release.version, size)
        case .downloading(let release):
            return L10n.t("settings.update.downloading", release.version)
        case .failed(let reason): return reason
        }
    }

    private var updateFailed: Bool {
        if case .failed = model.updateState { return true }
        return false
    }

    // MARK: - 启动

    private var startup: some View {
        PanelSection(title: L10n.t("settings.section.startup")) {
            if model.canLaunchAtLogin {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("settings.launchAtLogin")).font(.system(size: 12))
                        Text(L10n.t("settings.launchAtLogin.note"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
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
                        Button(L10n.t("common.openSettings")) { model.openLoginItemsSettings() }
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
                Text(L10n.t("settings.launchAtLogin.unavailable"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // M2 那条 LaunchAgent 与 app 自启是两份常驻，同时开着不出错但没必要。
            if model.agentInstalled {
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("settings.agent.running")).font(.system(size: 12))
                        Text(L10n.t("settings.agent.note"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.t("settings.agent.uninstall")) { model.uninstallAgent() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 地区

    /// 地区是单独一页。设置里只留一行入口：现在在哪儿、今天日出日落几点。
    private var location: some View {
        PanelSection(title: L10n.t("settings.section.place")) {
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
            return L10n.t("settings.solar.skipped")
        }
        guard let times = model.solarToday else { return L10n.t("place.sun.polar") }
        return L10n.t("place.sun.today", Clock.string(times.sunrise), Clock.string(times.sunset))
    }

    // MARK: - 壁纸组

    private var sceneImport: some View {
        PanelSection(title: L10n.t("settings.section.scene")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.scene.import")).font(.system(size: 12))
                    Text(L10n.t("settings.scene.note"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(L10n.t(model.importingScene ? "timeline.importing" : "timeline.import")) {
                    model.importSceneFromPanel()
                }
                    .controlSize(.small)
                    .disabled(model.importingScene)
            }
        }
    }

    // MARK: - 帮助

    /// 新手指引是一扇独立的窗（理由见 `OnboardingView`），它只在全新安装时自动出现 ——
    /// 老用户和后悔跳过的人得有个地方找回来，就是这一行。
    private var help: some View {
        PanelSection(title: L10n.t("settings.section.help")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.guide")).font(.system(size: 12))
                    Text(L10n.t("settings.guide.note"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(L10n.t("settings.guide.open")) { OnboardingWindow.shared.present() }
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
            Button(L10n.t("menu.revealConfig")) { model.revealConfigInFinder() }
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
