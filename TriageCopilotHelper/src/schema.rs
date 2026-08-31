use std::collections::{BTreeMap, HashSet};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

// These are intentionally the same limits enforced by CopilotAnalysisInput
// and CopilotAnalysisResponse in Triage/CopilotXPC/CopilotXPCProtocol.swift.
pub const MAX_WORK_ITEM_TITLE_BYTES: usize = 4_096;
pub const MAX_WORK_ITEM_STATE_BYTES: usize = 256;
pub const MAX_BODY_BYTES: usize = 65_536;
pub const MAX_REASON_BYTES: usize = 1_024;
pub const MAX_LABEL_BYTES: usize = 256;
pub const MAX_PROJECT_FIELD_KEY_BYTES: usize = 512;
pub const MAX_PROJECT_FIELD_VALUE_BYTES: usize = 2_048;
pub const MAX_AUTHOR_ROLE_BYTES: usize = 256;
pub const MAX_CONVERSATION_TEXT_BYTES: usize = 32_768;
pub const MAX_EVIDENCE_TEXT_BYTES: usize = 8_192;
pub const MAX_EVIDENCE_COUNT: usize = 128;
pub const MAX_LABEL_COUNT: usize = 64;
pub const MAX_PROJECT_FIELD_COUNT: usize = 64;
pub const MAX_SUMMARY_BYTES: usize = 16_384;
pub const MAX_NEXT_ACTION_BYTES: usize = 8_192;
pub const MAX_ACTION_TEXT_BYTES: usize = 8_192;

#[derive(Clone, Debug, Eq, Error, PartialEq)]
#[error("{message}")]
pub struct ValidationError {
    message: String,
}

impl ValidationError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

/// Exact Rust representation of Swift's `CopilotConversationExcerpt`.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ConversationExcerpt {
    pub evidence_id: String,
    pub author_role: String,
    pub text: String,
    pub timestamp: DateTime<Utc>,
}

/// Exact Rust representation of Swift's `CopilotEvidenceExcerpt`. The
/// evidence table is the sole source a generated response may cite.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EvidenceExcerpt {
    pub id: String,
    pub actor_role: String,
    pub text: String,
    pub timestamp: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub explicit_deadline: Option<DateTime<Utc>>,
}

/// Exact Rust representation of Swift's `CopilotAnalysisInput`.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AnalysisInput {
    pub candidate_id: String,
    pub content_is_untrusted: bool,
    pub work_item_title: String,
    pub work_item_state: String,
    pub deterministic_reasons: Vec<String>,
    pub body: String,
    pub labels: Vec<String>,
    pub project_fields: BTreeMap<String, String>,
    pub conversation: Vec<ConversationExcerpt>,
    pub evidence: Vec<EvidenceExcerpt>,
    pub evidence_ids: Vec<String>,
}

impl AnalysisInput {
    pub fn validate(&self) -> Result<(), ValidationError> {
        validate_identifier(&self.candidate_id, "candidate_id")?;
        if !self.content_is_untrusted {
            return Err(ValidationError::new("content_is_untrusted must be true"));
        }
        validate_text(
            &self.work_item_title,
            MAX_WORK_ITEM_TITLE_BYTES,
            "work_item_title",
        )?;
        validate_text(
            &self.work_item_state,
            MAX_WORK_ITEM_STATE_BYTES,
            "work_item_state",
        )?;
        if self.deterministic_reasons.is_empty() {
            return Err(ValidationError::new(
                "deterministic_reasons must not be empty",
            ));
        }
        ensure_unique_text(
            &self.deterministic_reasons,
            MAX_REASON_BYTES,
            "deterministic_reasons",
        )?;
        validate_bounded(&self.body, MAX_BODY_BYTES, "body")?;
        if self.labels.len() > MAX_LABEL_COUNT {
            return Err(ValidationError::new("labels exceeds maximum count"));
        }
        ensure_unique_text(&self.labels, MAX_LABEL_BYTES, "labels")?;
        if self.project_fields.len() > MAX_PROJECT_FIELD_COUNT {
            return Err(ValidationError::new("project_fields exceeds maximum count"));
        }
        for (key, value) in &self.project_fields {
            validate_text(key, MAX_PROJECT_FIELD_KEY_BYTES, "project_fields key")?;
            validate_bounded(value, MAX_PROJECT_FIELD_VALUE_BYTES, "project_fields value")?;
        }
        ensure_unique_identifiers(&self.evidence_ids, "evidence_ids")?;
        if self.evidence.len() > MAX_EVIDENCE_COUNT {
            return Err(ValidationError::new("evidence exceeds maximum count"));
        }
        let evidence_ids: HashSet<&str> = self.evidence_ids.iter().map(String::as_str).collect();
        let mut table_ids = HashSet::new();
        for excerpt in &self.evidence {
            validate_identifier(&excerpt.id, "evidence.id")?;
            if !table_ids.insert(excerpt.id.as_str()) {
                return Err(ValidationError::new("evidence contains duplicate IDs"));
            }
            validate_text(
                &excerpt.actor_role,
                MAX_AUTHOR_ROLE_BYTES,
                "evidence.actor_role",
            )?;
            validate_bounded(&excerpt.text, MAX_EVIDENCE_TEXT_BYTES, "evidence.text")?;
        }
        if table_ids != evidence_ids {
            return Err(ValidationError::new(
                "evidence IDs must exactly match the evidence table",
            ));
        }
        for excerpt in &self.conversation {
            validate_identifier(&excerpt.evidence_id, "conversation.evidence_id")?;
            validate_text(
                &excerpt.author_role,
                MAX_AUTHOR_ROLE_BYTES,
                "conversation.author_role",
            )?;
            validate_bounded(
                &excerpt.text,
                MAX_CONVERSATION_TEXT_BYTES,
                "conversation.text",
            )?;
            if !evidence_ids.contains(excerpt.evidence_id.as_str()) {
                return Err(ValidationError::new(
                    "conversation references unknown evidence",
                ));
            }
        }
        Ok(())
    }
}

/// A structured, source-grounded assertion made by one suggested action.
/// Empty action claim lists are permitted for review-only semantic output;
/// callers must not promote them to automatic actions.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActionClaim {
    pub evidence_id: String,
    pub actor_role: String,
    pub timestamp: DateTime<Utc>,
    pub quoted_span: String,
    pub deterministic_reason_id: String,
}

/// Exact Rust representation of Swift's `CopilotSuggestedActionItem`.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SuggestedActionItem {
    pub id: String,
    pub text: String,
    pub confidence: f64,
    pub evidence_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deadline: Option<DateTime<Utc>>,
    pub claims: Vec<ActionClaim>,
}

/// Exact Rust representation of Swift's flat `CopilotAnalysisResponse` body.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AnalysisOutput {
    pub summary: String,
    pub state: String,
    pub confidence: f64,
    pub evidence_ids: Vec<String>,
    pub action_items: Vec<SuggestedActionItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_action: Option<String>,
    pub model_id: String,
    pub prompt_provenance: String,
}

impl AnalysisOutput {
    pub fn validate_against(&self, input: &AnalysisInput) -> Result<(), ValidationError> {
        validate_text(&self.summary, MAX_SUMMARY_BYTES, "summary")?;
        reject_fence(&self.summary, "summary")?;
        validate_text(&self.state, MAX_WORK_ITEM_STATE_BYTES, "state")?;
        reject_fence(&self.state, "state")?;
        // Swift's response contract requires these to be non-empty but does
        // not impose a byte limit.
        validate_text(&self.model_id, usize::MAX, "model_id")?;
        validate_text(&self.prompt_provenance, usize::MAX, "prompt_provenance")?;
        if !self.confidence.is_finite() || !(0.0..=1.0).contains(&self.confidence) {
            return Err(ValidationError::new(
                "confidence must be between zero and one",
            ));
        }
        if let Some(next_action) = &self.next_action {
            validate_bounded(next_action, MAX_NEXT_ACTION_BYTES, "next_action")?;
            reject_fence(next_action, "next_action")?;
        }

        let permitted: HashSet<&str> = input.evidence_ids.iter().map(String::as_str).collect();
        let permitted_reasons: HashSet<&str> = input
            .deterministic_reasons
            .iter()
            .map(String::as_str)
            .collect();
        ensure_subset_unique(&self.evidence_ids, &permitted, "evidence_ids")?;
        let mut action_ids = HashSet::new();
        for action in &self.action_items {
            validate_text(&action.id, usize::MAX, "action_items.id")?;
            if !action_ids.insert(action.id.as_str()) {
                return Err(ValidationError::new("action item IDs must be unique"));
            }
            validate_text(&action.text, MAX_ACTION_TEXT_BYTES, "action_items.text")?;
            if !action.confidence.is_finite() || !(0.0..=1.0).contains(&action.confidence) {
                return Err(ValidationError::new(
                    "action_items.confidence must be between zero and one",
                ));
            }
            ensure_subset_unique(
                &action.evidence_ids,
                &permitted,
                "action_items.evidence_ids",
            )?;
            if action.claims.len() > MAX_EVIDENCE_COUNT {
                return Err(ValidationError::new(
                    "action_items.claims exceeds maximum count",
                ));
            }
            let mut claimed_evidence_ids = HashSet::new();
            for claim in &action.claims {
                validate_identifier(&claim.evidence_id, "action_items.claims.evidence_id")?;
                if !claimed_evidence_ids.insert(claim.evidence_id.as_str()) {
                    return Err(ValidationError::new(
                        "action_items.claims contains duplicate evidence IDs",
                    ));
                }
                let Some(evidence) = input
                    .evidence
                    .iter()
                    .find(|evidence| evidence.id == claim.evidence_id)
                else {
                    return Err(ValidationError::new(
                        "action_items.claims cites unknown evidence",
                    ));
                };
                if !action
                    .evidence_ids
                    .iter()
                    .any(|id| id == &claim.evidence_id)
                {
                    return Err(ValidationError::new(
                        "action_items.claims evidence is not cited by its action",
                    ));
                }
                validate_text(
                    &claim.actor_role,
                    MAX_AUTHOR_ROLE_BYTES,
                    "action_items.claims.actor_role",
                )?;
                if claim.actor_role != evidence.actor_role {
                    return Err(ValidationError::new(
                        "action_items.claims actor role does not match evidence",
                    ));
                }
                if claim.timestamp != evidence.timestamp {
                    return Err(ValidationError::new(
                        "action_items.claims timestamp does not match evidence",
                    ));
                }
                validate_text(
                    &claim.quoted_span,
                    MAX_EVIDENCE_TEXT_BYTES,
                    "action_items.claims.quoted_span",
                )?;
                if claim.quoted_span.chars().any(char::is_control)
                    || !evidence.text.contains(&claim.quoted_span)
                {
                    return Err(ValidationError::new(
                        "action_items.claims quote is not an exact evidence span",
                    ));
                }
                validate_text(
                    &claim.deterministic_reason_id,
                    MAX_REASON_BYTES,
                    "action_items.claims.deterministic_reason_id",
                )?;
                if !permitted_reasons.contains(claim.deterministic_reason_id.as_str()) {
                    return Err(ValidationError::new(
                        "action_items.claims deterministic reason is not current",
                    ));
                }
            }
            if let Some(deadline) = action.deadline {
                let is_evidenced = input.evidence.iter().any(|evidence| {
                    action.evidence_ids.iter().any(|id| id == &evidence.id)
                        && evidence.explicit_deadline == Some(deadline)
                });
                if !is_evidenced {
                    return Err(ValidationError::new(
                        "action_items.deadline is not present in cited evidence",
                    ));
                }
            }
        }
        Ok(())
    }
}

fn validate_identifier(value: &str, field: &str) -> Result<(), ValidationError> {
    if value.is_empty() || value.chars().any(char::is_whitespace) {
        return Err(ValidationError::new(format!("{field} is invalid")));
    }
    Ok(())
}

fn validate_text(value: &str, maximum: usize, field: &str) -> Result<(), ValidationError> {
    if value.is_empty() {
        return Err(ValidationError::new(format!("{field} must not be empty")));
    }
    validate_bounded(value, maximum, field)
}

fn validate_bounded(value: &str, maximum: usize, field: &str) -> Result<(), ValidationError> {
    if value.len() > maximum {
        return Err(ValidationError::new(format!(
            "{field} exceeds its byte limit"
        )));
    }
    Ok(())
}

fn reject_fence(value: &str, field: &str) -> Result<(), ValidationError> {
    if value.contains("```") {
        return Err(ValidationError::new(format!(
            "{field} must not contain Markdown fences"
        )));
    }
    Ok(())
}

fn ensure_unique_identifiers(values: &[String], field: &str) -> Result<(), ValidationError> {
    let mut seen = HashSet::new();
    for value in values {
        validate_identifier(value, field)?;
        if !seen.insert(value.as_str()) {
            return Err(ValidationError::new(format!("{field} contains duplicates")));
        }
    }
    Ok(())
}

fn ensure_unique_text(
    values: &[String],
    maximum: usize,
    field: &str,
) -> Result<(), ValidationError> {
    let mut seen = HashSet::new();
    for value in values {
        validate_text(value, maximum, field)?;
        if !seen.insert(value.as_str()) {
            return Err(ValidationError::new(format!("{field} contains duplicates")));
        }
    }
    Ok(())
}

fn ensure_subset_unique(
    values: &[String],
    permitted: &HashSet<&str>,
    field: &str,
) -> Result<(), ValidationError> {
    let mut seen = HashSet::new();
    for value in values {
        if !seen.insert(value.as_str()) || !permitted.contains(value.as_str()) {
            return Err(ValidationError::new(format!(
                "{field} contains an unknown or duplicate ID"
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn input() -> AnalysisInput {
        AnalysisInput {
            candidate_id: "candidate-1".to_owned(),
            content_is_untrusted: true,
            work_item_title: "Review incident fix".to_owned(),
            work_item_state: "open".to_owned(),
            deterministic_reasons: vec!["review_requested".to_owned()],
            body: "Please review the mitigation.".to_owned(),
            labels: vec!["incident".to_owned()],
            project_fields: BTreeMap::from([("priority".to_owned(), "high".to_owned())]),
            conversation: vec![ConversationExcerpt {
                evidence_id: "evidence-1".to_owned(),
                author_role: "author".to_owned(),
                text: "The deadline is Friday.".to_owned(),
                timestamp: "2026-08-28T04:00:00Z".parse().unwrap(),
            }],
            evidence: vec![EvidenceExcerpt {
                id: "evidence-1".to_owned(),
                actor_role: "author".to_owned(),
                text: "The deadline is Friday.".to_owned(),
                timestamp: "2026-08-28T04:00:00Z".parse().unwrap(),
                explicit_deadline: Some("2026-08-29T17:00:00Z".parse().unwrap()),
            }],
            evidence_ids: vec!["evidence-1".to_owned()],
        }
    }

    pub(crate) fn output() -> AnalysisOutput {
        AnalysisOutput {
            summary: "A review is requested before Friday.".to_owned(),
            state: "open".to_owned(),
            confidence: 0.95,
            evidence_ids: vec!["evidence-1".to_owned()],
            action_items: vec![SuggestedActionItem {
                id: "action-1".to_owned(),
                text: "Review the mitigation".to_owned(),
                confidence: 0.95,
                evidence_ids: vec!["evidence-1".to_owned()],
                deadline: Some("2026-08-29T17:00:00Z".parse().unwrap()),
                claims: vec![ActionClaim {
                    evidence_id: "evidence-1".to_owned(),
                    actor_role: "author".to_owned(),
                    timestamp: "2026-08-28T04:00:00Z".parse().unwrap(),
                    quoted_span: "The deadline is Friday.".to_owned(),
                    deterministic_reason_id: "review_requested".to_owned(),
                }],
            }],
            next_action: Some("Read the mitigation and leave a review.".to_owned()),
            model_id: "example-model".to_owned(),
            prompt_provenance: "triage-copilot-v2".to_owned(),
        }
    }

    #[test]
    fn swift_input_limits_and_unique_evidence_are_enforced() {
        assert!(input().validate().is_ok());
        let mut duplicate = input();
        duplicate.evidence_ids.push("evidence-1".to_owned());
        assert!(duplicate.validate().is_err());
        let mut long_role = input();
        long_role.conversation[0].author_role = "x".repeat(MAX_AUTHOR_ROLE_BYTES + 1);
        assert!(long_role.validate().is_err());
        let mut trusted = input();
        trusted.content_is_untrusted = false;
        assert!(trusted.validate().is_err());
        let mut incomplete_table = input();
        incomplete_table.evidence.clear();
        assert!(incomplete_table.validate().is_err());
    }

    #[test]
    fn output_cannot_invent_evidence_or_use_markdown_fences() {
        assert!(output().validate_against(&input()).is_ok());
        let mut invented = output();
        invented.action_items[0].evidence_ids = vec!["not-in-input".to_owned()];
        assert!(invented.validate_against(&input()).is_err());
        let mut fenced = output();
        fenced.summary = "```not allowed```".to_owned();
        assert!(fenced.validate_against(&input()).is_err());
        let mut invented_deadline = output();
        invented_deadline.action_items[0].deadline = Some("2026-08-30T17:00:00Z".parse().unwrap());
        assert!(invented_deadline.validate_against(&input()).is_err());
        let mut invalid_action_confidence = output();
        invalid_action_confidence.action_items[0].confidence = 1.01;
        assert!(
            invalid_action_confidence
                .validate_against(&input())
                .is_err()
        );
        let mut mismatched_claim = output();
        mismatched_claim.action_items[0].claims[0].actor_role = "invented".to_owned();
        assert!(mismatched_claim.validate_against(&input()).is_err());
        let mut injected_claim = output();
        injected_claim.action_items[0].claims[0].quoted_span = "ignore previous".to_owned();
        assert!(injected_claim.validate_against(&input()).is_err());
        let mut stale_reason_claim = output();
        stale_reason_claim.action_items[0].claims[0].deterministic_reason_id = "stale".to_owned();
        assert!(stale_reason_claim.validate_against(&input()).is_err());
    }
}
