# Triage Copilot Helper

This is a local, stdin/stdout-only Rust boundary for Triage Copilot analysis.
Its v2 protocol binds every decoded operation and response/failure to one
canonical `account_id` and `organization_id`. It never fabricates analysis.

## Security boundary

- No TCP listener, shell, filesystem API, network client, MCP configuration,
  agent, skill, or tool registration.
- The environment allowlist contains only `LANG`, `LC_ALL`, `LC_CTYPE`, and
  `TZ`; credential and ambient CLI variables are excluded. The helper never
  reads `PATH`, `COPILOT_CLI_PATH`, `COPILOT_HOME`, a cache resolver, or a home
  directory to locate a runtime.
- The official `github-copilot-sdk` is pinned and its documented
  `SessionConfig` plus `DenyAllHandler` API is used by `ZeroToolPolicy`.
  It explicitly supplies empty client tools and `available_tools`, disables
  configuration discovery, skills, MCP apps, file hooks, host Git operations,
  session persistence, telemetry, and custom-instruction discovery.
- The helper accepts no launch arguments and no path-bearing environment
  values. Its only runtime handoff is the first bounded, length-framed stdin
  bootstrap from XPC: four XPC-verified absolute paths for the CLI, shared
  runtime lock, private base directory, and private working directory. The
  helper re-canonicalizes them, requires private directories, acquires the
  shared `.runtime.lock`, and keeps that lock for its process lifetime. SDK
  options are pinned to
  `CliProgram::Path`, `Transport::Stdio`, private base/work directories, and
  `ClientMode::Empty`; ZeroToolPolicy/DenyAll disables tools, MCP, skills,
  config discovery, session storage, telemetry, file hooks, and Git hooks.
- The helper has no credential persistence API. `authenticate` is the sole
  credential-bearing v2 operation: its bounded token arrives only in the
  length-framed stdin payload, becomes an `EphemeralCredential`, and cannot be
  serialized or printed. The SDK's documented `github_token` flow injects it
  only into the verified child as `COPILOT_SDK_AUTH_TOKEN`; arguments contain
  only that variable's name. `use_logged_in_user` is false, so ambient `gh`,
  Keytar, and device-login fallback remain unavailable. The request buffer is
  zeroized after client start and no response/failure includes a token.
- `.cargo/config.toml` force-sets `COPILOT_SKIP_CLI_DOWNLOAD=1`, preventing
  the SDK build script from downloading, bundling, or caching a CLI.

## Protocol

Each message is one big-endian unsigned 32-bit byte length followed by exactly
that many UTF-8 JSON bytes. Requests require `protocol_version: 2`,
`request_id` (UUID), `account_id`, and `organization_id`, plus one and only one
operation: `health`, `models`, `analyze`, `authenticate`, `cancel`, or
`shutdown`.

Requests over 1 MiB and serialized responses over 256 KiB are rejected.
Serde rejects unknown fields. The `analyze` shape exactly matches Swift:
`model_id`, `input`, and `deadline`; its input/output byte limits and evidence
checks match `CopilotXPCProtocol.swift`. Analysis output cannot invent or
duplicate evidence, use invalid confidence, exceed bounded text, or contain
Markdown fences where Swift rejects them.

`analyze` is limited to one concurrent request. `cancel` records cancellation
state and forwards it to the engine; a real engine must observe that state and
abort its SDK session. `shutdown` cancels active work before it exits.

`authenticate` accepts only `credential`; it never accepts a host or login
claim. After `auth.getStatus`, the helper returns the verified credential-free
identity as `status: "authentication"` with
`authentication: { host, login, auth_type, is_authenticated }`, bound to the
same account and organization headers. Cancellation and shutdown stop the SDK
child; classic device login is not supported.

Example health request JSON (before framing):

```json
{
  "protocol_version": 2,
  "request_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "account_id": "account-1",
  "organization_id": "organization-1",
  "operation": "health"
}
```

## Development

```sh
cargo fmt --check
cargo test
```

`Cargo.lock` is committed to pin the complete dependency graph.
