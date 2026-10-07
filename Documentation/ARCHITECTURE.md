# Triage Architecture

Triage is a local-first native macOS application. `Triage/Core` defines its contracts and contains the personal-work GitHub GraphQL discovery path, `GRDBTriageStore`, `CopilotTriageDecider`, `TriageEngine`, and workspace presentation model.

Discovery searches GitHub GraphQL per relationship. The engine stores the resulting local workspace, sends bounded personal-work items through the authenticated Copilot helper's single `triage` operation, and publishes workspace presentation for `Triage/Views/Workspace`. The app has no legacy synchronization engine, evidence-receipt pipeline, or derived-intelligence subsystem.

The helper is fail-closed: health, authenticate, models, triage, cancel, and shutdown are its only operations. It has no tools, MCP, filesystem, or network capability beyond the pinned Copilot runtime.

## Distribution

The shipping artifact is a universal macOS 26 application. Release scripts require Hardened Runtime, timestamped Developer ID signatures, notarization, stapling, Gatekeeper acceptance, Sparkle EdDSA signatures, signed feeds, pre-extraction verification, checksums, and source-linked release evidence.
