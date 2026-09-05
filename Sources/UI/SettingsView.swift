import SwiftUI

/// Settings: launch at login, updates, and a link to the separate location page.
///
/// Startup and location are not daily controls, so they live in the ⋯ menu rather than on the timeline.
/// Both affect scheduling (solar slots need coordinates; without login startup the app must be opened manually),
/// so keep them discoverable: the timeline's missing-coordinate notice is itself an entry point.
///
/// Unlike the slot editor, these changes **take effect immediately**. Each toggle or coordinate change
/// is a single action, not part of a batch to apply together; a draft would add needless complexity.
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
                    // Language comes first: users who cannot read the interface need to find this section.
                    language
                    startup
                    updates
                    location
                    sceneImport
                    help
                    about
                }
                .padding(.horizontal, Panel.scrollInset)
                .padding(.vertical, Panel.inset)
                .measureHeight(into: $contentHeight)
                .background(VerticalOnlyScroll())
            }
            .frame(height: min(contentHeight, Panel.height))
        }
        .onAppear { model.refreshSettings() }
    }

    // MARK: - Language

    /// Always show language names in their native language, not the current interface language.
    /// Users changing this setting may not be able to read the rest of the interface.
    private var language: some View {
        PanelSection(title: L10n.t("settings.section.language")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.language.label")).font(Panel.Font.control)
                    Text(L10n.t("settings.language.note"))
                        .font(Panel.Font.secondary).foregroundStyle(.secondary)
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
                // `NSPopUpButton` sizes to its widest item, keeping width stable across language changes.
                .fixedSize()
            }
        }
    }

    // MARK: - Updates

    private var updates: some View {
        PanelSection(title: L10n.t("settings.section.update")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.update.auto")).font(Panel.Font.control)
                    Text(L10n.t("settings.update.auto.note"))
                        .font(Panel.Font.secondary).foregroundStyle(.secondary)
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
                        .font(Panel.Font.control).monospacedDigit()
                    if !updateFailed {
                        Text(updateDetail)
                            .font(Panel.Font.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)

                if model.updateState.isBusy {
                    ProgressView().controlSize(.small)
                } else if model.availableUpdate != nil {
                    Button(L10n.t("settings.update.install")) { model.installAvailableUpdate() }
                        .controlSize(.small)
                        .disabled(!model.canUpdate)
                } else {
                    Button(L10n.t("settings.update.check")) { model.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!model.canUpdate)
                }
            }

            // Do not let the button squeeze out the error's recovery time or truncate it to two lines.
            if updateFailed {
                Text(updateDetail)
                    .font(Panel.Font.secondary)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.availableUpdate != nil || updateFailed || !model.canUpdate {
                Button(L10n.t("settings.update.releases")) { model.openReleasesPage() }
                    .buttonStyle(.plain)
                    .font(Panel.Font.secondary)
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

    // MARK: - Startup

    private var startup: some View {
        PanelSection(title: L10n.t("settings.section.startup")) {
            if model.canLaunchAtLogin {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("settings.launchAtLogin")).font(Panel.Font.control)
                        Text(L10n.t("settings.launchAtLogin.note"))
                            .font(Panel.Font.secondary).foregroundStyle(.secondary)
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
                            .font(Panel.Font.secondary)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(L10n.t("common.openSettings")) { model.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }

                if let warning = model.launchAtLoginPathWarning {
                    Text(warning)
                        .font(Panel.Font.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // A bare binary run from build/ has no bundle to register.
                Text(L10n.t("settings.launchAtLogin.unavailable"))
                    .font(Panel.Font.secondary)
                    .foregroundStyle(.secondary)
            }

            // The M2 LaunchAgent and app login startup are separate residents; running both works but is redundant.
            if model.agentInstalled {
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("settings.agent.running")).font(Panel.Font.control)
                        Text(L10n.t("settings.agent.note"))
                            .font(Panel.Font.secondary).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.t("settings.agent.uninstall")) { model.uninstallAgent() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Location

    /// Location has its own page. Settings only links to it, showing the current place and today's solar times.
    private var location: some View {
        PanelSection(title: L10n.t("settings.section.place")) {
            Button { open(.place) } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.placeLabel)
                            .font(Panel.Font.control)
                            .lineLimit(1)
                        Text(solarLine)
                            .font(Panel.Font.secondary)
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

    // MARK: - Wallpaper sets

    private var sceneImport: some View {
        PanelSection(title: L10n.t("settings.section.scene")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.scene.import")).font(Panel.Font.control)
                    Text(L10n.t("settings.scene.note"))
                        .font(Panel.Font.secondary).foregroundStyle(.secondary)
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

    // MARK: - Help

    /// Onboarding uses a standalone window (see `OnboardingView`) and opens automatically only on a fresh install.
    /// This row lets existing users and those who skipped it find it again.
    private var help: some View {
        PanelSection(title: L10n.t("settings.section.help")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.guide")).font(Panel.Font.control)
                    Text(L10n.t("settings.guide.note"))
                        .font(Panel.Font.secondary).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(L10n.t("settings.guide.open")) { OnboardingWindow.shared.present() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - About

    private var about: some View {
        HStack(spacing: 6) {
            Text("HourGlow \(Bundle.main.shortVersion)")
                .font(Panel.Font.secondary)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Button(L10n.t("menu.revealConfig")) { model.revealConfigInFinder() }
                .buttonStyle(.plain)
                .font(Panel.Font.secondary)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

extension Bundle {
    /// Bare binaries such as panelshot have no Info.plist; show a placeholder rather than leaving the interface blank.
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
