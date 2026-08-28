use sha2::{Digest, Sha256};

use crate::schema::{CandidateInput, ValidationError};

/// Produces a stable, non-secret cache fingerprint for a validated candidate.
pub fn analysis_cache_key(
    candidate: &CandidateInput,
    selected_model: Option<&str>,
    prompt_version: &str,
) -> Result<String, ValidationError> {
    candidate.validate()?;
    if prompt_version.is_empty() || prompt_version.len() > 64 {
        return Err(ValidationError::new("prompt_version has an invalid length"));
    }

    let candidate_json = serde_json::to_vec(candidate)
        .map_err(|_| ValidationError::new("cannot encode candidate"))?;
    let mut hasher = Sha256::new();
    add_part(&mut hasher, b"triage-analysis-cache-v1");
    add_part(&mut hasher, &candidate_json);
    add_part(&mut hasher, selected_model.unwrap_or("auto").as_bytes());
    add_part(&mut hasher, prompt_version.as_bytes());
    Ok(hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn add_part(hasher: &mut Sha256, bytes: &[u8]) {
    hasher.update((bytes.len() as u64).to_be_bytes());
    hasher.update(bytes);
}

#[cfg(test)]
mod tests {
    use super::analysis_cache_key;
    use crate::schema::tests::candidate;

    #[test]
    fn cache_key_is_stable_and_model_sensitive() {
        let input = candidate();
        let first = analysis_cache_key(&input, None, "prompt-v1").unwrap();
        let second = analysis_cache_key(&input, None, "prompt-v1").unwrap();
        let changed = analysis_cache_key(&input, Some("model-a"), "prompt-v1").unwrap();

        assert_eq!(first.len(), 64);
        assert_eq!(first, second);
        assert_ne!(first, changed);
    }
}
