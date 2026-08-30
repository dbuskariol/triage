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
                }
            }

            Section {
                SynchronizationStatusLabel(
                    status: presentation.synchronizationStatus,
                    detail: presentation.synchronizationDetail
                )
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
        }
    }
}

struct SynchronizationStatusLabel: View {
    let status: WorkspacePresentationState.SynchronizationStatus
    let detail: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: status.systemImage)
                .foregroundStyle(tint)
        }
        .help(detail ?? status.title)
        .accessibilityLabel(detail.map { "\(status.title). \($0)" } ?? status.title)
    }

    private var tint: Color {
        switch status {
        case .upToDate:
            .green
        case .refreshing:
            .accentColor
        case .partial, .ssoRequired, .approvalRequired:
            .orange
        case .offline, .signInRequired:
            .red
        case .unavailable:
            .secondary
        }
    }
}
