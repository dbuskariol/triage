use std::sync::Arc;
use std::{
    io::{self, Read, Write},
    path::PathBuf,
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::task::JoinSet;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::{
    engine::{
        AuthenticationResponse, CancellationScope, CancellationState, CopilotEngine,
        EphemeralCredential, TrustedRuntimeBootstrap,
    },
    schema::{
        TriageItem, TriageItemDecision, ValidationError, retain_valid_triage_outputs,
        validate_draft_inputs, validate_triage_inputs, validate_triage_instructions,
    },
};

/// Must stay in lockstep with `CopilotIPC.version`.
pub const PROTOCOL_VERSION: u16 = 2;
pub const MAX_REQUEST_BYTES: usize = 1_024 * 1_024;
pub const MAX_RESPONSE_BYTES: usize = 256 * 1_024;
pub const BOOTSTRAP_VERSION: u16 = 1;
pub const MAX_BOOTSTRAP_BYTES: usize = 16 * 1_024;

/// Reads the one anonymous-pipe bootstrap that must precede every protocol
/// request. It is deliberately length-framed and schema-bound so arguments or
/// inherited environment can never select a runtime or profile directory.
pub fn read_trusted_runtime_bootstrap<R: Read>(
    reader: &mut R,
) -> Result<TrustedRuntimeBootstrap, ProtocolError> {
    let payload = read_frame(reader, MAX_BOOTSTRAP_BYTES)?.ok_or(ProtocolError::InvalidFrame)?;
    let bootstrap: TrustedRuntimeBootstrapWire =
        serde_json::from_slice(&payload).map_err(|_| {
            ProtocolError::InvalidRequest(ValidationError::new("invalid runtime bootstrap"))
        })?;
    if bootstrap.version != BOOTSTRAP_VERSION {
        return Err(ProtocolError::InvalidRequest(ValidationError::new(
            "unsupported runtime bootstrap",
        )));
    }
    Ok(TrustedRuntimeBootstrap {
        cli_path: bounded_absolute_path(bootstrap.executable_path)?,
        runtime_lock_path: bounded_absolute_path(bootstrap.runtime_lock_path)?,
        base_directory: bounded_absolute_path(bootstrap.base_directory_path)?,
        working_directory: bounded_absolute_path(bootstrap.working_directory_path)?,
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TrustedRuntimeBootstrapWire {
    version: u16,
    executable_path: String,
    runtime_lock_path: String,
    base_directory_path: String,
    working_directory_path: String,
}

fn bounded_absolute_path(value: String) -> Result<PathBuf, ProtocolError> {
    if value.is_empty() || value.len() > 4_096 || value.contains('\0') {
        return Err(ProtocolError::InvalidRequest(ValidationError::new(
            "invalid runtime bootstrap",
        )));
    }
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        return Err(ProtocolError::InvalidRequest(ValidationError::new(
            "invalid runtime bootstrap",
        )));
    }
    Ok(path)
}

#[derive(Debug, Serialize)]
pub struct WireRequest {
    pub protocol_version: u16,
    pub request_id: Uuid,
    pub account_id: String,
    pub organization_id: String,
    #[serde(flatten)]
    pub operation: RequestOperation,
}

impl WireRequest {
    pub fn validate(&self) -> Result<(), ProtocolError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion);
        }
        validate_identifier(&self.account_id, "account_id")?;
        validate_identifier(&self.organization_id, "organization_id")?;
        match &self.operation {
            RequestOperation::Triage {
                viewer_login,
                items,
                instructions,
                reasoning_effort,
                context_tier,
                ..
            } => {
                validate_model_options(reasoning_effort.as_deref(), context_tier.as_deref())?;
                validate_triage_inputs(viewer_login, items)
                    .map_err(ProtocolError::InvalidRequest)?;
                validate_triage_instructions(instructions.as_deref())
                    .map_err(ProtocolError::InvalidRequest)?;
            }
            RequestOperation::Draft {
                viewer_login,
                item,
                goal,
                writing_style,
                reasoning_effort,
                context_tier,
                ..
            } => {
                validate_model_options(reasoning_effort.as_deref(), context_tier.as_deref())?;
                validate_draft_inputs(
                    viewer_login,
                    item,
                    goal.as_deref(),
                    writing_style.as_deref(),
                )
                .map_err(ProtocolError::InvalidRequest)?;
            }
            _ => {}
        }
        if let RequestOperation::Authenticate {
            credential: Some(credential),
            ..
        } = &self.operation
        {
            credential.validate().map_err(|_| {
                ProtocolError::InvalidRequest(ValidationError::new("credential is invalid"))
            })?;
        }
        Ok(())
    }
}

fn validate_model_options(
    reasoning_effort: Option<&str>,
    context_tier: Option<&str>,
) -> Result<(), ProtocolError> {
    let invalid_effort = reasoning_effort.is_some_and(|value| {
        value.is_empty()
            || value.len() > 16
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte == b'_')
    });
    let invalid_tier =
        context_tier.is_some_and(|value| !matches!(value, "default" | "long_context"));
    if invalid_effort || invalid_tier {
        return Err(ProtocolError::InvalidRequest(ValidationError::new(
            "model options are invalid",
        )));
    }
    Ok(())
}

#[derive(Debug, Serialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum RequestOperation {
    Health,
    Models,
    Triage {
        #[serde(skip_serializing_if = "Option::is_none")]
        model_id: Option<String>,
        viewer_login: String,
        items: Vec<TriageItem>,
        deadline: DateTime<Utc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        instructions: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reasoning_effort: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        context_tier: Option<String>,
    },
    Draft {
        #[serde(skip_serializing_if = "Option::is_none")]
        model_id: Option<String>,
        viewer_login: String,
        item: Box<TriageItem>,
        deadline: DateTime<Utc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        goal: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        writing_style: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        reasoning_effort: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        context_tier: Option<String>,
    },
    Authenticate {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        credential: Option<EphemeralCredential>,
        allow_browser: bool,
    },
    Cancel {
        target_request_id: Uuid,
    },
    Shutdown,
}

// Decoding is deliberately per-operation rather than through serde_json::Value.
// In particular, authenticate receives a token and must not leave a generic
// JSON tree or ordinary payload buffer holding it after this function returns.
#[derive(Deserialize)]
struct OperationProbe<'a> {
    #[serde(borrow)]
    operation: &'a str,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HeaderRequest {
    protocol_version: u16,
    request_id: Uuid,
    account_id: String,
    organization_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TriageRequest {
    #[serde(flatten)]
    header: HeaderRequest,
    operation: TriageOperation,
    model_id: Option<String>,
    viewer_login: String,
    items: Vec<TriageItem>,
    deadline: DateTime<Utc>,
    #[serde(default)]
    instructions: Option<String>,
    #[serde(default)]
    reasoning_effort: Option<String>,
    #[serde(default)]
    context_tier: Option<String>,
}
#[derive(Deserialize)]
enum TriageOperation {
    #[serde(rename = "triage")]
    Triage,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DraftWireRequest {
    #[serde(flatten)]
    header: HeaderRequest,
    operation: DraftOperation,
    model_id: Option<String>,
    viewer_login: String,
    item: TriageItem,
    deadline: DateTime<Utc>,
    #[serde(default)]
    goal: Option<String>,
    #[serde(default)]
    writing_style: Option<String>,
    #[serde(default)]
    reasoning_effort: Option<String>,
    #[serde(default)]
    context_tier: Option<String>,
}
#[derive(Deserialize)]
enum DraftOperation {
    #[serde(rename = "draft")]
    Draft,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthenticateRequest {
    #[serde(flatten)]
    header: HeaderRequest,
    operation: AuthenticateOperation,
    credential: Option<EphemeralCredential>,
    #[serde(default)]
    allow_browser: bool,
}

#[derive(Deserialize)]
enum AuthenticateOperation {
    #[serde(rename = "authenticate")]
    Authenticate,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CancelRequest {
    #[serde(flatten)]
    header: HeaderRequest,
    operation: CancelOperation,
    target_request_id: Uuid,
}

#[derive(Deserialize)]
enum CancelOperation {
    #[serde(rename = "cancel")]
    Cancel,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SimpleRequest {
    #[serde(flatten)]
    header: HeaderRequest,
    operation: SimpleOperation,
}

#[derive(Deserialize)]
enum SimpleOperation {
    #[serde(rename = "health")]
    Health,
    #[serde(rename = "models")]
    Models,
    #[serde(rename = "shutdown")]
    Shutdown,
}

/// Every emitted response, including every failure, is tied to the exact
/// account and organization of one decoded request. A malformed frame cannot
/// safely claim an identity, so the helper terminates the stream rather than
/// emitting an unbound failure envelope.
#[derive(Clone, Debug, Serialize)]
pub struct WireResponse {
    pub protocol_version: u16,
    pub request_id: Uuid,
    pub account_id: String,
    pub organization_id: String,
    #[serde(flatten)]
    pub result: ResponseResult,
}

impl WireResponse {
    fn for_request(request: &WireRequest, result: ResponseResult) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id: request.request_id,
            account_id: request.account_id.clone(),
            organization_id: request.organization_id.clone(),
            result,
        }
    }

    fn failure(request: &WireRequest, failure: Failure) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id: request.request_id,
            account_id: request.account_id.clone(),
            organization_id: request.organization_id.clone(),
            result: ResponseResult::Failure { failure },
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ResponseResult {
    Health {
        health: HealthResponse,
    },
    Models {
        models: Vec<ModelDescriptor>,
    },
    Triage {
        model_id: String,
        decisions: Vec<TriageItemDecision>,
    },
    Draft {
        model_id: String,
        draft: String,
    },
    Authentication {
        authentication: AuthenticationResponse,
    },
    Cancelled {
        cancelled_request_id: Uuid,
    },
    Shutdown,
    Failure {
        failure: Failure,
    },
}

#[derive(Clone, Debug, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HealthResponse {
    pub helper_version: String,
    pub copilot_available: bool,
    pub tool_policy: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ModelDescriptor {
    pub id: String,
    pub display_name: String,
    pub is_default: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub supported_reasoning_efforts: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
    pub supports_long_context: bool,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureCode {
    InvalidFrame,
    RequestTooLarge,
    InvalidRequest,
    UnsupportedVersion,
    ValidationFailed,
    RuntimeUnavailable,
    AuthenticationFailed,
    Cancelled,
    Busy,
    ShuttingDown,
    Internal,
}

#[derive(Clone, Debug, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Failure {
    pub code: FailureCode,
    pub message: String,
}

impl Failure {
    pub fn new(code: FailureCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("invalid frame")]
    InvalidFrame,
    #[error("request exceeds maximum size")]
    RequestTooLarge,
    #[error("response exceeds maximum size")]
    ResponseTooLarge,
    #[error("invalid request")]
    InvalidRequest(ValidationError),
    #[error("unsupported protocol version")]
    UnsupportedVersion,
    #[error("I/O error")]
    Io(#[from] io::Error),
    #[error("JSON encoding error")]
    Json(#[from] serde_json::Error),
}

pub fn read_request<R: Read>(reader: &mut R) -> Result<Option<WireRequest>, ProtocolError> {
    let Some(payload) = read_frame(reader, MAX_REQUEST_BYTES)? else {
        return Ok(None);
    };
    let request = decode_request(&payload)?;
    request.validate()?;
    Ok(Some(request))
}

fn decode_request(payload: &[u8]) -> Result<WireRequest, ProtocolError> {
    let operation = serde_json::from_slice::<OperationProbe<'_>>(payload)
        .map_err(|_| {
            ProtocolError::InvalidRequest(ValidationError::new("request failed schema validation"))
        })?
        .operation;
    match operation {
        "health" | "models" | "shutdown" => {
            let request: SimpleRequest = decode_typed(payload)?;
            let operation = match request.operation {
                SimpleOperation::Health => RequestOperation::Health,
                SimpleOperation::Models => RequestOperation::Models,
                SimpleOperation::Shutdown => RequestOperation::Shutdown,
            };
            Ok(WireRequest {
                protocol_version: request.header.protocol_version,
                request_id: request.header.request_id,
                account_id: request.header.account_id,
                organization_id: request.header.organization_id,
                operation,
            })
        }
        "triage" => {
            if payload.len() > 120 * 1024 {
                return Err(ProtocolError::InvalidRequest(ValidationError::new(
                    "triage request exceeds 120 KiB",
                )));
            }
            let request: TriageRequest = decode_typed(payload)?;
            let TriageOperation::Triage = request.operation;
            Ok(WireRequest {
                protocol_version: request.header.protocol_version,
                request_id: request.header.request_id,
                account_id: request.header.account_id,
                organization_id: request.header.organization_id,
                operation: RequestOperation::Triage {
                    model_id: request.model_id,
                    viewer_login: request.viewer_login,
                    items: request.items,
                    deadline: request.deadline,
                    instructions: request.instructions,
                    reasoning_effort: request.reasoning_effort,
                    context_tier: request.context_tier,
                },
            })
        }
        "draft" => {
            if payload.len() > 32 * 1024 {
                return Err(ProtocolError::InvalidRequest(ValidationError::new(
                    "draft request exceeds 32 KiB",
                )));
            }
            let request: DraftWireRequest = decode_typed(payload)?;
            let DraftOperation::Draft = request.operation;
            Ok(WireRequest {
                protocol_version: request.header.protocol_version,
                request_id: request.header.request_id,
                account_id: request.header.account_id,
                organization_id: request.header.organization_id,
                operation: RequestOperation::Draft {
                    model_id: request.model_id,
                    viewer_login: request.viewer_login,
                    item: Box::new(request.item),
                    deadline: request.deadline,
                    goal: request.goal,
                    writing_style: request.writing_style,
                    reasoning_effort: request.reasoning_effort,
                    context_tier: request.context_tier,
                },
            })
        }
        "authenticate" => {
            let mut request: AuthenticateRequest = decode_typed(payload)?;
            let AuthenticateOperation::Authenticate = request.operation;
            // Move the only secret-bearing field into its zeroizing owner.
            let credential = request.credential.take();
            Ok(WireRequest {
                protocol_version: request.header.protocol_version,
                request_id: request.header.request_id,
                account_id: request.header.account_id,
                organization_id: request.header.organization_id,
                operation: RequestOperation::Authenticate {
                    credential,
                    allow_browser: request.allow_browser,
                },
            })
        }
        "cancel" => {
            let request: CancelRequest = decode_typed(payload)?;
            let CancelOperation::Cancel = request.operation;
            Ok(WireRequest {
                protocol_version: request.header.protocol_version,
                request_id: request.header.request_id,
                account_id: request.header.account_id,
                organization_id: request.header.organization_id,
                operation: RequestOperation::Cancel {
                    target_request_id: request.target_request_id,
                },
            })
        }
        _ => Err(ProtocolError::InvalidRequest(ValidationError::new(
            "unsupported operation",
        ))),
    }
}

fn decode_typed<T: for<'de> Deserialize<'de>>(payload: &[u8]) -> Result<T, ProtocolError> {
    serde_json::from_slice(payload).map_err(|_| {
        ProtocolError::InvalidRequest(ValidationError::new("request failed schema validation"))
    })
}

pub fn write_response<W: Write>(
    writer: &mut W,
    response: &WireResponse,
) -> Result<(), ProtocolError> {
    let payload = serde_json::to_vec(response)?;
    if payload.len() > MAX_RESPONSE_BYTES {
        return Err(ProtocolError::ResponseTooLarge);
    }
    write_frame(writer, &payload)
}

fn read_frame<R: Read>(
    reader: &mut R,
    maximum: usize,
) -> Result<Option<Zeroizing<Vec<u8>>>, ProtocolError> {
    let mut first = [0_u8; 1];
    if reader.read(&mut first)? == 0 {
        return Ok(None);
    }
    let mut header = [0_u8; 4];
    header[0] = first[0];
    reader.read_exact(&mut header[1..])?;
    let length = u32::from_be_bytes(header) as usize;
    if length > maximum {
        return Err(ProtocolError::RequestTooLarge);
    }
    let mut payload = Zeroizing::new(vec![0_u8; length]);
    reader.read_exact(&mut payload)?;
    Ok(Some(payload))
}

fn write_frame<W: Write>(writer: &mut W, payload: &[u8]) -> Result<(), ProtocolError> {
    let length = u32::try_from(payload.len()).map_err(|_| ProtocolError::InvalidFrame)?;
    writer.write_all(&length.to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(())
}

fn validate_identifier(value: &str, field: &str) -> Result<(), ProtocolError> {
    if value.is_empty() || value.chars().any(char::is_whitespace) {
        return Err(ProtocolError::InvalidRequest(ValidationError::new(
            format!("{field} is invalid"),
        )));
    }
    Ok(())
}

fn cancellation_scope(request: &WireRequest) -> CancellationScope {
    CancellationScope::new(request.account_id.clone(), request.organization_id.clone())
}

fn is_control_operation(operation: &RequestOperation) -> bool {
    matches!(
        operation,
        RequestOperation::Cancel { .. } | RequestOperation::Shutdown
    )
}

async fn abort_analyses_and_shutdown<E: CopilotEngine>(
    engine: &E,
    analyses: &mut JoinSet<WireResponse>,
) -> Result<(), Failure> {
    analyses.abort_all();
    while analyses.join_next().await.is_some() {}
    // A dropped analysis future cannot run its async cleanup. Its active
    // session remains owned by the engine, so shutdown must drain it before a
    // malformed frame or explicit shutdown returns control to the OS.
    engine.shutdown().await
}

/// Runs one analysis at a time while retaining stdin availability for cancel.
/// `cancel` only touches a currently active request ID; it cannot mark a later
/// request cancelled or affect an already-finished one.
pub async fn serve_stdio<E: CopilotEngine>(engine: Arc<E>) -> Result<(), ProtocolError> {
    let (sender, mut receiver) = tokio::sync::mpsc::channel(8);
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut reader = stdin.lock();
        loop {
            match read_request(&mut reader) {
                Ok(Some(request)) => {
                    if sender
                        .blocking_send(ReaderEvent::Request(Box::new(request)))
                        .is_err()
                    {
                        return;
                    }
                }
                Ok(None) => return,
                Err(_) => {
                    if sender.blocking_send(ReaderEvent::Malformed).is_err() {
                        return;
                    }
                    return;
                }
            }
        }
    });

    let stdout = io::stdout();
    let mut writer = stdout.lock();
    let cancellation = CancellationState::default();
    let mut analyses = JoinSet::new();
    loop {
        tokio::select! {
            event = receiver.recv() => {
                let Some(event) = event else { break };
                match event {
                    ReaderEvent::Malformed => {
                        cancellation.cancel_all();
                        let _ = abort_analyses_and_shutdown(engine.as_ref(), &mut analyses).await;
                        break;
                    }
                    ReaderEvent::Request(mut request) => {
                        // Never let a queued models/auth/health operation wait
                        // behind the engine's analysis gate: that would stall
                        // the reader and prevent a later cancel or shutdown
                        // frame from being processed.
                        if !analyses.is_empty() && !is_control_operation(&request.operation) {
                            write_response(&mut writer, &WireResponse::failure(&request, Failure::new(FailureCode::Busy, "Only one analysis may run at a time")))?;
                            continue;
                        }
                        match &mut request.operation {
                        RequestOperation::Triage { model_id, viewer_login, items, deadline, instructions, reasoning_effort, context_tier } => {
                            let options = crate::engine::TriageModelOptions { model: model_id.clone(), reasoning_effort: reasoning_effort.clone(), context_tier: context_tier.clone(), instructions: instructions.clone() };
                            let model_id = model_id.clone();
                            let viewer_login = viewer_login.clone();
                            let items = items.clone();
                            let deadline = *deadline;
                            cancellation.begin(request.request_id, cancellation_scope(&request));
                            let task_engine = Arc::clone(&engine);
                            let cancellation_engine = Arc::clone(&engine);
                            let task_cancellation = cancellation.clone();
                            analyses.spawn(async move {
                                let work = task_engine.triage(request.request_id, viewer_login, items.clone(), options, task_cancellation.clone());
                                let result = run_until_deadline(work, deadline, request.request_id, &task_cancellation, cancellation_engine.as_ref()).await;
                                let response = match result {
                                    Ok(decisions) => match retain_valid_triage_outputs(decisions, &items) {
                                        Ok(decisions) => WireResponse::for_request(&request, ResponseResult::Triage { model_id: model_id.unwrap_or_else(|| "auto".to_owned()), decisions }),
                                        Err(_) => WireResponse::failure(&request, Failure::new(FailureCode::ValidationFailed, "Triage failed output validation")),
                                    },
                                    Err(failure) => WireResponse::failure(&request, failure),
                                };
                                task_cancellation.finish(request.request_id);
                                response
                            });
                        }
                        RequestOperation::Draft { model_id, viewer_login, item, deadline, goal, writing_style, reasoning_effort, context_tier } => {
                            let draft_request = crate::engine::DraftRequest { viewer_login: viewer_login.clone(), item: (**item).clone(), goal: goal.clone(), writing_style: writing_style.clone() };
                            let options = crate::engine::TriageModelOptions { model: model_id.clone(), reasoning_effort: reasoning_effort.clone(), context_tier: context_tier.clone(), instructions: None };
                            let model_id = model_id.clone();
                            let deadline = *deadline;
                            cancellation.begin(request.request_id, cancellation_scope(&request));
                            let task_engine = Arc::clone(&engine);
                            let cancellation_engine = Arc::clone(&engine);
                            let task_cancellation = cancellation.clone();
                            analyses.spawn(async move {
                                let work = task_engine.draft(request.request_id, draft_request, options, task_cancellation.clone());
                                let result = run_until_deadline(work, deadline, request.request_id, &task_cancellation, cancellation_engine.as_ref()).await;
                                let response = match result {
                                    Ok(draft) => WireResponse::for_request(&request, ResponseResult::Draft { model_id: model_id.unwrap_or_else(|| "auto".to_owned()), draft }),
                                    Err(failure) => WireResponse::failure(&request, failure),
                                };
                                task_cancellation.finish(request.request_id);
                                response
                            });
                        }
                        RequestOperation::Authenticate { credential, allow_browser } => {
                            let credential = credential.take();
                            let allow_browser = *allow_browser;
                            write_engine_response(&mut writer, &request, engine.authenticate(credential, allow_browser).await.map(|authentication| ResponseResult::Authentication { authentication }))?;
                        }
                        RequestOperation::Health => write_engine_response(&mut writer, &request, engine.health().await.map(|health| ResponseResult::Health { health }))?,
                        RequestOperation::Models => write_engine_response(&mut writer, &request, engine.models().await.map(|models| ResponseResult::Models { models }))?,
                        RequestOperation::Cancel { target_request_id } => {
                            let target_request_id = *target_request_id;
                            let response = if cancellation.cancel_in_scope(target_request_id, &cancellation_scope(&request)) {
                                match engine.cancel(target_request_id).await {
                                    Ok(()) => WireResponse::for_request(&request, ResponseResult::Cancelled { cancelled_request_id: target_request_id }),
                                    Err(failure) => WireResponse::failure(&request, failure),
                                }
                            } else {
                                // The Swift response schema always requires the target ID. A non-active
                                // target is idempotently acknowledged without affecting any newer work.
                                WireResponse::for_request(&request, ResponseResult::Cancelled { cancelled_request_id: target_request_id })
                            };
                            write_response(&mut writer, &response)?;
                        }
                        RequestOperation::Shutdown => {
                            cancellation.cancel_all();
                            let response = match abort_analyses_and_shutdown(engine.as_ref(), &mut analyses).await {
                                Ok(()) => WireResponse::for_request(&request, ResponseResult::Shutdown),
                                Err(failure) => WireResponse::failure(&request, failure),
                            };
                            write_response(&mut writer, &response)?;
                            break;
                        }
                    }
                    }
                }
            }
            joined = analyses.join_next(), if !analyses.is_empty() => if let Some(Ok(response)) = joined {
                write_response(&mut writer, &response)?;
            },
        }
    }
    Ok(())
}

/// Runs `work` until it finishes or `deadline` passes; on timeout the
/// request is cancelled in the engine so its session is torn down.
async fn run_until_deadline<E: CopilotEngine, T>(
    work: impl std::future::Future<Output = Result<T, Failure>>,
    deadline: DateTime<Utc>,
    request_id: Uuid,
    cancellation: &CancellationState,
    engine: &E,
) -> Result<T, Failure> {
    let remaining = deadline.signed_duration_since(Utc::now());
    if remaining <= chrono::Duration::zero() {
        return Err(Failure::new(FailureCode::Cancelled, "Deadline elapsed"));
    }
    tokio::pin!(work);
    let timer = tokio::time::sleep(std::time::Duration::from_millis(
        remaining.num_milliseconds() as u64,
    ));
    tokio::pin!(timer);
    tokio::select! {
        value = &mut work => value,
        _ = &mut timer => {
            cancellation.cancel(request_id);
            let _ = engine.cancel(request_id).await;
            Err(Failure::new(FailureCode::Cancelled, "Deadline elapsed"))
        }
    }
}

fn write_engine_response<W: Write>(
    writer: &mut W,
    request: &WireRequest,
    result: Result<ResponseResult, Failure>,
) -> Result<(), ProtocolError> {
    let response = match result {
        Ok(result) => WireResponse::for_request(request, result),
        Err(failure) => WireResponse::failure(request, failure),
    };
    write_response(writer, &response)
}

enum ReaderEvent {
    Request(Box<WireRequest>),
    Malformed,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::EphemeralCredential;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    fn request(operation: RequestOperation) -> WireRequest {
        WireRequest {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::parse_str("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").unwrap(),
            account_id: "account-1".to_owned(),
            organization_id: "organization-1".to_owned(),
            operation,
        }
    }

    #[test]
    fn v2_frames_require_and_round_trip_account_identity() {
        let request = request(RequestOperation::Health);
        let mut framed = Vec::new();
        write_frame(&mut framed, &serde_json::to_vec(&request).unwrap()).unwrap();
        let decoded = read_request(&mut framed.as_slice()).unwrap().unwrap();
        assert_eq!(decoded.account_id, "account-1");
        let response = WireResponse::for_request(
            &decoded,
            ResponseResult::Health {
                health: HealthResponse {
                    helper_version: "test".to_owned(),
                    copilot_available: false,
                    tool_policy: "deny_all".to_owned(),
                },
            },
        );
        let body = serde_json::to_value(response).unwrap();
        assert_eq!(body["protocol_version"], 2);
        assert_eq!(body["account_id"], "account-1");
        assert_eq!(body["status"], "health");
    }

    #[test]
    fn failures_and_cancel_responses_are_bound_to_the_request_account() {
        let request = request(RequestOperation::Cancel {
            target_request_id: Uuid::new_v4(),
        });
        let failure = serde_json::to_value(WireResponse::failure(
            &request,
            Failure::new(FailureCode::Busy, "busy"),
        ))
        .unwrap();
        assert_eq!(failure["account_id"], "account-1");
        assert_eq!(failure["organization_id"], "organization-1");
        let response = serde_json::to_value(WireResponse::for_request(
            &request,
            ResponseResult::Cancelled {
                cancelled_request_id: request.request_id,
            },
        ))
        .unwrap();
        assert_eq!(response["status"], "cancelled");
        assert_eq!(
            response["cancelled_request_id"],
            request.request_id.to_string()
        );
    }

    #[test]
    fn active_analysis_only_admits_control_frames() {
        assert!(!is_control_operation(&RequestOperation::Health));
        assert!(!is_control_operation(&RequestOperation::Models));
        assert!(!is_control_operation(&RequestOperation::Authenticate {
            allow_browser: false,
            credential: Some(EphemeralCredential::new("test-token".to_owned())),
        }));
        assert!(is_control_operation(&RequestOperation::Cancel {
            target_request_id: Uuid::new_v4(),
        }));
        assert!(is_control_operation(&RequestOperation::Shutdown));
    }

    #[derive(Default)]
    struct ShutdownProbe {
        shutdowns: AtomicUsize,
    }

    #[async_trait::async_trait]
    impl CopilotEngine for ShutdownProbe {
        async fn health(&self) -> Result<HealthResponse, Failure> {
            Err(Failure::new(FailureCode::Internal, "not used"))
        }

        async fn models(&self) -> Result<Vec<ModelDescriptor>, Failure> {
            Err(Failure::new(FailureCode::Internal, "not used"))
        }

        async fn triage(
            &self,
            _: Uuid,
            _: String,
            _: Vec<TriageItem>,
            _: crate::engine::TriageModelOptions,
            _: CancellationState,
        ) -> Result<Vec<TriageItemDecision>, Failure> {
            Err(Failure::new(FailureCode::Internal, "unused"))
        }
        async fn draft(
            &self,
            _: Uuid,
            _: crate::engine::DraftRequest,
            _: crate::engine::TriageModelOptions,
            _: CancellationState,
        ) -> Result<String, Failure> {
            Err(Failure::new(FailureCode::Internal, "unused"))
        }
        async fn authenticate(
            &self,
            _: Option<EphemeralCredential>,
            _: bool,
        ) -> Result<AuthenticationResponse, Failure> {
            Err(Failure::new(FailureCode::Internal, "not used"))
        }

        async fn cancel(&self, _: Uuid) -> Result<(), Failure> {
            Ok(())
        }

        async fn shutdown(&self) -> Result<(), Failure> {
            self.shutdowns.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    #[tokio::test]
    async fn malformed_or_shutdown_interleaving_aborts_analysis_then_drains_engine() {
        let engine = Arc::new(ShutdownProbe::default());
        let mut analyses = JoinSet::new();
        analyses.spawn(std::future::pending::<WireResponse>());

        abort_analyses_and_shutdown(engine.as_ref(), &mut analyses)
            .await
            .unwrap();

        assert!(analyses.is_empty());
        assert_eq!(engine.shutdowns.load(Ordering::SeqCst), 1);
    }

    fn draft_payload(extra: &str) -> Vec<u8> {
        let payload = format!(
            r#"{{"protocol_version":2,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","account_id":"account-1","organization_id":"organization-1","operation":"draft","viewer_login":"octocat","deadline":"2030-01-01T00:00:00Z","goal":"Answer @bob","writing_style":"Brief.","item":{{"id":"I_1","kind":"issue","repository":"octo/widgets","number":1,"title":"Bug","state":"open","author":"bob","updated_at":"2030-01-01T00:00:00Z","relationships":["mentioned"],"labels":[],"assignees":[],"body":"Can you look?","pull_request":null,"recent_activity":[]}}{extra}}}"#
        );
        let mut framed = Vec::new();
        write_frame(&mut framed, payload.as_bytes()).unwrap();
        framed
    }

    #[test]
    fn draft_requests_decode_strictly() {
        let decoded = read_request(&mut draft_payload("").as_slice())
            .unwrap()
            .unwrap();
        let RequestOperation::Draft {
            item,
            goal,
            writing_style,
            ..
        } = decoded.operation
        else {
            panic!("expected draft");
        };
        assert_eq!(item.id, "I_1");
        assert_eq!(goal.as_deref(), Some("Answer @bob"));
        assert_eq!(writing_style.as_deref(), Some("Brief."));
        assert!(read_request(&mut draft_payload(r#","extra":1"#).as_slice()).is_err());
        let response = serde_json::to_value(WireResponse::for_request(
            &request(RequestOperation::Health),
            ResponseResult::Draft {
                model_id: "auto".to_owned(),
                draft: "Thanks!".to_owned(),
            },
        ))
        .unwrap();
        assert_eq!(response["status"], "draft");
        assert_eq!(response["draft"], "Thanks!");
    }

    #[test]
    fn oversize_frames_are_rejected_before_allocation() {
        let mut framed = (MAX_REQUEST_BYTES as u32 + 1).to_be_bytes().to_vec();
        framed.extend_from_slice(b"ignored");
        assert!(matches!(
            read_request(&mut framed.as_slice()),
            Err(ProtocolError::RequestTooLarge)
        ));
    }

    #[test]
    fn authenticate_token_is_inbound_only_and_never_enters_debug_or_response() {
        let token = "triage-test-secret";
        let payload = format!(
            r#"{{"protocol_version":2,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","account_id":"account-1","organization_id":"organization-1","operation":"authenticate","credential":"{token}"}}"#
        );
        let mut framed = Vec::new();
        write_frame(&mut framed, payload.as_bytes()).unwrap();
        let request = read_request(&mut framed.as_slice()).unwrap().unwrap();
        assert!(request.validate().is_ok());
        assert!(!format!("{request:?}").contains(token));
        assert!(serde_json::to_value(&request).is_err());
        let response = WireResponse::for_request(
            &request,
            ResponseResult::Authentication {
                authentication: AuthenticationResponse {
                    host: "https://github.com".to_owned(),
                    login: "octocat".to_owned(),
                    auth_type: "token".to_owned(),
                    is_authenticated: true,
                },
            },
        );
        let response = serde_json::to_string(&response).unwrap();
        assert!(!response.contains(token));
        assert!(response.contains("authentication"));
    }

    #[test]
    fn rejected_authentication_payload_never_echoes_its_secret() {
        let token = "triage-rejected-secret";
        let payload = format!(
            r#"{{"protocol_version":2,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","account_id":"account-1","organization_id":"organization-1","operation":"authenticate","credential":"{token}","extra":"{token}"}}"#
        );
        let mut framed = Vec::new();
        write_frame(&mut framed, payload.as_bytes()).unwrap();
        let error = read_request(&mut framed.as_slice()).unwrap_err();
        assert!(!format!("{error:?}").contains(token));
        assert!(!error.to_string().contains(token));
    }
}
