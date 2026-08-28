import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController

    var body: some View {
        VStack(spacing: 0) {
            settingsNavigation
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageHeader
                    categoryContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
        .onAppear {
            preferences.refreshLaunchAtLoginStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            preferences.refreshLaunchAtLoginStatus()
        }
    }

    private var settingsNavigation: some View {
        HStack(spacing: 6) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    navigation.settingsCategory = category
                } label: {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(
                            navigation.settingsCategory == category
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(navigation.settingsCategory == category ? .primary : .secondary)
                .accessibilityAddTraits(
                    navigation.settingsCategory == category ? .isSelected : []
                )
                .help(category.title)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .background(.bar)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(navigation.settingsCategory.title)
                .font(.largeTitle.weight(.bold))
            Text(categorySubtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var categorySubtitle: String {
        switch navigation.settingsCategory {
        case .general: "Choose how Triage integrates with macOS."
        case .updates: "Keep Triage current through signed, verified updates."
        case .about: "Review this installation and its privacy baseline."
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch navigation.settingsCategory {
        case .general:
            generalSettings
        case .updates:
            updateSettings
        case .about:
            aboutSettings
        }
    }

    private var generalSettings: some View {
        SettingsCard(title: "App") {
            SettingsToggleRow(
                title: "Show Triage in the menu bar",
                detail: "Keep Triage available without leaving the main window open.",
                systemImage: "menubar.rectangle",
                isOn: $preferences.showMenuBarExtra
            )
            SettingsDivider()
            SettingsToggleRow(
                title: "Launch at login",
                detail: "Make Triage available as soon as you sign in.",
                systemImage: "power",
                isOn: Binding(
                    get: { preferences.launchAtLoginEnabled },
                    set: { preferences.setLaunchAtLogin($0) }
                )
            )
            if let error = preferences.launchAtLoginError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 42)
            }
        }
    }

    private var updateSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Automatic Updates") {
                SettingsToggleRow(
                    title: "Automatically check for updates",
                    detail: "Securely check the signed Triage release feed in the background.",
                    systemImage: "arrow.triangle.2.circlepath",
                    isOn: Binding(
                        get: { softwareUpdates.automaticallyChecksForUpdates },
                        set: { softwareUpdates.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                if softwareUpdates.automaticallyChecksForUpdates {
                    SettingsDivider()
                    SettingsValueRow(
                        title: "Check frequency",
                        detail: "How often Triage checks the signed update feed.",
                        systemImage: "calendar.badge.clock"
                    ) {
                        Picker(
                            "Frequency",
                            selection: Binding(
                                get: { softwareUpdates.updateCheckInterval },
                                set: { softwareUpdates.setUpdateCheckInterval($0) }
                            )
                        ) {
                            ForEach(AppUpdateCheckInterval.allCases) { interval in
                                Text(interval.title).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                    if softwareUpdates.allowsAutomaticUpdates {
                        SettingsDivider()
                        SettingsToggleRow(
                            title: "Download updates automatically",
                            detail: "Prepare verified updates so they are ready when you quit Triage.",
                            systemImage: "arrow.down.circle",
                            isOn: Binding(
                                get: { softwareUpdates.automaticallyDownloadsUpdates },
                                set: { softwareUpdates.setAutomaticallyDownloadsUpdates($0) }
                            )
                        )
                    }
                }
            }

            SettingsCard(title: "Current Version") {
                SettingsActionRow(
                    title: metadata.displayVersion,
                    detail: "Updates are signed and verified by Sparkle before installation.",
                    systemImage: "app.badge.checkmark"
                ) {
                    Button("Check Now") {
                        softwareUpdates.checkForUpdates()
                    }
                    .disabled(!softwareUpdates.canCheckForUpdates)
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Triage") {
                SettingsValueRow(
                    title: "Version \(metadata.displayVersion)",
                    detail: "A native macOS 26 application.",
                    systemImage: "app.badge.checkmark"
                ) {
                    Text(metadata.bundleIdentifier)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Privacy") {
                SettingsValueRow(
                    title: "Private by default",
                    detail: "Triage declares no tracking and collects no data.",
                    systemImage: "hand.raised"
                ) {
                    Label("No Data", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var metadata: AppMetadata {
        AppMetadata()
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.headline)
                content
            }
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 42)
    }
}

private struct SettingsRowDescription: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsValueRow<Control: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let control: Control

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsRowDescription(title: title, detail: detail, systemImage: systemImage)
            control
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct SettingsActionRow<Control: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let control: Control

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            control
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsValueRow(title: title, detail: detail, systemImage: systemImage) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
