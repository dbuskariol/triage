# AGENTS.md

This file is the repository-wide operating guide for coding agents working on Triage. Direct user instructions always take precedence.

## Product state

Triage is a local-first AI-assisted GitHub personal-work triage app. Preserve its Core discovery/store/AI/engine boundaries and native Workspace views.

Preserve these baseline invariants:

- Native macOS 26 app built with Swift 6, SwiftUI, and AppKit only where Mac-specific behavior requires it.
- Local-first and privacy-preserving. Do not add telemetry, analytics, advertising, tracking, or uploaded diagnostics.
- Universal `arm64` and `x86_64` Developer ID distribution with Hardened Runtime, notarization, and Sparkle update verification.
- Standard Mac windows, menus, Settings, menu-bar behavior, keyboard navigation, accessibility, appearance, and state restoration.
- Third-party dependencies require a concrete need. Sparkle and the
  version-locked GRDB/SQLCipher vault are the only baseline dependencies.

## Repository map

- `Triage/Core`: contracts, GitHub personal-work discovery, GRDB store, AI triage, engine, and presentation.
- `Triage/CopilotXPC` and `TriageCopilotHelper`: fail-closed authenticated Copilot helper; `triage` is its only inference operation.
- `Triage/Views/Workspace`: SwiftUI workspace surfaces.
- `Triage/Models` and `Triage/Services`: app state, preferences, and platform services.
- `TriageTests`: deterministic unit tests.
- `Package.swift`: command-line compilation and test mirror.
- `Configuration`: bundle metadata.
- `Documentation`: architecture and release operations.
- `scripts`: verification and fail-closed release automation.
- `.github/workflows`: Apple silicon and Intel CI plus guarded release automation.

## Working in the checkout

- Search before introducing abstractions or dependencies.
- Keep Swift 6 strict-concurrency checks clean.
- Prefer current Apple frameworks and system controls.
- Keep user-facing errors explicit and actionable.
- Add tests for behavior changes.
- Keep generated products and DerivedData outside the repository.
- Never commit signing keys, certificates, notarization credentials, or release secrets.

## Verification

Run:

```sh
scripts/verify-ci.sh
```

For UI changes, also exercise the built app with keyboard, pointer, VoiceOver semantics, resizing, light/dark appearance, and the menu bar.

## Release safety

`scripts/release.sh prepare` is a non-publishing rehearsal. `scripts/release.sh finalize` contacts Apple and requires the exact clean `v<version>` tag. Do not finalize, tag, push, publish, enable release automation, or rotate credentials without explicit user approval.
