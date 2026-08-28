# Releasing Triage

Triage ships outside the Mac App Store as a universal, hardened, Developer ID-signed and notarized app. Sparkle verifies both the signed appcast and EdDSA-signed update archive before extraction.

`scripts/release.sh` is the single release entry point. Local and GitHub releases use the same fail-closed validators.

## Local rehearsal

The initial Sparkle private key is stored outside the repository at:

```text
~/Library/Application Support/Triage/Release/sparkle-private-key
```

Back it up in an approved secret manager before the first release. Never commit it.

After updating the version, build number, and release notes, commit the source and run:

```sh
TRIAGE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TRIAGE_DEVELOPMENT_TEAM="TEAMID" \
TRIAGE_SPARKLE_PRIVATE_KEY_FILE="$HOME/Library/Application Support/Triage/Release/sparkle-private-key" \
scripts/release.sh prepare
```

This builds and verifies the complete artifact graph without contacting Apple's notarization service or publishing a release.

## Final release

Create and check out the exact `v<MARKETING_VERSION>` tag only after CI and signed-app acceptance are green:

```sh
TRIAGE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TRIAGE_DEVELOPMENT_TEAM="TEAMID" \
TRIAGE_NOTARY_KEYCHAIN_PROFILE="Triage Notary" \
TRIAGE_SPARKLE_PRIVATE_KEY_FILE="$HOME/Library/Application Support/Triage/Release/sparkle-private-key" \
scripts/release.sh finalize
```

The final flow notarizes and staples the app and DMG, verifies Gatekeeper and Sparkle signatures, and produces ZIP, DMG, appcast, release notes, checksums, manifest, dSYM, and notarization evidence under `dist/`.

## GitHub Actions

Release automation is fail-closed behind `TRIAGE_RELEASE_AUTOMATION_ENABLED=true` and requires the protected `release` environment plus:

- `DEVELOPER_ID_P12_BASE64`
- `DEVELOPER_ID_P12_PASSWORD`
- `APPLE_DEVELOPMENT_TEAM`
- `APP_STORE_CONNECT_KEY_P8_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY_BASE64`
