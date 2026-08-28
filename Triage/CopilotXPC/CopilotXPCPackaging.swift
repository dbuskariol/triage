/// Packaging requirements for enabling the Copilot runtime.
///
/// The app embeds `TriageCopilotXPC` and exposes only `TriageCopilotHelper`,
/// which accepts and returns complete length-prefixed frames. The service
/// authenticates its caller and owns all process control.
///
/// 1. Embed the signed universal helper at
///    `Triage.app/Contents/XPCServices/TriageCopilotXPC.xpc/Contents/Resources/TriageCopilotHelper`.
///    Embed the pinned official Copilot runtime beneath that service's Resources
///    directory, never from `PATH`.
/// 2. Make the app embed and sign the XPC service, helper, and runtime with the
///    same release team. The service validates the helper with
///    Security.framework `SecStaticCode` against exact team and bundle
///    identifiers before launching it.
/// 3. Construct an `NSXPCConnection` to the fixed
///    `com.triage.mac.TriageCopilotXPC` Mach service and adapt it to
///    `CopilotXPCFrameService` with `CopilotXPCServiceClient`, then pass a
///    `CopilotXPCFrameTransport` to `CopilotHelperClient`. Configure both
///    interfaces with `TriageCopilotHelper`.
/// 4. Preserve the service environment allowlist, private empty working
///    directory, size limits, deadline, and single-flight policy.
///    Do not add shell invocation, inherited environment, a fallback executable,
///    TCP listener, or ambient credentials.
/// 5. Add the service/helper/runtime artifacts to release architecture,
///    code-signature, notarization, Sparkle, and private-data deletion checks.
enum CopilotXPCPackaging {}
