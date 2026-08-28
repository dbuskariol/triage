use std::io::{self, Read, Write};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::task::JoinSet;
use uuid::Uuid;

use crate::{
    engine::{CancellationState, CopilotEngine},
    schema::{AnalysisOutput, CandidateInput, ValidationError},
};

pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct WireRequest {
    pub protocol_version: u16,
    pub request_id: Uuid,
    pub organization_id: Uuid,
    #[serde(flatten)]
    pub operation: RequestOperation,
}

impl WireRequest {
    pub fn validate(&self) -> Result<(), ProtocolError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion);
        }
        if let RequestOperation::Analyze { candidate, model } = &self.operation {
            candidate
                .validate()
                .map_err(ProtocolError::InvalidRequest)?;
            if let Some(model) = model {
                validate_model(model)?;
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum RequestOperation {
    Health,
    Models,
    Analyze {
        candidate: CandidateInput,
        model: Option<String>,
    },
    Cancel {
        target_request_id: Uuid,
    },
    Shutdown,
}

#[derive(Clone, Debug, Serialize)]
pub struct WireResponse {
    pub protocol_version: u16,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub organization_id: Option<Uuid>,
    #[serde(flatten)]
    pub result: ResponseResult,
}

impl WireResponse {
    fn for_request(request: &WireRequest, result: ResponseResult) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id: Some(request.request_id),
            organization_id: Some(request.organization_id),
            result,
        }
    }

    fn failure(request: Option<&WireRequest>, failure: Failure) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            request_id: request.map(|value| value.request_id),
            organization_id: request.map(|value| value.organization_id),
            result: ResponseResult::Failure { failure },
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ResponseResult {
    Health { health: HealthResponse },
    Models { models: Vec<ModelDescriptor> },
    Analysis { analysis: AnalysisOutput },
    Cancelled { cancelled: bool },
    Shutdown { accepted: bool },
    Failure { failure: Failure },
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

impl ProtocolError {
    fn failure(&self) -> Failure {
        match self {
            Self::InvalidFrame | Self::Io(_) | Self::Json(_) => Failure::new(
                FailureCode::InvalidFrame,
                "Invalid length-prefixed JSON frame",
            ),
            Self::RequestTooLarge => {
                Failure::new(FailureCode::RequestTooLarge, "Request exceeds 1 MiB limit")
            }
            Self::ResponseTooLarge => {
                Failure::new(FailureCode::Internal, "Response exceeds 256 KiB limit")
            }
            Self::InvalidRequest(_) => Failure::new(
                FailureCode::ValidationFailed,
                "Request failed schema validation",
            ),
            Self::UnsupportedVersion => Failure::new(
                FailureCode::UnsupportedVersion,
                "Unsupported protocol version",
            ),
        }
    }
}

/// Reads a single big-endian u32-length JSON frame.
pub fn read_request<R: Read>(reader: &mut R) -> Result<Option<WireRequest>, ProtocolError> {
    let Some(payload) = read_frame(reader, MAX_REQUEST_BYTES)? else {
        return Ok(None);
    };
    let value: serde_json::Value = serde_json::from_slice(&payload)?;
    validate_request_fields(&value)?;
    let request: WireRequest = serde_json::from_value(value)?;
    request.validate()?;
    Ok(Some(request))
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

fn read_frame<R: Read>(reader: &mut R, maximum: usize) -> Result<Option<Vec<u8>>, ProtocolError> {
    let mut first = [0_u8; 1];
    match reader.read(&mut first)? {
        0 => return Ok(None),
        1 => {}
        _ => unreachable!("single-byte buffer cannot read more than one byte"),
    }
    let mut header = [0_u8; 4];
    header[0] = first[0];
    reader.read_exact(&mut header[1..])?;
    let length = u32::from_be_bytes(header) as usize;
    if length > maximum {
        return Err(ProtocolError::RequestTooLarge);
    }
    let mut payload = vec![0_u8; length];
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

fn validate_model(model: &str) -> Result<(), ProtocolError> {
    if model.is_empty() || model.len() > 128 || model.contains('\0') || model.contains("```") {
        return Err(ProtocolError::InvalidRequest(ValidationError::new(
            "model has an invalid value",
        )));
    }
    Ok(())
}

/// `serde(flatten)` and `deny_unknown_fields` are incompatible. The operation
/// tag is flattened to keep the wire contract compact, so this check provides
/// the equivalent fail-closed top-level unknown-field enforcement before
/// strongly typed Serde deserialization handles every nested object.
fn validate_request_fields(value: &serde_json::Value) -> Result<(), ProtocolError> {
    let object = value.as_object().ok_or_else(|| {
        ProtocolError::InvalidRequest(ValidationError::new("request must be an object"))
    })?;
    let operation = object
        .get("operation")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            ProtocolError::InvalidRequest(ValidationError::new("operation must be a string"))
        })?;
    let allowed = match operation {
        "health" | "models" | "shutdown" => &[
            "protocol_version",
            "request_id",
            "organization_id",
            "operation",
        ][..],
        "analyze" => &[
            "protocol_version",
            "request_id",
            "organization_id",
            "operation",
            "candidate",
            "model",
        ][..],
        "cancel" => &[
            "protocol_version",
            "request_id",
            "organization_id",
            "operation",
            "target_request_id",
        ][..],
        _ => {
            return Err(ProtocolError::InvalidRequest(ValidationError::new(
                "unsupported operation",
            )));
        }
    };
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(ProtocolError::InvalidRequest(ValidationError::new(
            "request contains an unknown field",
        )));
    }
    Ok(())
}

/// Runs the production stdin/stdout protocol. One analysis runs at a time;
/// input remains readable while it runs so a `cancel` can reach the engine.
pub async fn serve_stdio<E: CopilotEngine>(engine: Arc<E>) -> Result<(), ProtocolError> {
    let (sender, mut receiver) = tokio::sync::mpsc::channel(8);
    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut reader = stdin.lock();
        loop {
            match read_request(&mut reader) {
                Ok(Some(request)) => {
                    if sender.blocking_send(ReaderEvent::Request(request)).is_err() {
                        return;
                    }
                }
                Ok(None) => return,
                Err(error) => {
                    let terminal =
                        matches!(error, ProtocolError::RequestTooLarge | ProtocolError::Io(_));
                    if sender
                        .blocking_send(ReaderEvent::Failure(error.failure(), terminal))
                        .is_err()
                    {
                        return;
                    }
                    if terminal {
                        return;
                    }
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
                let Some(event) = event else {
                    break;
                };
                match event {
                    ReaderEvent::Failure(failure, terminal) => {
                        write_response(&mut writer, &WireResponse::failure(None, failure))?;
                        if terminal {
                            analyses.abort_all();
                            break;
                        }
                    }
                    ReaderEvent::Request(request) => {
                        match request.operation.clone() {
                            RequestOperation::Analyze { candidate, model } => {
                                if !analyses.is_empty() {
                                    write_response(
                                        &mut writer,
                                        &WireResponse::failure(
                                            Some(&request),
                                            Failure::new(FailureCode::Busy, "Only one analysis may run at a time"),
                                        ),
                                    )?;
                                    continue;
                                }
                                cancellation.begin(request.request_id);
                                let task_engine = Arc::clone(&engine);
                                let task_cancellation = cancellation.clone();
                                analyses.spawn(async move {
                                    let response = match task_engine
                                        .analyze(
                                            request.request_id,
                                            candidate.clone(),
                                            model,
                                            task_cancellation.clone(),
                                        )
                                        .await
                                    {
                                        Ok(_analysis) if task_cancellation.is_cancelled(request.request_id) => {
                                            WireResponse::failure(
                                                Some(&request),
                                                Failure::new(FailureCode::Cancelled, "Analysis was cancelled"),
                                            )
                                        }
                                        Ok(analysis) => match analysis.validate_against(&candidate) {
                                            Ok(()) => WireResponse::for_request(
                                                &request,
                                                ResponseResult::Analysis { analysis },
                                            ),
                                            Err(_) => WireResponse::failure(
                                                Some(&request),
                                                Failure::new(FailureCode::ValidationFailed, "Analysis failed output validation"),
                                            ),
                                        },
                                        Err(failure) => WireResponse::failure(Some(&request), failure),
                                    };
                                    task_cancellation.finish(request.request_id);
                                    response
                                });
                            }
                            RequestOperation::Health => {
                                write_engine_response(
                                    &mut writer,
                                    &request,
                                    engine.health().await.map(|health| ResponseResult::Health { health }),
                                )?;
                            }
                            RequestOperation::Models => {
                                write_engine_response(
                                    &mut writer,
                                    &request,
                                    engine.models().await.map(|models| ResponseResult::Models { models }),
                                )?;
                            }
                            RequestOperation::Cancel { target_request_id } => {
                                let cancelled = cancellation.cancel(target_request_id);
                                let response = if cancelled {
                                    match engine.cancel(target_request_id).await {
                                        Ok(()) => WireResponse::for_request(
                                            &request,
                                            ResponseResult::Cancelled { cancelled: true },
                                        ),
                                        Err(failure) => WireResponse::failure(Some(&request), failure),
                                    }
                                } else {
                                    WireResponse::for_request(
                                        &request,
                                        ResponseResult::Cancelled { cancelled: false },
                                    )
                                };
                                write_response(&mut writer, &response)?;
                            }
                            RequestOperation::Shutdown => {
                                cancellation.cancel_all();
                                analyses.abort_all();
                                let response = match engine.shutdown().await {
                                    Ok(()) => WireResponse::for_request(
                                        &request,
                                        ResponseResult::Shutdown { accepted: true },
                                    ),
                                    Err(failure) => WireResponse::failure(Some(&request), failure),
                                };
                                write_response(&mut writer, &response)?;
                                break;
                            }
                        }
                    }
                }
            }
            joined = analyses.join_next(), if !analyses.is_empty() => {
                if let Some(Ok(response)) = joined {
                    write_response(&mut writer, &response)?;
                } else if joined.is_some() {
                    write_response(
                        &mut writer,
                        &WireResponse::failure(
                            None,
                            Failure::new(FailureCode::Internal, "Analysis task terminated unexpectedly"),
                        ),
                    )?;
                }
            }
        }
    }
    Ok(())
}

fn write_engine_response<W: Write>(
    writer: &mut W,
    request: &WireRequest,
    result: Result<ResponseResult, Failure>,
) -> Result<(), ProtocolError> {
    let response = match result {
        Ok(result) => WireResponse::for_request(request, result),
        Err(failure) => WireResponse::failure(Some(request), failure),
    };
    write_response(writer, &response)
}

enum ReaderEvent {
    Request(WireRequest),
    Failure(Failure, bool),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::tests::candidate;

    fn request(operation: RequestOperation) -> WireRequest {
        WireRequest {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::parse_str("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").unwrap(),
            organization_id: Uuid::parse_str("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb").unwrap(),
            operation,
        }
    }

    #[test]
    fn length_framing_round_trips_strict_request() {
        let request = request(RequestOperation::Health);
        let json = serde_json::to_vec(&request).unwrap();
        let mut framed = Vec::new();
        write_frame(&mut framed, &json).unwrap();

        let decoded = read_request(&mut framed.as_slice()).unwrap().unwrap();
        assert_eq!(decoded.request_id, request.request_id);
        assert!(matches!(decoded.operation, RequestOperation::Health));
    }

    #[test]
    fn protocol_accepts_each_and_only_supported_operation() {
        let operations = [
            RequestOperation::Health,
            RequestOperation::Models,
            RequestOperation::Analyze {
                candidate: candidate(),
                model: None,
            },
            RequestOperation::Cancel {
                target_request_id: Uuid::parse_str("cccccccc-cccc-4ccc-8ccc-cccccccccccc").unwrap(),
            },
            RequestOperation::Shutdown,
        ];

        for operation in operations {
            let request = request(operation);
            let payload = serde_json::to_vec(&request).unwrap();
            let mut framed = Vec::new();
            write_frame(&mut framed, &payload).unwrap();
            assert!(read_request(&mut framed.as_slice()).unwrap().is_some());
        }

        let unsupported = br#"{"protocol_version":1,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","organization_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","operation":"other"}"#;
        let mut framed = Vec::new();
        write_frame(&mut framed, unsupported).unwrap();
        assert!(matches!(
            read_request(&mut framed.as_slice()),
            Err(ProtocolError::InvalidRequest(_))
        ));
    }

    #[test]
    fn unknown_request_fields_are_rejected() {
        let body = br#"{"protocol_version":1,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","organization_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","operation":"health","extra":true}"#;
        let mut framed = Vec::new();
        write_frame(&mut framed, body).unwrap();

        assert!(matches!(
            read_request(&mut framed.as_slice()),
            Err(ProtocolError::InvalidRequest(_))
        ));
    }

    #[test]
    fn oversized_frames_are_rejected_before_allocation() {
        let mut framed = (MAX_REQUEST_BYTES as u32 + 1).to_be_bytes().to_vec();
        framed.extend_from_slice(b"ignored");
        assert!(matches!(
            read_request(&mut framed.as_slice()),
            Err(ProtocolError::RequestTooLarge)
        ));
    }

    #[test]
    fn analysis_request_validates_candidate_and_model() {
        let valid = request(RequestOperation::Analyze {
            candidate: candidate(),
            model: Some("model-a".to_owned()),
        });
        assert!(valid.validate().is_ok());

        let invalid = request(RequestOperation::Analyze {
            candidate: candidate(),
            model: Some("```model```".to_owned()),
        });
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn response_bound_is_enforced() {
        let response = WireResponse {
            protocol_version: PROTOCOL_VERSION,
            request_id: None,
            organization_id: None,
            result: ResponseResult::Failure {
                failure: Failure::new(FailureCode::Internal, "x".repeat(MAX_RESPONSE_BYTES)),
            },
        };
        assert!(matches!(
            write_response(&mut Vec::new(), &response),
            Err(ProtocolError::ResponseTooLarge)
        ));
    }
}
