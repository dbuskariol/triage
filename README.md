# Triage

Triage is a native, local-first macOS application for AI-assisted GitHub personal-work triage. It uses Swift 6, SwiftUI, GRDB/SQLCipher, and a fail-closed Rust Copilot helper.

## Architecture

- `Triage/Core`: contracts, GitHub personal-work discovery, local GRDB storage, the `TriageEngine` loop, Copilot triage decisioning, and workspace presentation.
- `Triage/Views/Workspace`: the native SwiftUI workspace.
- `Triage/CopilotXPC` and `TriageCopilotHelper`: authenticated helper boundary. Its only inference operation is `triage`.

## Open

```sh
open Triage.xcodeproj
```

## Verify

```sh
scripts/verify-ci.sh
```

The checked-in Swift package mirrors the app target for command-line `swift test`; the Xcode project is the shipping app definition.
