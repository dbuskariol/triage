# Triage Copilot Helper

This is a local, stdin/stdout-only Rust boundary for future Triage Copilot
analysis. It deliberately ships with no bundled Copilot CLI/runtime, so the
current executable accepts protocol requests but reports models and analysis as
`runtime_unavailable`. It never fabricates analysis output.

## Security boundary

- No TCP listener, shell, filesystem API, network client, MCP configuration,
  agent, skill, or tool registration.
- The environment allowlist contains only `LANG`, `LC_ALL`, `LC_CTYPE`, and
  `TZ`; credential and ambient CLI variables are excluded.
- The official `github-copilot-sdk` is pinned and its documented
  `SessionConfig` plus `DenyAllHandler` API is used by `ZeroToolPolicy`.
  It explicitly supplies empty client tools and `available_tools`, disables
  configuration discovery, skills, MCP apps, file hooks, host Git operations,
  session persistence, telemetry, and custom-instruction discovery.
- The SDK's CLI startup is intentionally isolated behind `CopilotEngine`.
  Integration can occur only after Triage packages a signed, explicit runtime
  path and verifies its credential storage. It must pass the sanitized
  environment, an empty private working directory, no tools/MCP, an ephemeral
  zeroized credential buffer, and use `abort` for cancellation.
- The helper has no credential persistence API. Credentials are absent from
  the protocol and `EphemeralCredential` zeroizes its in-memory buffer.

## Protocol

Each message is one big-endian unsigned 32-bit byte length followed by exactly
that many UTF-8 JSON bytes. Requests require `protocol_version: 1`,
`request_id` (UUID), and `organization_id` (UUID), plus one and only one
operation:

`health`, `models`, `analyze`, `cancel`, or `shutdown`.

Requests over 1 MiB and serialized responses over 256 KiB are rejected.
Serde rejects unknown fields. Candidate content is bounded and explicitly
marked untrusted. Analysis output is independently validated against supplied
evidence: unknown or duplicate IDs, invalid confidence, oversized text,
Markdown fences, and unevidenced deadlines are rejected.

`analyze` is limited to one concurrent request. `cancel` records cancellation
state and forwards it to the engine; a real engine must observe that state and
abort its SDK session. `shutdown` cancels active work before it exits.

Example health request JSON (before framing):

```json
{
  "protocol_version": 1,
  "request_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "organization_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "operation": "health"
}
```

## Development

```sh
cargo fmt --check
cargo test
```

`Cargo.lock` is committed to pin the complete dependency graph.
