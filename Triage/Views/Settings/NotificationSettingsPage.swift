import AppKit
import SwiftUI
import UserNotifications

/// Settings ▸ Notifications: what Triage tells you about, quiet hours, and the Dock badge.
struct NotificationSettingsPage: View {
    @EnvironmentObject private var appModel: TriageAppModel
    @AppStorage(TriagePreferenceKeys.notifyNeedsAction) private var notifyNeedsAction = true
    @AppStorage(TriagePreferenceKeys.notifyFollowUps) private var notifyFollowUps = true
    @AppStorage(TriagePreferenceKeys.quietHoursEnabled) private var quietHoursEnabled = false
    @AppStorage(TriagePreferenceKeys.quietHoursStart) private var quietHoursStart = 19
    @AppStorage(TriagePreferenceKeys.quietHoursEnd) private var quietHoursEnd = 8
    @AppStorage(TriagePreferenceKeys.showDockBadge) private var showDockBadge = true
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Form {
            if authorization == .denied {
                Section {
                    Label("Notifications are turned off for Triage in System Settings.", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("Work newly needs your action", isOn: $notifyNeedsAction)
                Toggle("Follow-ups are overdue", isOn: $notifyFollowUps)
            } header: {
                Text("Notify Me When")
            } footer: {
                Text("You hear about each item once, when Copilot first decides it needs you, and again only if it leaves and comes back. Follow-up reminders arrive at most once a day. Notifications are local to this Mac.")
            }

            Section {
                Toggle("Silence notifications overnight", isOn: $quietHoursEnabled)
                Picker("From", selection: $quietHoursStart) { hourOptions }
                    .disabled(!quietHoursEnabled)
                Picker("Until", selection: $quietHoursEnd) { hourOptions }
                    .disabled(!quietHoursEnabled)
            } header: {
                Text("Quiet Hours")
            } footer: {
                Text("Work that arrives during quiet hours waits in the Briefing. Focus modes in System Settings also apply.")
            }

            Section {
                Toggle("Show work needing your action on the Dock icon", isOn: $showDockBadge)
            } header: {
                Text("Dock")
            } footer: {
                Text("Requires Badges to be allowed for Triage in System Settings ▸ Notifications.")
            }

            Section {
                HStack {
                    Text("Banner style, sounds, and Notification Center grouping are managed by macOS.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .onChange(of: showDockBadge) { appModel.refreshAttention() }
        .task {
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    private var hourOptions: some View {
        ForEach(0..<24, id: \.self) { hour in
            Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?
                .formatted(date: .omitted, time: .shortened) ?? "\(hour):00").tag(hour)
        }
    }
}
