use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use github_copilot_sdk::{SessionConfig, handler::DenyAllHandler};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

use crate::{
    protocol::{Failure, FailureCode, HealthResponse, ModelDescriptor},
    schema::{AnalysisOutput, CandidateInput},
};

/// The only capability policy accepted by Triage.
///
/// No tools are registered, MCP is never configured, and the SDK's documented
/// `DenyAllHandler` rejects any runtime permission request that still arrives.
#[derive(Clone, Debug, Default)]
pub struct ZeroToolPolicy;

impl ZeroToolPolicy {
    pub const fn tool_names(&self) -> &'static [&'static str] {
        &[]
    }

    pub const fn mcp_enabled(&self) -> bool {
        false
    }

    pub fn sdk_session_config(&self) -> SessionConfig {
        let mut config = SessionConfig::default().with_permission_handler(Arc::new(DenyAllHandler));
        config.tools = Some(Vec::new());
        config.available_tools = Some(Vec::new());
        config.enable_config_discovery = Some(false);
        config.enable_file_hooks = Some(false);
        config.enable_host_git_operations = Some(false);
        config.enable_session_store = Some(false);
        config.enable_skills = Some(false);
        config.enable_mcp_apps = Some(false);
        config.enable_session_telemetry = Some(false);
        config.enable_file_change_tracking = Some(false);
        config.skip_custom_instructions = Some(true);
        config.enable_on_demand_instruction_discovery = Some(false);
        config
    }
}

/// Credentials may only exist in a caller-owned, zeroized ephemeral buffer.
///
/// This helper's public IPC does not carry credentials and this type has no
/// persistence or filesystem API.
pub struct EphemeralCredential(Zeroizing<String>);

impl EphemeralCredential {
    pub fn new(value: String) -> Self {
        Self(Zeroizing::new(value))
    }

    pub fn expose_for_sdk(&self) -> &str {
        &self.0
    }
}

impl Drop for EphemeralCredential {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

#[derive(Clone, Debug, Default)]
pub struct CancellationState {
    inner: Arc<Mutex<CancellationSet>>,
}

#[derive(Debug, Default)]
struct CancellationSet {
    active: HashSet<Uuid>,
    cancelled: HashSet<Uuid>,
}

impl CancellationState {
    pub fn begin(&self, request_id: Uuid) -> bool {
        let mut state = self.inner.lock().expect("cancellation state lock poisoned");
        state.cancelled.remove(&request_id);
        state.active.insert(request_id)
    }

    pub fn finish(&self, request_id: Uuid) {
        let mut state = self.inner.lock().expect("cancellation state lock poisoned");
        state.active.remove(&request_id);
        state.cancelled.remove(&request_id);
    }

    pub fn cancel(&self, request_id: Uuid) -> bool {
        let mut state = self.inner.lock().expect("cancellation state lock poisoned");
        if state.active.contains(&request_id) {
            state.cancelled.insert(request_id);
            true
        } else {
            false
        }
    }

    pub fn cancel_all(&self) {
        let mut state = self.inner.lock().expect("cancellation state lock poisoned");
        let active: Vec<_> = state.active.iter().copied().collect();
        state.cancelled.extend(active);
    }

    pub fn is_cancelled(&self, request_id: Uuid) -> bool {
        self.inner
            .lock()
            .expect("cancellation state lock poisoned")
            .cancelled
            .contains(&request_id)
    }
}

#[async_trait]
pub trait CopilotEngine: Send + Sync + 'static {
    async fn health(&self) -> Result<HealthResponse, Failure>;
    async fn models(&self) -> Result<Vec<ModelDescriptor>, Failure>;
    async fn analyze(
        &self,
        request_id: Uuid,
        candidate: CandidateInput,
        selected_model: Option<String>,
        cancellation: CancellationState,
    ) -> Result<AnalysisOutput, Failure>;
    async fn cancel(&self, request_id: Uuid) -> Result<(), Failure>;
    async fn shutdown(&self) -> Result<(), Failure>;
}

/// Secure default until a signed, bundled CLI/runtime path is packaged.
///
/// The official SDK is deliberately linked for its `SessionConfig` and
/// `DenyAllHandler` APIs above.  Starting `Client::start` is deferred: with
/// `default-features = false` it would need an explicit bundled CLI path, and
/// this scaffold must not discover a CLI, use PATH, or invoke an external one.
#[derive(Clone, Debug, Default)]
pub struct UnavailableCopilotEngine;

#[async_trait]
impl CopilotEngine for UnavailableCopilotEngine {
    async fn health(&self) -> Result<HealthResponse, Failure> {
        Ok(HealthResponse {
            helper_version: env!("CARGO_PKG_VERSION").to_owned(),
            copilot_available: false,
            tool_policy: "deny_all".to_owned(),
        })
    }

    async fn models(&self) -> Result<Vec<ModelDescriptor>, Failure> {
        Err(runtime_unavailable())
    }

    async fn analyze(
        &self,
        _request_id: Uuid,
        _candidate: CandidateInput,
        _selected_model: Option<String>,
        _cancellation: CancellationState,
    ) -> Result<AnalysisOutput, Failure> {
        Err(runtime_unavailable())
    }

    async fn cancel(&self, _request_id: Uuid) -> Result<(), Failure> {
        Ok(())
    }

    async fn shutdown(&self) -> Result<(), Failure> {
        Ok(())
    }
}

fn runtime_unavailable() -> Failure {
    Failure::new(
        FailureCode::RuntimeUnavailable,
        "Copilot runtime is not bundled in this build",
    )
}

#[cfg(test)]
mod tests {
    use super::{CancellationState, ZeroToolPolicy};
    use uuid::Uuid;

    #[test]
    fn cancellation_only_targets_active_requests() {
        let state = CancellationState::default();
        let request_id = Uuid::new_v4();
        assert!(!state.cancel(request_id));
        assert!(state.begin(request_id));
        assert!(state.cancel(request_id));
        assert!(state.is_cancelled(request_id));
        state.finish(request_id);
        assert!(!state.is_cancelled(request_id));
    }

    #[test]
    fn zero_tool_policy_cannot_enable_tools_or_mcp() {
        let policy = ZeroToolPolicy;
        assert!(policy.tool_names().is_empty());
        assert!(!policy.mcp_enabled());
        let sdk_config = policy.sdk_session_config();
        assert!(sdk_config.tools.as_ref().is_some_and(Vec::is_empty));
        assert_eq!(sdk_config.available_tools, Some(Vec::new()));
        assert_eq!(sdk_config.enable_config_discovery, Some(false));
        assert_eq!(sdk_config.enable_mcp_apps, Some(false));
        assert_eq!(sdk_config.enable_skills, Some(false));
    }
}
