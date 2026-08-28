import Foundation

struct AppMetadata: Equatable {
    let version: String
    let build: String
    let bundleIdentifier: String

    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        bundleIdentifier = bundle.bundleIdentifier ?? "com.triage.mac"
    }

    var displayVersion: String {
        "\(version) (\(build))"
    }
}
