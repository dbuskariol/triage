import AppKit
import SwiftUI

/// A colored status dot before the label, as in System Settings.
struct StatusDotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            configuration.title
        }
    }
}

/// Deterministic initials avatar; Triage never downloads profile images.
struct InitialAvatar: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Text(String(text.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]
        let hash = text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

// MARK: - Privacy & Data

/// Privacy and local-data sections, shown on the General tab.
struct PrivacySettingsSections: View {
    @State private var storageBytes: Int64?

    static var dataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Triage", directoryHint: .isDirectory)
    }

    var body: some View {
        Group {
            Section {
                fact("lock.fill", "Stays on this Mac",
                     "Your work, Copilot’s decisions, rules, and instructions are stored in a database encrypted with a key in your Keychain.")
                fact("eye.slash.fill", "No tracking",
                     "Triage has no analytics, telemetry, advertising, or crash uploads.")
                fact("sparkles", "Sent to Copilot",
                     "Only for organizations where you turn Copilot on: titles, descriptions, recent comments, pull request status, and your instructions.")
                fact("arrow.down.circle", "Read-only on GitHub",
                     "Triage only reads from GitHub. It never comments, approves, merges, or changes anything.")
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent("Encrypted data") {
                    Text(storageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                        .monospacedDigit()
                }
                LabeledContent("Keeps") { Text("Work seen in the last 30 days") }
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Self.dataDirectory])
                    }
                }
            } header: {
                Text("Local Data")
            } footer: {
                Text("To remove an account and all of its local data, use Accounts.")
            }
        }
        .task { storageBytes = await Self.directorySize(Self.dataDirectory) }
    }

    private func fact(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private static func directorySize(_ url: URL) async -> Int64 {
        await Task.detached(priority: .utility) { synchronousSize(url) }.value
    }

    nonisolated private static func synchronousSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        while let file = files.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

// MARK: - About

enum AboutSettingsView {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
