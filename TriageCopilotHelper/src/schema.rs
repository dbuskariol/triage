use std::collections::HashSet;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

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

fn validate_identifier(value: &str, field: &str) -> Result<(), ValidationError> {
    if value.is_empty() || value.chars().any(char::is_whitespace) {
        return Err(ValidationError::new(format!("{field} is invalid")));
    }
    Ok(())
}
fn validate_text(value: &str, maximum: usize, field: &str) -> Result<(), ValidationError> {
    if value.is_empty() || value.len() > maximum {
        return Err(ValidationError::new(format!("{field} is invalid")));
    }
    Ok(())
}

pub const MAX_TRIAGE_ITEMS: usize = 20;
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TriageReview {
    pub author: String,
    pub state: String,
    pub submitted_at: Option<DateTime<Utc>>,
}
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TriagePullRequest {
    pub is_draft: bool,
    pub review_decision: Option<String>,
    pub requested_reviewers: Vec<String>,
    pub latest_reviews: Vec<TriageReview>,
    pub checks: Option<String>,
    pub mergeable: Option<String>,
    pub unresolved_review_threads: i32,
    pub additions: i32,
    pub deletions: i32,
}
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TriageActivity {
    pub author: String,
    pub created_at: DateTime<Utc>,
    pub excerpt: String,
}
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TriageItem {
    pub id: String,
    pub kind: String,
    pub repository: String,
    pub number: i32,
    pub title: String,
    pub state: String,
    pub author: Option<String>,
    pub updated_at: DateTime<Utc>,
    pub relationships: Vec<String>,
    pub labels: Vec<String>,
    pub assignees: Vec<String>,
    pub body: String,
    pub pull_request: Option<TriagePullRequest>,
    pub recent_activity: Vec<TriageActivity>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rule_hints: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_next_action: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub viewer_activity: Vec<String>,
}
// Model output: unknown fields are ignored and only known fields are re-serialized.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct TriageItemDecision {
    pub id: String,
    pub disposition: String,
    pub priority: i32,
    pub confidence: f64,
    pub summary: String,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_action: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instruction_note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handled: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handled_evidence: Option<String>,
}
impl TriageItem {
    fn validate(&self) -> Result<(), ValidationError> {
        validate_identifier(&self.id, "item.id")?;
        validate_text(&self.kind, 64, "item.kind")?;
        validate_text(&self.repository, 512, "item.repository")?;
        validate_text(&self.title, 4_000, "item.title")?;
        validate_text(&self.state, 64, "item.state")?;
        if self.rule_hints.len() > 10
            || self
                .rule_hints
                .iter()
                .any(|hint| hint.is_empty() || hint.len() > 200)
        {
            return Err(ValidationError::new("triage rule hints are invalid"));
        }
        if self.number <= 0 || self.body.len() > 4_000 {
            return Err(ValidationError::new("triage item is invalid"));
        }
        Ok(())
    }
}
pub const MAX_TRIAGE_INSTRUCTION_BYTES: usize = 2_000;

pub fn validate_triage_instructions(instructions: Option<&str>) -> Result<(), ValidationError> {
    if instructions.is_some_and(|value| value.len() > MAX_TRIAGE_INSTRUCTION_BYTES) {
        return Err(ValidationError::new("instructions are too long"));
    }
    Ok(())
}

pub fn validate_triage_inputs(
    viewer_login: &str,
    items: &[TriageItem],
) -> Result<(), ValidationError> {
    validate_identifier(viewer_login, "viewer_login")?;
    if !(1..=MAX_TRIAGE_ITEMS).contains(&items.len()) {
        return Err(ValidationError::new(
            "triage requires one through twenty items",
        ));
    }
    let mut ids = HashSet::new();
    for item in items {
        item.validate()?;
        if !ids.insert(item.id.as_str()) {
            return Err(ValidationError::new("triage item IDs must be unique"));
        }
    }
    Ok(())
}
/// Parses model output leniently: tolerates Markdown fences or prose around the
/// JSON array and clamps over-long text instead of discarding the whole batch.
pub fn parse_triage_output(content: &str) -> Option<Vec<TriageItemDecision>> {
    let start = content.find('[')?;
    let end = content.rfind(']')?;
    if end < start {
        return None;
    }
    let mut decisions: Vec<TriageItemDecision> =
        serde_json::from_str(&content[start..=end]).ok()?;
    for decision in &mut decisions {
        decision.disposition = decision.disposition.trim().to_ascii_lowercase();
        decision.priority = decision.priority.clamp(0, 100);
        if decision.confidence.is_finite() {
            decision.confidence = decision.confidence.clamp(0.0, 1.0);
        }
        decision.summary = clamp_text(decision.summary.trim(), 280);
        decision.reason = clamp_text(decision.reason.trim(), 400);
        decision.next_action = decision
            .next_action
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| clamp_text(value, 200));
        decision.handled = decision
            .handled
            .as_deref()
            .map(|value| value.trim().to_ascii_lowercase())
            .filter(|value| matches!(value.as_str(), "yes" | "partial" | "no"));
        decision.handled_evidence = decision
            .handled_evidence
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("null"))
            .map(|value| clamp_text(value, 200));
        decision.instruction_note = decision
            .instruction_note
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("null"))
            .map(|value| clamp_text(value, 200));
    }
    Some(decisions)
}

fn clamp_text(value: &str, maximum_bytes: usize) -> String {
    if value.len() <= maximum_bytes {
        return value.to_owned();
    }
    let mut end = maximum_bytes.saturating_sub('…'.len_utf8());
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", value[..end].trim_end())
}

/// Keeps every well-formed decision for a requested item (first occurrence
/// wins) and drops the rest, so one malformed decision never discards a whole
/// batch. Missing items are retried by the app. Fails only when nothing is usable.
pub fn retain_valid_triage_outputs(
    outputs: Vec<TriageItemDecision>,
    inputs: &[TriageItem],
) -> Result<Vec<TriageItemDecision>, ValidationError> {
    let expected: HashSet<&str> = inputs.iter().map(|i| i.id.as_str()).collect();
    let mut ids = HashSet::new();
    let valid: Vec<TriageItemDecision> = outputs
        .into_iter()
        .filter(|output| {
            expected.contains(output.id.as_str())
                && matches!(
                    output.disposition.as_str(),
                    "act" | "review" | "wait" | "none"
                )
                && (0..=100).contains(&output.priority)
                && output.confidence.is_finite()
                && (0.0..=1.0).contains(&output.confidence)
                && validate_text(&output.summary, 280, "summary").is_ok()
                && validate_text(&output.reason, 400, "reason").is_ok()
                && !output
                    .next_action
                    .as_ref()
                    .is_some_and(|v| v.is_empty() || v.len() > 200)
                && ids.insert(output.id.clone())
        })
        .collect();
    if valid.is_empty() {
        return Err(ValidationError::new("triage returned no usable decisions"));
    }
    Ok(valid)
}

#[cfg(test)]
mod triage_contract_tests {
    #[test]
    fn parse_triage_output_tolerates_fences_and_clamps_text() {
        let long = "é".repeat(400);
        let content = format!(
            "```json\n[{{\"id\":\"A\",\"disposition\":\" Act \",\"priority\":120,\"confidence\":1.5,\"summary\":\"{long}\",\"reason\":\"r\",\"next_action\":\"\",\"extra\":1}}]\n```"
        );
        let decisions = super::parse_triage_output(&content).expect("parsed");
        let decision = &decisions[0];
        assert_eq!(decision.disposition, "act");
        assert_eq!(decision.priority, 100);
        assert_eq!(decision.confidence, 1.0);
        assert!(decision.summary.len() <= 280 && decision.summary.ends_with('…'));
        assert_eq!(decision.next_action, None);
        assert!(super::parse_triage_output("no json here").is_none());
        assert!(super::validate_triage_instructions(Some(&"a".repeat(2_001))).is_err());
        assert!(super::validate_triage_instructions(Some("Prefer security work.")).is_ok());
    }

    use super::*;
    fn item(id: &str) -> TriageItem {
        TriageItem {
            id: id.into(),
            kind: "issue".into(),
            repository: "o/r".into(),
            number: 1,
            title: "Title".into(),
            state: "open".into(),
            author: None,
            updated_at: Utc::now(),
            relationships: vec![],
            labels: vec![],
            assignees: vec![],
            body: "".into(),
            pull_request: None,
            recent_activity: vec![],
            rule_hints: vec![],
            previous_next_action: None,
            viewer_activity: vec![],
        }
    }
    fn decision(id: &str) -> TriageItemDecision {
        TriageItemDecision {
            id: id.into(),
            disposition: "review".into(),
            priority: 40,
            confidence: 0.8,
            summary: "Read this item.".into(),
            reason: "It is relevant to you.".into(),
            next_action: None,
            instruction_note: None,
            handled: None,
            handled_evidence: None,
        }
    }
    #[test]
    fn triage_keeps_valid_decisions_for_requested_items() {
        let inputs = vec![item("one"), item("two")];
        let ids = |outputs: Vec<TriageItemDecision>| {
            retain_valid_triage_outputs(outputs, &inputs)
                .map(|v| v.into_iter().map(|d| d.id).collect::<Vec<_>>())
        };
        assert_eq!(ids(vec![decision("one")]).unwrap(), ["one"]);
        assert_eq!(
            ids(vec![decision("one"), decision("three"), decision("one")]).unwrap(),
            ["one"]
        );
        assert_eq!(
            ids(vec![decision("one"), decision("two")]).unwrap(),
            ["one", "two"]
        );
        assert!(ids(vec![decision("three")]).is_err());
        assert!(ids(vec![]).is_err());
    }
}
