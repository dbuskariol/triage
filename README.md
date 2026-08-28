# Triage

Triage is an intentionally empty, production-ready native macOS application shell.

The baseline follows the same engineering and distribution conventions as Reccy:

- Swift 6 and SwiftUI for macOS 26
- Native window, sidebar, Settings scene, menus, and menu-bar extra
- Launch-at-login and menu-bar preferences
- Sparkle automatic update controls and signed feed verification
- Privacy manifest with no tracking or collected data
- Universal Apple silicon and Intel release builds
- Hardened Runtime, Developer ID signing, notarization, signed DMG and ZIP packaging
- Apple silicon and Intel GitHub Actions verification

## Open

```sh
open Triage.xcodeproj
```

## Verify

```sh
scripts/verify-ci.sh
```

The checked-in Swift package mirrors the app target so command-line environments can run `swift test`; the Xcode project remains the shipping app definition.

Product behavior is deliberately absent until its purpose and requirements are defined.
