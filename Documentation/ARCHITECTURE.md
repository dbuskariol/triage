# Triage Architecture

Triage currently contains only the application shell. Product architecture will be added after the product definition is known.

## Baseline boundaries

- `TriageApp` owns scene composition and long-lived application objects.
- `AppNavigationModel` owns sidebar and Settings navigation.
- `AppPreferences` owns durable macOS integration preferences.
- `SoftwareUpdateController` is the single boundary around Sparkle.
- Views contain presentation and route actions through those shared objects.

The shell uses Swift 6 strict concurrency. UI state and framework objects are main-actor isolated. No domain persistence, background work, permissions, telemetry, or data collection exists. Network access is limited to signed Sparkle update checks.

The privacy manifest declares the app-private `UserDefaults` required-reason API and no tracking or collected data.

## Distribution

The shipping artifact is a universal macOS 26 application. Release scripts require Hardened Runtime, timestamped Developer ID signatures, notarization, stapling, Gatekeeper acceptance, Sparkle EdDSA signatures, signed feeds, pre-extraction verification, checksums, and source-linked release evidence.
