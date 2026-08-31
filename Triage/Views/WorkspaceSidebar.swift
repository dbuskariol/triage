import SwiftUI

struct WorkspaceSidebar: View {
    let accounts: [GitHubAccount]
    let organizations: [GitHubOrganization]
    let presentation: WorkspacePresentationState
    let onSelectAccount: (AccountID) -> Void
    let onSelectOrganization: (OrganizationID) -> Void
    @Binding var selection: AppSection

    var body: some View {
        List(selection: $selection) {
            Section {
                accountPicker
                organizationPicker
            }

            Section("Work") {
                ForEach(presentation.sectionCounts) { item in
                    Label {
                        HStack {
                            Text(item.section.title)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(item.count.formatted())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(item.count) items")
                        }
                    } icon: {
                        Image(systemName: item.section.systemImage)
                    }
                    .tag(item.section)
                    .accessibilityLabel("\(item.section.title), \(item.count) items")
                    .accessibilityHint("Shows \(item.section.title.lowercased()) work in the selected organization")
                }
            }

            if WorkspaceSidebarPresentation.showsSynchronizationStatus(
                presentation.synchronizationStatus
            ) {
                Section("Synchronization") {
                    SynchronizationStatusLabel(
                        status: presentation.synchronizationStatus,
                        detail: presentation.synchronizationDetail,
                        lastSuccessfulSyncAt: presentation.lastSuccessfulSyncAt
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Triage sidebar")
    }

    @ViewBuilder
    private var accountPicker: some View {
        if accounts.isEmpty {
            Label("No account connected", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        } else {
            Picker(
                "Account",
                selection: Binding(
                    get: { presentation.selectedAccountID },
                    set: { accountID in
                        if let accountID {
                            onSelectAccount(accountID)
                        }
                    }
                )
            ) {
                ForEach(accounts) { account in
                    Text(account.displayName ?? account.login)
                        .tag(Optional(account.id))
                }
            }
            .disabled(accounts.count < 2)
            .accessibilityHint(accounts.count < 2 ? "Only one GitHub account is connected." : "Changes the organization work queue.")
        }
    }

    @ViewBuilder
    private var organizationPicker: some View {
        if organizations.isEmpty {
            Label("No organization selected", systemImage: "building.2")
                .foregroundStyle(.secondary)
        } else {
            Picker(
                "Organization",
                selection: Binding(
                    get: { presentation.selectedOrganizationID },
                    set: { organizationID in
                        if let organizationID {
                            onSelectOrganization(organizationID)
                        }
                    }
                )
            ) {
                ForEach(organizations) { organization in
                    Text(organization.displayName ?? organization.login)
                        .tag(Optional(organization.id))
                }
            }
            .accessibilityHint("Changes the organization work queue.")
        }
    }
}

enum WorkspaceSidebarPresentation {
    /// Keep the source list focused on navigation during healthy or actively
    /// refreshing operation. Persistent status is reserved for states that
    /// require an explicit user decision or explain incomplete local work.
    static func showsSynchronizationStatus(
        _ status: WorkspacePresentationState.SynchronizationStatus
    ) -> Bool {
        switch status {
        case .upToDate, .refreshing:
            false
        case .noAccount, .noOrganization, .initialSynchronization, .partial,
             .ssoRequired, .approvalRequired, .offline, .signInRequired, .unavailable:
            true
        }
    }
}

struct SynchronizationStatusLabel: View {
    let status: WorkspacePresentationState.SynchronizationStatus
    let detail: String?
    let lastSuccessfulSyncAt: Date?

    init(
        status: WorkspacePresentationState.SynchronizationStatus,
        detail: String?,
        lastSuccessfulSyncAt: Date? = nil
    ) {
        self.status = status
        self.detail = detail
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .lineLimit(1)
                if let secondaryText {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: status.systemImage)
                .foregroundStyle(tint)
        }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Synchronization and coverage status for the selected organization.")
    }

    var accessibilityLabel: String {
        [status.title, detail, lastSuccessfulSyncAt.map {
            "Last successful sync \($0.formatted(date: .abbreviated, time: .shortened))"
        }]
        .compactMap { $0 }
        .joined(separator: ". ")
    }

    /// Source-list rows remain compact during degraded states. VoiceOver and
    /// the Help tooltip retain the complete status, including the timestamp.
    var secondaryText: String? {
        if let detail, !detail.isEmpty {
            return detail
        }
        guard let lastSuccessfulSyncAt else { return nil }
        return "Last successful sync \(lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var tint: Color {
        switch status {
        case .upToDate:
            .green
        case .refreshing, .initialSynchronization:
            .accentColor
        case .partial, .ssoRequired, .approvalRequired:
            .orange
        case .offline, .signInRequired:
            .red
        case .noAccount, .noOrganization, .unavailable:
            .secondary
        }
    }
}
