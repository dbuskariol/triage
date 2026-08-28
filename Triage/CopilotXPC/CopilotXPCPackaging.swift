/// Packaging requirements for enabling the Copilot XPC boundary.
///
/// This code is intentionally compiled in the app target until the service
/// target exists. It does not launch an arbitrary command and its default
/// code-signature validator fails closed.
///
/// 1. Add a `TriageCopilotXPC` XPC Service target with its own Hardened Runtime
///    entitlement file. Its exported interface must be `TriageCopilotHelper`;
///    it accepts and returns only `CopilotFrameCodec` frames.
/// 2. Embed the signed universal helper at
///    `Triage.app/Contents/XPCServices/TriageCopilotXPC.xpc/Contents/Resources/TriageCopilotHelper`.
///    Embed the pinned official Copilot runtime beneath that service's Resources
///    directory, never from `PATH`.
/// 3. Make the app embed and sign the XPC service, helper, and runtime with the
///    same release team. Replace `UnconfiguredCopilotCodeSignatureValidator`
///    with a Security.framework `SecStaticCode` validator against exact team
///    and bundle identifiers before launching the helper.
/// 4. Construct an `NSXPCConnection` to the fixed
///    `com.triage.mac.TriageCopilotXPC` Mach service and adapt it to
///    `CopilotXPCFrameService` with `CopilotXPCServiceClient`, then pass a
///    `CopilotXPCFrameTransport` to `CopilotHelperClient`. Configure both
///    interfaces with `TriageCopilotHelper`.
/// 5. In the service, use `CopilotHelperLaunchConfiguration.make()` and
///    `FoundationCopilotHelperLauncher`. Preserve the environment allowlist,
///    empty working directory, size limits, deadline, and single-flight policy.
///    Do not add shell invocation, inherited environment, a fallback executable,
///    TCP listener, or ambient credentials.
/// 6. Add the service/helper/runtime artifacts to release architecture,
///    code-signature, notarization, Sparkle, and private-data deletion checks.
enum CopilotXPCPackaging {}
