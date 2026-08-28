import SwiftUI

struct RootView: View {
    @EnvironmentObject private var navigation: AppNavigationModel

    var body: some View {
        NavigationSplitView {
            AppSidebar(selection: $navigation.section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .overview:
            EmptyWorkspaceView()
        case .settings:
            SettingsView()
        }
    }
}

private struct EmptyWorkspaceView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Triage")
                .font(.largeTitle.weight(.bold))
            Text("Ready for its product definition.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Overview")
    }
}

private struct AppSidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                ForEach(AppSection.allCases.filter { $0 != .settings }) { section in
                    sidebarButton(section)
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 8)

            Spacer(minLength: 12)

            Divider()
            sidebarButton(.settings)
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .frame(width: 17)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .font(.body)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isSelected ? Color.accentColor : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
