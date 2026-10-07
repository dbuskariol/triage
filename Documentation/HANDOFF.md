# Current-state handoff

Triage is AI-first personal-work triage. The current path is GitHub GraphQL relationship discovery → `GRDBTriageStore` → `TriageEngine` → `CopilotTriageDecider` → Workspace views.

The Rust helper accepts only `health`, `authenticate`, `models`, `triage`, `cancel`, and `shutdown`. No legacy inference operations remain.

Keep changes local-first and fail-closed. Do not reintroduce the old synchronization engine, evidence/receipt pipeline, or derived-intelligence architecture.
