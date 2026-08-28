use std::collections::HashSet;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

pub const MAX_TITLE_BYTES: usize = 512;
pub const MAX_BODY_BYTES: usize = 12 * 1024;
pub const MAX_CONVERSATION_ITEMS: usize = 24;
pub const MAX_CONVERSATION_TEXT_BYTES: usize = 4 * 1024;
pub const MAX_EVIDENCE: usize = 64;
pub const MAX_ACTIONS: usize = 16;

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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkItemState {
    Open,
    Closed,
    Merged,
    Draft,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ParticipantRole {
    Author,
    Assignee,
    Reviewer,
    Commenter,
    Mentioned,
    Unknown,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EvidenceKind {
    Issue,
    PullRequest,
    Review,
    Comment,
    TimelineEvent,
    Discussion,
    Project,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TriggerReason {
    pub id: String,
    pub title: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ConversationItem {
    pub occurred_at: DateTime<Utc>,
    pub participant_alias: String,
    pub participant_role: ParticipantRole,
    pub text: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EvidenceInput {
    pub id: Uuid,
    pub kind: EvidenceKind,
    pub observed_at: DateTime<Utc>,
    pub quote: String,
    pub explicit_deadline: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CandidateInput {
    pub candidate_id: Uuid,
    pub content_is_untrusted: bool,
    pub work_item_title: String,
    pub state: WorkItemState,
    pub trigger_reasons: Vec<TriggerReason>,
    pub body: Option<String>,
    pub conversation: Vec<ConversationItem>,
    pub labels: Vec<String>,
    pub project_fields: std::collections::BTreeMap<String, String>,
    pub evidence: Vec<EvidenceInput>,
}

impl CandidateInput {
    pub fn validate(&self) -> Result<(), ValidationError> {
        if !self.content_is_untrusted {
            return Err(ValidationError::new(
                "candidate content must be marked untrusted",
            ));
        }
        validate_text(&self.work_item_title, MAX_TITLE_BYTES, "work_item_title")?;
        validate_count(&self.trigger_reasons, 1, 16, "trigger_reasons")?;
        validate_count(
            &self.conversation,
            0,
            MAX_CONVERSATION_ITEMS,
            "conversation",
        )?;
        validate_count(&self.labels, 0, 32, "labels")?;
        if self.project_fields.len() > 32 {
            return Err(ValidationError::new(
                "project_fields has an invalid item count",
            ));
        }
        validate_count(&self.evidence, 1, MAX_EVIDENCE, "evidence")?;

        if let Some(body) = &self.body {
            validate_text(body, MAX_BODY_BYTES, "body")?;
        }
        for reason in &self.trigger_reasons {
            validate_text(&reason.id, 64, "trigger_reason.id")?;
            validate_text(&reason.title, 256, "trigger_reason.title")?;
        }
        for item in &self.conversation {
            validate_text(
                &item.participant_alias,
                64,
                "conversation.participant_alias",
            )?;
            validate_text(&item.text, MAX_CONVERSATION_TEXT_BYTES, "conversation.text")?;
        }
        for label in &self.labels {
            validate_text(label, 128, "label")?;
        }
        for (key, value) in &self.project_fields {
            validate_text(key, 128, "project_field.key")?;
            validate_text(value, 256, "project_field.value")?;
        }

        let mut evidence_ids = HashSet::new();
        for evidence in &self.evidence {
            if !evidence_ids.insert(evidence.id) {
                return Err(ValidationError::new("evidence IDs must be unique"));
            }
            validate_text(&evidence.quote, 2 * 1024, "evidence.quote")?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AnalysisProvenance {
    pub model_id: String,
    pub prompt_version: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActionItem {
    pub id: Uuid,
    pub title: String,
    pub detail: Option<String>,
    pub confidence: f64,
    pub evidence_ids: Vec<Uuid>,
    pub next_action: String,
    pub explicit_deadline: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AnalysisOutput {
    pub schema_version: u16,
    pub summary: String,
    pub state: WorkItemState,
    pub confidence: f64,
    pub evidence_ids: Vec<Uuid>,
    pub action_items: Vec<ActionItem>,
    pub provenance: AnalysisProvenance,
}

impl AnalysisOutput {
    pub fn validate_against(&self, candidate: &CandidateInput) -> Result<(), ValidationError> {
        candidate.validate()?;
        if self.schema_version != 1 {
            return Err(ValidationError::new("unsupported analysis schema version"));
        }
        validate_output_text(&self.summary, 2 * 1024, "summary")?;
        validate_confidence(self.confidence, "confidence")?;
        validate_output_text(&self.provenance.model_id, 128, "provenance.model_id")?;
        validate_output_text(
            &self.provenance.prompt_version,
            64,
            "provenance.prompt_version",
        )?;
        validate_count(&self.evidence_ids, 1, MAX_EVIDENCE, "evidence_ids")?;
        validate_count(&self.action_items, 0, MAX_ACTIONS, "action_items")?;

        let source_evidence: HashSet<_> = candidate.evidence.iter().map(|value| value.id).collect();
        ensure_known_unique(&self.evidence_ids, &source_evidence, "analysis evidence")?;

        let mut action_ids = HashSet::new();
        for action in &self.action_items {
            if !action_ids.insert(action.id) {
                return Err(ValidationError::new("action IDs must be unique"));
            }
            validate_output_text(&action.title, 256, "action.title")?;
            if let Some(detail) = &action.detail {
                validate_output_text(detail, 1024, "action.detail")?;
            }
            validate_output_text(&action.next_action, 512, "action.next_action")?;
            validate_confidence(action.confidence, "action.confidence")?;
            validate_count(&action.evidence_ids, 1, MAX_EVIDENCE, "action.evidence_ids")?;
            ensure_known_unique(&action.evidence_ids, &source_evidence, "action evidence")?;
            if action
                .evidence_ids
                .iter()
                .any(|id| !self.evidence_ids.contains(id))
            {
                return Err(ValidationError::new(
                    "action evidence must also be listed by the analysis",
                ));
            }
            if let Some(deadline) = action.explicit_deadline {
                let deadline_is_evidenced = candidate.evidence.iter().any(|evidence| {
                    action.evidence_ids.contains(&evidence.id)
                        && evidence.explicit_deadline.as_ref() == Some(&deadline)
                });
                if !deadline_is_evidenced {
                    return Err(ValidationError::new(
                        "explicit deadline must exactly match referenced evidence",
                    ));
                }
            }
        }
        Ok(())
    }
}

fn validate_count<T>(
    values: &[T],
    minimum: usize,
    maximum: usize,
    field: &str,
) -> Result<(), ValidationError> {
    if !(minimum..=maximum).contains(&values.len()) {
        return Err(ValidationError::new(format!(
            "{field} has an invalid item count"
        )));
    }
    Ok(())
}

fn validate_text(value: &str, maximum_bytes: usize, field: &str) -> Result<(), ValidationError> {
    if value.is_empty() || value.len() > maximum_bytes || value.contains('\0') {
        return Err(ValidationError::new(format!(
            "{field} has an invalid length"
        )));
    }
    Ok(())
}

fn validate_output_text(
    value: &str,
    maximum_bytes: usize,
    field: &str,
) -> Result<(), ValidationError> {
    validate_text(value, maximum_bytes, field)?;
    if value.contains("```") {
        return Err(ValidationError::new(format!(
            "{field} must not contain Markdown fences"
        )));
    }
    Ok(())
}

fn validate_confidence(value: f64, field: &str) -> Result<(), ValidationError> {
    if !value.is_finite() || !(0.0..=1.0).contains(&value) {
        return Err(ValidationError::new(format!(
            "{field} must be between zero and one"
        )));
    }
    Ok(())
}

fn ensure_known_unique(
    ids: &[Uuid],
    known: &HashSet<Uuid>,
    field: &str,
) -> Result<(), ValidationError> {
    let mut seen = HashSet::new();
    for id in ids {
        if !seen.insert(*id) || !known.contains(id) {
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
    use std::collections::BTreeMap;

    pub(crate) fn candidate() -> CandidateInput {
        CandidateInput {
            candidate_id: Uuid::parse_str("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").unwrap(),
            content_is_untrusted: true,
            work_item_title: "Review incident fix".to_owned(),
            state: WorkItemState::Open,
            trigger_reasons: vec![TriggerReason {
                id: "review_requested".to_owned(),
                title: "Review requested".to_owned(),
            }],
            body: Some("Please review the mitigation.".to_owned()),
            conversation: vec![ConversationItem {
                occurred_at: "2026-08-28T04:00:00Z".parse().unwrap(),
                participant_alias: "author".to_owned(),
                participant_role: ParticipantRole::Author,
                text: "The deadline is Friday.".to_owned(),
            }],
            labels: vec!["incident".to_owned()],
            project_fields: BTreeMap::new(),
            evidence: vec![EvidenceInput {
                id: Uuid::parse_str("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb").unwrap(),
                kind: EvidenceKind::Comment,
                observed_at: "2026-08-28T04:00:00Z".parse().unwrap(),
                quote: "The deadline is Friday.".to_owned(),
                explicit_deadline: Some("2026-08-29T00:00:00Z".parse().unwrap()),
            }],
        }
    }

    fn valid_output() -> AnalysisOutput {
        let input = candidate();
        AnalysisOutput {
            schema_version: 1,
            summary: "A review is requested before Friday.".to_owned(),
            state: WorkItemState::Open,
            confidence: 0.95,
            evidence_ids: vec![input.evidence[0].id],
            action_items: vec![ActionItem {
                id: Uuid::parse_str("cccccccc-cccc-4ccc-8ccc-cccccccccccc").unwrap(),
                title: "Review the mitigation".to_owned(),
                detail: None,
                confidence: 0.95,
                evidence_ids: vec![input.evidence[0].id],
                next_action: "Read the proposed mitigation and leave a review.".to_owned(),
                explicit_deadline: input.evidence[0].explicit_deadline,
            }],
            provenance: AnalysisProvenance {
                model_id: "example-model".to_owned(),
                prompt_version: "v1".to_owned(),
            },
        }
    }

    #[test]
    fn output_requires_real_evidence_and_evidenced_deadline() {
        let input = candidate();
        assert!(valid_output().validate_against(&input).is_ok());

        let mut invented_evidence = valid_output();
        invented_evidence.action_items[0].evidence_ids = vec![Uuid::new_v4()];
        assert!(invented_evidence.validate_against(&input).is_err());

        let mut invented_deadline = valid_output();
        invented_deadline.action_items[0].explicit_deadline =
            Some("2026-08-30T00:00:00Z".parse().unwrap());
        assert!(invented_deadline.validate_against(&input).is_err());
    }

    #[test]
    fn output_rejects_fences_and_invalid_confidence() {
        let input = candidate();
        let mut output = valid_output();
        output.summary = "```not accepted```".to_owned();
        assert!(output.validate_against(&input).is_err());

        let mut output = valid_output();
        output.confidence = 1.1;
        assert!(output.validate_against(&input).is_err());
    }

    #[test]
    fn candidate_rejects_duplicate_evidence_and_unmarked_content() {
        let mut input = candidate();
        input.evidence.push(input.evidence[0].clone());
        assert!(input.validate().is_err());

        let mut input = candidate();
        input.content_is_untrusted = false;
        assert!(input.validate().is_err());
    }
}
