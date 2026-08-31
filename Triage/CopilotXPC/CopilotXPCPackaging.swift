/// Packaging requirements for enabling the Copilot runtime.
///
/// The app embeds `TriageCopilotXPC` and exposes only `TriageCopilotHelper`,
/// which accepts and returns complete length-prefixed frames. The service
/// authenticates its caller and owns all process control.
///
/// 1. Distribution builds embed the universal, Developer ID-signed helper at
///    `Triage.app/Contents/XPCServices/TriageCopilotXPC.xpc/Contents/Resources/TriageCopilotHelper`.
///    The Triage app and XPC service are likewise universal and Developer ID
///    signed for distribution.
/// 2. The official GitHub Copilot CLI is never embedded, re-signed, or resolved
///    from `PATH`. Only explicit user action may download the pinned GitHub
///    release through exactly one bounded `github.com` to
///    `release-assets.githubusercontent.com` redirect. Its archive hash,
///    extracted executable, architecture, and GitHub Developer ID signature are
///    verified before installation in app-owned Application Support.
/// 3. Construct an `NSXPCConnection` to the fixed
///    `com.triage.mac.TriageCopilotXPC` Mach service and adapt it to
///    `CopilotXPCFrameService` with `CopilotXPCServiceClient`, then pass a
///    `CopilotXPCFrameTransport` to `CopilotHelperClient`. Configure both
///    interfaces with `TriageCopilotHelper`.
/// 4. Preserve the service environment allowlist, private empty working
///    directory, size limits, deadline, single-flight policy, authenticated
///    account binding, and consent checks. The installed descriptor is
///    revalidated immediately before launch. Do not add shell invocation,
///    inherited environment, a fallback executable, TCP listener, or ambient
///    credentials.
/// 5. Release verification covers the Triage app, XPC service, and Rust helper.
///    The acquired vendor runtime has independent acquisition and launch-time
///    verification rather than being included in Triage signing or notarization.
enum CopilotXPCPackaging {}
